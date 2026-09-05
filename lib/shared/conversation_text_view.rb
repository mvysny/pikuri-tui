# frozen_string_literal: true

require 'pikuri-core'
require 'tuile'

# The conversation transcript as one cohesive Tuile component: a
# {Tuile::Component::TextView} that renders an agent conversation into itself —
# user turns, streamed reasoning, streamed assistant answers, tool calls, tool
# observations, fallback notices, cancellation markers. The host folds the
# listener it exposes into the agent:
#
#   pane = Shared::ConversationTextView.new
#   config.add_listener(pane.listener)   # into the agent's ListenerList
#
# This is the app's *primary* pane, so it is deliberately unframed and
# untinted: it keeps the terminal's own background, and the surfaces around it
# — the {Shared::StatusRuleLabel} below it, the {Shared::InputPane} below that,
# the coding shell's sidebar beside it — are the tinted secondaries that set it
# off. The agent status it used to carry in its bottom border now lives on the
# rule, which is a sibling row the shell's +Layout+ owns.
#
# The pikuri seam lives in the nested {Listener}, not on the pane: this
# component exposes UI verbs ({#add_block}, {#open_assistant_block},
# {#render_markdown}, …) and knows nothing about +Pikuri::Agent::Event+. The
# {Listener} is the sole translator from the event stream into those verbs.
#
# == State ownership
#
# The pane itself is *stateless* with respect to a conversation's progress: it
# holds no "currently-open block" cursor. Each {Listener} carries its own
# open-stream state (two {Shared::StreamedBlock}s — assistant and thinking —
# plus the tool-call/result pairing) and drives the pane's stateless verbs.
# That is what lets a sub-agent be "another thin listener with a bigger indent"
# writing into this same pane without sharing the parent's open blocks (see
# {Listener#for_sub_agent}).
#
# The one exception is {#pending_decision} — the pane must hold it, because the
# pane is what the answering keys arrive at.
#
# == Asking a human decision
#
#   conversation.pending_decision = decision      # body + "(y) approve …"
#   # user Tabs here (the prompt's caret vanishes — that is the focus cue),
#   # presses y; decision.on_choice fires with :approve
#   conversation.settle_pending_decision('approved')
#
# The answer keys are armed by *focus*: they only answer while this pane holds
# it. That is the whole safety property — prose typed at the prompt is a
# different focus target, so no amount of typing can answer a question the user
# has not looked at.
#
# == Markdown flag
#
# +markdown:+ (default +true+) gates the assistant render path: when off, the
# assistant streaming path uses {Shared::Markdown::PassthroughBuffer} and
# {#render_markdown} returns its input verbatim. The thinking pane's grayscale
# repaint is independent of the flag — a +markdown: false+ thinking buffer is
# still a {Shared::Markdown::StreamingBuffer} with a recolor-only render
# function, so the gray tint survives.
#
# UI-thread-confined, with exceptions (the nested {Listener} marshals the event
# stream onto the UI thread before driving these verbs; {#render_turn_error} is
# safe off-thread and self-marshals).
class Shared::ConversationTextView < Tuile::Component::TextView
  # Cap, in characters, applied to tool-result content before it lands in the
  # pane. Mirrors the terminal listener's cap so the two renderers stay
  # visually consistent.
  #
  # @return [Integer]
  MAX_TOOL_RESULT_CHARS = 200

  # Keys that mean "I'm done reading here", both routed to {#on_escape}.
  #
  # +q+ rides along with ESC because Tuile's event loop *stops* on either one
  # when no component claims it — fine when nothing is focused, a footgun on a
  # pane the user tabs to in order to answer a decision.
  #
  # @return [Array<String>]
  LEAVE_KEYS = [Tuile::Keys::ESC, 'q'].freeze

  LOG = Pikuri.logger_for('markdown')
  private_constant :LOG

  # @param markdown [Boolean] when +true+ (the default), assistant content is
  #   rendered through {Shared::Markdown::Renderer}; when +false+, echoed
  #   verbatim and streamed through {Shared::Markdown::PassthroughBuffer}. The
  #   thinking path always recolors to gray.
  # @param tool_formatters [Hash{String => #render_call, #render_result}]
  #   per-tool-name formatters that replace the default +→ name(args)+ /
  #   += result+ rendering for those tools (the +edit+ / +write+ diff views).
  #   Defaults to +{}+.
  def initialize(markdown: true, tool_formatters: {})
    super()
    @markdown = markdown
    @tool_formatters = tool_formatters
    self.auto_scroll = true
    # Unlike the coding shell's sidebar panes this one is genuinely scrollable,
    # by the prompt's PageUp/PageDown.
    self.scrollbar_visibility = :visible
    # The leaf listener this pane builds directly isn't a component, so it
    # takes the screen explicitly — this pane hands it its own inherited
    # +#screen+ property (the {Tuile::Screen} singleton, fake-able via
    # +Tuile::Screen.fake+ for tests). Its +event_queue+ marshals the render
    # calls back from the agent's worker thread.
    @listener = Listener.new(view: self, screen: screen, indent: 0)
    @pending_decision = nil
    @decision_region = nil
    @decision_body = nil
    @on_escape = nil
  end

  # @return [Listener] the transcript listener bound to this pane, created once
  #   at construction. The host includes it in the agent's +ListenerList+;
  #   pikuri mints indented siblings off it via {Listener#for_sub_agent}.
  attr_reader :listener

  # @return [Shared::PendingDecision, nil] the decision this pane is currently
  #   asking, +nil+ when there is none. While set, {#handle_key} claims that
  #   decision's keys.
  attr_reader :pending_decision

  # @return [Proc, nil] zero-arg callable run when the user leaves this pane
  #   ({LEAVE_KEYS}) — normally "put focus back on the prompt". Leave it unset
  #   and those keys fall through unclaimed, which stops the event loop.
  attr_accessor :on_escape

  # @return [Hash{String => #render_call, #render_result}] the per-tool
  #   formatters, consulted by the {Listener} on each tool call.
  attr_reader :tool_formatters

  # @return [Tuile::Theme] the screen's current theme (re-read each call so an
  #   OS light/dark flip is picked up).
  def theme = screen.theme

  # Render width for a fresh streaming buffer: the pane's wrap width (its own
  # width less the columns the scrollbar claims), floored at 1 so a
  # not-yet-laid-out pane doesn't pass a non-positive width to
  # {Shared::Markdown::Renderer}.
  #
  # @return [Integer]
  def buffer_width = [wrap_width, 1].max

  # Append one logical block to the pane: create a fresh region and assign
  # +text+ (prefixed with +indent+ spaces on its first line). Each
  # non-streaming event lands as exactly one such block.
  #
  # @param text [String, Tuile::StyledString] the block's content.
  # @param indent [Integer] leading spaces on the block's first line.
  # @return [void]
  def add_block(text, indent: 0)
    create_region.text = indent_block(text, indent)
  end

  # Open a fresh streamed assistant block: a new region plus the streaming
  # buffer writing into it — a {Shared::Markdown::StreamingBuffer} (Markdown →
  # ANSI) when +@markdown+, else a {Shared::Markdown::PassthroughBuffer}. The
  # render proc snapshots the width + terminal scheme at build time (one buffer
  # per block), so an appearance flip mid-block keeps the scheme it started
  # with. Drives a {Shared::StreamedBlock}.
  #
  # @param indent [Integer] leading spaces baked into the render proc.
  # @return [Array(Tuile::Component::TextView::Region, #append)] the region and
  #   its streaming buffer.
  def open_assistant_block(indent: 0)
    region = create_region
    buffer =
      if @markdown
        Shared::Markdown::StreamingBuffer.new(render: indent_render(build_markdown_renderer, indent), region: region)
      else
        Shared::Markdown::PassthroughBuffer.new(region: region)
      end
    [region, buffer]
  end

  # Twin of {#open_assistant_block} for the reasoning pane. Always a
  # {Shared::Markdown::StreamingBuffer}: the render is
  # {Shared::Markdown::Renderer}→recolor when Markdown is on, recolor-only when
  # off — so the gray tint applies in both modes. The reasoning tone is
  # snapshot at build time, like the width.
  #
  # @param indent [Integer] leading spaces baked into the render proc.
  # @return [Array(Tuile::Component::TextView::Region, #append)] the region and
  #   its streaming buffer.
  def open_thinking_block(indent: 0)
    region = create_region
    thinking = screen.theme[:thinking]
    render = if @markdown
               markdown = build_markdown_renderer
               ->(md) { Shared::Markdown::Grayscale.recolor(markdown.call(md), fg: thinking) }
             else
               ->(md) { Shared::Markdown::Grayscale.recolor(md, fg: thinking) }
             end
    [region, Shared::Markdown::StreamingBuffer.new(render: indent_render(render, indent), region: region)]
  end

  # Render assistant Markdown for the pane, degrading to the raw string when
  # the renderer raises — LLM output is arbitrary and a kramdown / rouge
  # surprise shouldn't abort an in-flight conversation on a long-running TUI.
  # A no-op returning +content+ unchanged when +@markdown+ is false.
  #
  # @param content [String] assistant Markdown
  # @return [String] rendered ANSI text, or +content+ on failure / when
  #   Markdown is off.
  def render_markdown(content)
    return content unless @markdown

    Shared::Markdown::Renderer.render(content, width: buffer_width, dark: dark_scheme?)
  rescue StandardError => e
    LOG.warn("Shared::Markdown::Renderer.render failed (#{e.class}: #{e.message}); falling back to raw text")
    content
  end

  # Render a non-streamed reasoning bookend: the Markdown render recolored to
  # the theme's single muted reasoning tone (structure preserved). Used when a
  # {Pikuri::Agent::Event::Thinking} arrives with no preceding deltas.
  #
  # @param content [String] reasoning Markdown
  # @return [String] gray-toned ANSI text
  def render_thinking(content)
    Shared::Markdown::Grayscale.recolor(render_markdown(content), fg: screen.theme[:thinking])
  end

  # Flatten whitespace and cap to {MAX_TOOL_RESULT_CHARS}. Long results
  # (rendered HTML, PDF text) would otherwise drown the transcript; the
  # byte-count suffix distinguishes "tool returned exactly this" from "tool
  # returned much more."
  #
  # @param content [String] tool observation
  # @return [String] single-line display form, possibly truncated
  def truncate_tool_result(content)
    original_bytes = content.to_s.bytesize
    flattened = content.to_s.gsub(/\s+/, ' ').strip
    return flattened if flattened.length <= MAX_TOOL_RESULT_CHARS

    "#{flattened[0, MAX_TOOL_RESULT_CHARS]}… (#{original_bytes} bytes total)"
  end

  # Append a one-line, error-themed turn-failure notice to the transcript.
  # Safe to call from the agent worker thread; marshals its own append onto
  # the event-loop thread.
  #
  # @param exception [StandardError] the caught library exception.
  # @return [void]
  def render_turn_error(exception)
    screen.event_queue.submit do
      add_line(screen.theme.error("! #{exception.class}: #{exception.message}"))
    end
  end

  # Append a one-line, muted informational notice to the transcript — the dim
  # sibling of {#render_turn_error}, same self-marshaling shape but the detail
  # tone, so a non-failure (e.g. a bare skill-load with nothing to send yet)
  # never reads as an error. Safe to call from the agent worker thread.
  #
  # @param text [String] the notice, plain; this applies the tone.
  # @return [void]
  def render_notice(text)
    screen.event_queue.submit do
      add_line(screen.theme.detail("· #{text}"))
    end
  end

  # Ask +decision+ in the transcript: append its body with the key cue under it,
  # and claim those keys until the decision is settled.
  #
  #   ⏵ OK to run `rm -rf build`?
  #   (y) approve   (n) reject   (r) reject w/ reason
  #
  # Passing +nil+ disarms the keys without touching the block — for a decision
  # whose answer is still being typed elsewhere.
  #
  # @param decision [Shared::PendingDecision, nil] the decision to ask.
  # @return [void]
  def pending_decision=(decision)
    @pending_decision = decision
    return if decision.nil?

    @decision_body = decision.body
    @decision_region = create_region
    write_decision(screen.theme.notice(decision.cue))
  end

  # Rewrite the asked decision's cue line as +text+, the record of how it went,
  # and disarm its keys. Repeatable: an outcome reached in two steps (reject,
  # then a typed reason) settles once per step.
  #
  #   conversation.settle_pending_decision('approved')   # · approved
  #
  # @param text [String] the outcome, plain; this applies the tone.
  # @return [void]
  # @raise [RuntimeError] if no decision was ever asked into this pane.
  def settle_pending_decision(text)
    raise 'no decision block to settle' if @decision_region.nil?

    @pending_decision = nil
    write_decision(screen.theme.detail("· #{text}"))
  end

  # Claims the asked decision's keys, then {LEAVE_KEYS}, then falls back to
  # {Tuile::Component::TextView}'s scroll ladder.
  #
  # @param key [String]
  # @return [Boolean] +true+ if the key was consumed here.
  def handle_key(key)
    return true if choose(key)

    if LEAVE_KEYS.include?(key) && @on_escape
      @on_escape.call
      return true
    end

    super
  end

  # Drops every region, the asked decision's included.
  #
  # @return [void]
  def clear
    super
    @pending_decision = nil
    @decision_region = nil
    @decision_body = nil
  end

  private

  # @param key [String]
  # @return [Boolean] whether the key picked an outcome for the asked decision.
  def choose(key)
    choice = @pending_decision&.choice_for(key)
    return false if choice.nil?

    @pending_decision.on_choice.call(choice.outcome)
    true
  end

  # Rewrite the decision block as its body over +tail+.
  #
  # @param tail [String] the toned cue or outcome line.
  # @return [void]
  def write_decision(tail)
    @decision_region.text = "#{@decision_body}\n#{tail}"
  end

  # Prepend +indent+ spaces to a block, handling both +String+ blocks (theme
  # helpers, rendered markdown) and +Tuile::StyledString+ blocks (the diff
  # formatters). The pad lands on the first line only.
  #
  # @param text [String, Tuile::StyledString]
  # @param indent [Integer]
  # @return [String, Tuile::StyledString]
  def indent_block(text, indent)
    return text if indent.zero?

    pad = ' ' * indent
    return pad + text if text.is_a?(String)

    Tuile::StyledString.plain(pad) + text
  end

  # Wrap a +String -> String+ render proc so its output carries +indent+ spaces
  # on the first line. A no-op (returns the proc unchanged) for the main agent.
  # The {Shared::Markdown::StreamingBuffer}'s commit-probe sentinel is
  # unaffected: the pad lands on the first line, the sentinel on the last.
  #
  # @param render [#call]
  # @param indent [Integer]
  # @return [#call]
  def indent_render(render, indent)
    return render if indent.zero?

    pad = ' ' * indent
    ->(md) { pad + render.call(md) }
  end

  # A callable snapshotting the current {#buffer_width} + terminal scheme,
  # routing through {Shared::Markdown::Renderer.render}.
  #
  # @return [Proc]
  def build_markdown_renderer
    width = buffer_width
    dark = dark_scheme?
    ->(md) { Shared::Markdown::Renderer.render(md, width: width, dark: dark) }
  end

  # Whether the pane is on a dark terminal background, so
  # {Shared::Markdown::Renderer} can pick a legible code-highlighting theme.
  # The screen holds exactly the {Shared::AppTheme::DARK}/{Shared::AppTheme::LIGHT}
  # constant its {Tuile::ThemeDef} resolved, so identity against +LIGHT+ is the
  # live scheme.
  #
  # @return [Boolean]
  def dark_scheme? = !screen.theme.equal?(Shared::AppTheme::LIGHT)

  # Translates a +Pikuri::Agent+'s normalized event stream into
  # {Shared::ConversationTextView} render calls — the Tuile-targeted equivalent of
  # +Pikuri::Agent::Listener::Terminal+, rendering into the conversation pane
  # instead of stdout.
  #
  # This holds the per-conversation *state* the pane deliberately does not: two
  # {Shared::StreamedBlock}s (the open assistant and thinking blocks, each a
  # region + streaming buffer), the streamed-thinking flag, and the
  # tool-call/result pairing slot. Everything visual is delegated to the pane's
  # stateless verbs. Because the state lives here (not on the shared pane), a
  # sub-agent listener minted by {#for_sub_agent} renders into the same pane
  # with its own independent open blocks.
  #
  # == Variant coverage
  #
  # Mirrors the terminal listener with three intentional departures:
  #
  # 1. {Pikuri::Agent::Event::UserTurn} renders as +"> #{content}"+ instead of
  #    staying silent — submitting clears the input, so without an echo the
  #    user's message would vanish.
  # 2. Library failures during rendering are caught + logged (by the pane's
  #    {#render_markdown}), never raised — an uncaught raise on the worker
  #    thread would kill the agent loop.
  # 3. Streaming deltas ({Pikuri::Agent::Event::AssistantDelta} /
  #    {Pikuri::Agent::Event::ThinkingDelta}) render incrementally through a
  #    per-block streaming buffer; the thinking buffer recolors to one muted
  #    tone. A trailing bookend ({Pikuri::Agent::Event::Assistant} /
  #    {Pikuri::Agent::Event::Thinking}) finalizes the open buffer (replacing
  #    the preview if the delta stream was truncated) or, with no deltas,
  #    renders directly.
  #
  # +Tokens+ / +ContextCap+ stay silent (their consumer is
  # +Pikuri::Agent::Listener::TokenLog+).
  #
  # {#on_event} fires on the agent's worker thread and wraps the whole dispatch
  # in +screen.event_queue.submit+, so every region mutation runs on the
  # event-loop thread under the UI lock; the queue is FIFO, so events still land
  # in order.
  class Listener < Pikuri::Agent::Listener::Base
    # Leading spaces a sub-agent's listener prepends to every block, so its
    # stream reads as indented under the parent's +→ agent(...)+ call. Mirrors
    # +Pikuri::Agent::Listener::Terminal+'s +SUB_AGENT_PADDING+. The pad lands
    # on the first line only; sub-agent recursion is blocked (depth never
    # exceeds 1), so a fixed indent reads cleanly.
    #
    # @return [Integer]
    SUB_AGENT_INDENT = 2

    # @param view [Shared::ConversationTextView] the pane this listener renders
    #   into. Lifetime owned by the pane; the listener neither constructs nor
    #   destroys it.
    # @param screen [Tuile::Screen] the screen whose +event_queue+ marshals UI
    #   mutations back from the worker thread. Passed explicitly so the listener
    #   can be unit-tested with a {Tuile::FakeScreen}.
    # @param indent [Integer] leading spaces prepended to every block (0 for the
    #   main agent, {SUB_AGENT_INDENT} on a {#for_sub_agent} sibling).
    def initialize(view:, screen:, indent: 0)
      super()
      @view = view
      @screen = screen
      @indent = indent
      # The two open streamed blocks (each a region + streaming buffer). They
      # differ only in the pane verb the open-factory calls; everything else -
      # append, finalize, wipe, preserve - is the same lifecycle.
      @assistant = Shared::StreamedBlock.new { @view.open_assistant_block(indent: @indent) }
      @thinking = Shared::StreamedBlock.new { @view.open_thinking_block(indent: @indent) }
      @thinking_streamed = false
      # Set on a ToolCall a formatter handled, consumed by the next ToolResult
      # to pair the result with that call. ruby_llm runs tool calls strictly
      # call→result→call→result, so a single slot is exact.
      @pending_formatter = nil
    end

    # Dispatch one event to the pane, marshaled onto the event-loop thread so
    # the downstream region mutations execute under the UI lock.
    #
    # @param event [Pikuri::Agent::Event::Base]
    # @return [void]
    def on_event(event)
      @screen.event_queue.submit { dispatch_event(event) }
    end

    # @return [String] short label used by +Pikuri::Agent#to_s+.
    def to_s = 'Shared::ConversationTextView::Listener'

    # Mint a sub-agent sibling rendering into the *same* pane, indented one
    # {SUB_AGENT_INDENT} deeper (dispatched by
    # +Pikuri::Agent::ListenerList#for_sub_agent+ when the +agent+ tool spawns a
    # delegate). It carries its own open-stream state — the parent's buffers are
    # flushed before the tool call runs and the parent is blocked until the
    # delegate returns, so there is nothing to clobber.
    #
    # @return [Listener]
    def for_sub_agent(**)
      self.class.new(view: @view, screen: @screen, indent: @indent + SUB_AGENT_INDENT)
    end

    private

    # The actual case dispatch. Runs on the event-loop thread (via {#on_event}'s
    # +submit+) so every region mutation is under the UI lock.
    #
    # @param event [Pikuri::Agent::Event::Base]
    # @return [void]
    def dispatch_event(event)
      case event
      in Pikuri::Agent::Event::UserTurn(content:)
        @assistant.wipe
        @thinking.preserve
        @thinking_streamed = false
        @view.add_block(@view.theme.user("> #{content}"), indent: @indent)
      in Pikuri::Agent::Event::ThinkingDelta(content:)
        @assistant.wipe
        @thinking.append(content)
        @thinking_streamed = true
      in Pikuri::Agent::Event::Thinking(content:)
        if @thinking.open?
          @thinking.finalize(content)
        elsif !@thinking_streamed
          @view.add_block(@view.render_thinking(content), indent: @indent)
        end
        @thinking_streamed = false
      in Pikuri::Agent::Event::AssistantDelta(content:)
        @thinking.preserve
        @assistant.append(content)
      in Pikuri::Agent::Event::Assistant(content:)
        @thinking.preserve
        if @assistant.open?
          @assistant.finalize(content)
        else
          @view.add_block(@view.render_markdown(content), indent: @indent)
        end
      in Pikuri::Agent::Event::ToolCall(name:, arguments:)
        @assistant.wipe
        @thinking.preserve
        render_tool_call(name, arguments)
      in Pikuri::Agent::Event::ToolResult(content:)
        @assistant.wipe
        @thinking.preserve
        render_tool_result(content)
      in Pikuri::Agent::Event::SystemInjected(content:)
        @assistant.wipe
        @thinking.preserve
        render_system_injection(content)
      in Pikuri::Agent::Event::FallbackNotice(reason:)
        @assistant.wipe
        @thinking.preserve
        @view.add_block(@view.theme.notice("! #{reason}"), indent: @indent)
      in Pikuri::Agent::Event::Cancelled
        @assistant.preserve
        @thinking.preserve
        @view.add_block(@view.theme.error('! cancelled'), indent: @indent)
      in Pikuri::Agent::Event::Reset
        reset_conversation
      else
        # Tokens / ContextCap: silent here. TokenLog handles them if the host
        # registered one.
      end
    end

    # Render a {Pikuri::Agent::Event::SystemInjected} body — dim, with a ⊕
    # marker, mirroring +Pikuri::Agent::Listener::Terminal+ — collapsing the two
    # skill-shaped ones:
    #
    #   ⊕ loaded skill: writing-rdoc      # was a whole SKILL.md body
    #                                     # a promotion block renders nothing
    #
    # Both are XML-wrapped payloads sized for the model, and pasting either
    # verbatim buries the transcript under a screenful the human didn't ask for.
    # A promotion is dropped outright rather than summarized because the host
    # that promoted it announces its own line — one carrying the matched path
    # this block has no room for.
    #
    # @param content [String] the injected block.
    # @return [void]
    def render_system_injection(content)
      return if content.include?('<available_skills>')

      name = content[/\A<skill name="([^"]*)"/, 1]
      text = name ? "loaded skill: #{name}" : content
      @view.add_block(@view.theme.detail("⊕ #{text}"), indent: @indent)
    end

    # Render a {Pikuri::Agent::Event::ToolCall}. A registered formatter for
    # +name+ takes precedence and is stashed so the paired result routes back to
    # it; a missing / declining formatter falls back to +→ name(args)+ and
    # clears the pending slot.
    #
    # @param name [String]
    # @param arguments [Hash]
    # @return [void]
    def render_tool_call(name, arguments)
      formatter = @view.tool_formatters[name]
      block = formatter&.render_call(arguments: arguments, width: @view.buffer_width, theme: @view.theme)
      if block
        @pending_formatter = formatter
        @view.add_block(block, indent: @indent)
      else
        @pending_formatter = nil
        args = arguments.map { |k, v| "#{k}=#{v.inspect}" }.join(', ')
        @view.add_block(@view.theme.tool("→ #{name}(#{args})"), indent: @indent)
      end
    end

    # Render a {Pikuri::Agent::Event::ToolResult}. When the paired call was
    # formatter-handled, route to its +render_result+ (which returns +nil+ to
    # suppress a redundant success line, or a string for an error); otherwise
    # the default += result+ line.
    #
    # @param content [String]
    # @return [void]
    def render_tool_result(content)
      formatter = @pending_formatter
      @pending_formatter = nil
      if formatter
        block = formatter.render_result(content: content, theme: @view.theme)
        @view.add_block(block, indent: @indent) if block
      else
        @view.add_block(@view.theme.tool("= #{@view.truncate_tool_result(content)}"), indent: @indent)
      end
    end

    # Wipe the pane and drop every per-turn render handle on
    # {Pikuri::Agent::Event::Reset} (the host cleared the conversation). The
    # pane is cleared (detaching all regions, including any open buffers'), then
    # both blocks are +preserve+d — dropping their now-detached handles without
    # a second +region.remove+ — and the streaming / pairing slots reset to
    # construction state.
    #
    # @return [void]
    def reset_conversation
      @view.clear
      @assistant.preserve
      @thinking.preserve
      @thinking_streamed = false
      @pending_formatter = nil
    end
  end
end
