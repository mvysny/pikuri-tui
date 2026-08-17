# frozen_string_literal: true

require 'pikuri-core'
require 'tuile'

# The conversation transcript as one cohesive Tuile component: a
# {Tuile::Component::Window} that renders an agent conversation into its own
# content view — user turns, streamed reasoning, streamed assistant answers,
# tool calls, tool observations, fallback notices, cancellation markers — and
# carries a {Shared::StatusFooterUpdater} footer in its bottom border. The host
# folds the two listeners it exposes into the agent, then feeds the two values
# that only exist once the agent is built:
#
#   win = Shared::ConversationWindow.new(token_log: token_log)
#   config.add_listener(win.listener)                # transcript + model name, both
#   config.add_listener(win.status_footer_updater)   #   into the ListenerList (plus token_log)
#   win.interloper = agent.interloper                # mid-turn "N queued" segment
#   win.current_model = 'Local Qwen 3.6'
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
# == Markdown flag
#
# +markdown:+ (default +true+) gates the assistant render path: when off, the
# assistant streaming path uses {Shared::Markdown::PassthroughBuffer} and
# {#render_markdown} returns its input verbatim. The thinking pane's grayscale
# repaint is independent of the flag — a +markdown: false+ thinking buffer is
# still a {Shared::Markdown::StreamingBuffer} with a recolor-only render
# function, so the gray tint survives.
#
# The plan-mode badge is not wired here: the footer exposes +plan_active=+ via
# {#status_footer_updater}, but the +Code::PlanModeListener+ feeding it is a
# +:code+-group concern, so the coding / computer shells bind it themselves.
#
# UI-thread-confined, with exceptions (the nested {Listener} marshals the event
# stream onto the UI thread before driving these verbs; {#render_turn_error} is
# safe off-thread and self-marshals).
class Shared::ConversationWindow < Tuile::Component::Window
  # Cap, in characters, applied to tool-result content before it lands in the
  # pane. Mirrors the terminal listener's cap so the two renderers stay
  # visually consistent.
  #
  # @return [Integer]
  MAX_TOOL_RESULT_CHARS = 200

  LOG = Pikuri.logger_for('markdown')
  private_constant :LOG

  # @param token_log [Pikuri::Agent::Listener::TokenLog] the agent's token
  #   log, fed into the footer. The host must wire the *same* instance into
  #   the agent's +ListenerList+.
  # @param title [String] the window's border caption.
  # @param markdown [Boolean] when +true+ (the default), assistant content is
  #   rendered through {Shared::Markdown::Renderer}; when +false+, echoed
  #   verbatim and streamed through {Shared::Markdown::PassthroughBuffer}. The
  #   thinking path always recolors to gray.
  # @param tool_formatters [Hash{String => #render_call, #render_result}]
  #   per-tool-name formatters that replace the default +→ name(args)+ /
  #   += result+ rendering for those tools (the +edit+ / +write+ diff views).
  #   Defaults to +{}+.
  # @param model_names [Hash{Array(String, String) => String}]
  #   {Shared::Model::Choice.key} → display name, forwarded to the
  #   {Shared::StatusFooterUpdater} so a transport passed to {#current_model=}
  #   resolves to a friendly name.
  def initialize(token_log:, title: 'Conversation', markdown: true, tool_formatters: {}, model_names: {})
    super(title)
    @markdown = markdown
    @tool_formatters = tool_formatters
    @view = Tuile::Component::TextView.new
    @view.auto_scroll = true
    self.content = @view
    self.scrollbar = true
    # The footer chrome and the leaf listener this window builds directly
    # aren't components, so they take the screen explicitly — this window hands
    # them its own inherited +#screen+ property (the {Tuile::Screen} singleton,
    # fake-able via +Tuile::Screen.fake+ for tests). Its +event_queue+ marshals
    # {#render_turn_error} and drives the spinner.
    # Border chrome, not a widget slot: the Shared::StatusFooterUpdater embeds
    # the agent status into this window's bottom border (window: self).
    @status_footer_updater = Shared::StatusFooterUpdater.new(screen: screen, window: self, token_log: token_log, names: model_names)
    @listener = Listener.new(view: self, screen: screen, indent: 0)
  end

  # @return [Tuile::Component::TextView] the content view backing the
  #   transcript; exposed for tests, production drives it through {#listener}.
  attr_reader :view

  # The footer-chrome updater, which also duck-types as an agent listener
  # ({Shared::StatusFooterUpdater#on_event}) to re-point its model name on a
  # switch — fold it into the agent's +ListenerList+ alongside {#listener}.
  # The coding / computer shells also bind their {Code::PlanModeListener} to it.
  #
  # @return [Shared::StatusFooterUpdater]
  attr_reader :status_footer_updater

  # @return [Listener] the transcript listener bound to this pane, created once
  #   at construction. The host includes it in the agent's +ListenerList+;
  #   pikuri mints indented siblings off it via {Listener#for_sub_agent}.
  attr_reader :listener

  # @return [Hash{String => #render_call, #render_result}] the per-tool
  #   formatters, consulted by the {Listener} on each tool call.
  attr_reader :tool_formatters

  # @return [Tuile::Theme] the screen's current theme (re-read each call so an
  #   OS light/dark flip is picked up).
  def theme = screen.theme

  # Render width for a fresh streaming buffer: the content view's current width
  # less two columns for the scrollbar gutter, floored at 1 so a not-yet-laid-
  # out pane doesn't pass a non-positive width to {Shared::Markdown::Renderer}.
  #
  # @return [Integer]
  def buffer_width = [@view.rect.width - 2, 1].max

  # Pages the transcript up half a screen, clamped at the top.
  #
  # @return [void]
  def scroll_half_page_up = @view.scroll_half_page_up

  # Pages the transcript down half a screen; landing on the last row re-arms
  # tailing, so streamed output follows the viewport again.
  #
  # @return [void]
  def scroll_half_page_down = @view.scroll_half_page_down

  # Append one logical block to the pane: create a fresh region and assign
  # +text+ (prefixed with +indent+ spaces on its first line). Each
  # non-streaming event lands as exactly one such block.
  #
  # @param text [String, Tuile::StyledString] the block's content.
  # @param indent [Integer] leading spaces on the block's first line.
  # @return [void]
  def add_block(text, indent: 0)
    @view.create_region.text = indent_block(text, indent)
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
    region = @view.create_region
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
    region = @view.create_region
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

  # Wipe the whole transcript (detaching every region). The {Listener} calls
  # this on a +Reset+.
  #
  # @return [void]
  def clear = @view.clear

  # Hand the footer the agent's mid-turn input queue so it can render the
  # "N queued" segment.
  #
  # @param interloper [Pikuri::Agent::Control::Interloper, nil]
  # @return [void]
  def interloper=(interloper)
    @status_footer_updater.interloper = interloper
  end

  # Seed the footer's model-name segment with the boot model (a display name
  # or a transport to resolve — see {Shared::StatusFooterUpdater#current_model=});
  # the footer's own {Shared::StatusFooterUpdater#on_event} takes over on later
  # switches once it's in the +ListenerList+.
  #
  # @param model [String, Pikuri::Agent::ChatTransport, nil]
  # @return [void]
  def current_model=(model)
    @status_footer_updater.current_model = model
  end

  # Start the footer's mid-turn spinner.
  #
  # @return [void]
  def start_animation = @status_footer_updater.start_animation

  # Stop the footer's mid-turn spinner, settling it to idle.
  #
  # @return [void]
  def stop_animation = @status_footer_updater.stop_animation

  # Append a one-line, error-themed turn-failure notice to the transcript.
  # Safe to call from the agent worker thread; marshals its own append onto
  # the event-loop thread.
  #
  # @param exception [StandardError] the caught library exception.
  # @return [void]
  def render_turn_error(exception)
    screen.event_queue.submit do
      @view.add_line(screen.theme.error("! #{exception.class}: #{exception.message}"))
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
      @view.add_line(screen.theme.detail("· #{text}"))
    end
  end

  private

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
  # {Shared::ConversationWindow} render calls — the Tuile-targeted equivalent of
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

    # @param view [Shared::ConversationWindow] the pane this listener renders
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
    def to_s = 'Shared::ConversationWindow::Listener'

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
