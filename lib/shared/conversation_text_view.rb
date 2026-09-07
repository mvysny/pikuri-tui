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
# *Display* state is the pane's own, though: {#pending_decision} (the pane is
# what the answering keys arrive at), {#tool_detail}, and the redrawable-block
# register behind {#add_kinded_block} — a flag on a listener would be copied
# into every sub-agent sibling at mint time and go stale.
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
# == Tool-line form
#
# A tool call and its observation are drawn in one of two forms, flipped at
# runtime by {#toggle_tool_detail}:
#
#   Bash(rm -rf build)                      # :short — what happened
#     OK, 340 B
#   → bash(command="rm -rf build")          # :verbose — the argument dump
#     = rm: cannot remove 'build': Permis…
#
# Both live side by side in {Listener} and the flip redraws the blocks already
# in the transcript, so the raw form of a call is reachable *after* reading its
# short one. That is the whole point: a filter applied as events arrive would
# only ever reach the next call.
#
# == Reasoning visibility
#
# {#show_thinking=} shows or hides every reasoning block at once, including
# the ones already in the transcript — hidden means the region's text is
# +""+, which collapses its footprint without detaching it. While hidden the
# listener drops the delta stream outright and lets the +Thinking+ bookend
# land as a hidden block, so a reveal shows the full reasoning rather than
# whatever the deltas got through. One cost, accepted: reasoning cancelled
# mid-stream has no bookend, so hiding it and revealing it again shows only
# what had streamed.
#
# Do not "simplify" the reveal into +#clear+ plus a replay of recorded events.
# +#clear+ drops the region {#pending_decision} is asking in, so a toggle
# pressed while a confirmer question is parked would erase the question while
# the tool thread stays blocked on its answer — a hang with no visible cause.
# It would also clobber open streamed blocks mid-turn, lose a cancel's
# preserved partial, and reset the scroll.
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
  # The tool-line forms {#tool_detail=} switches between, in toggle order.
  #
  # @return [Array<Symbol>]
  TOOL_DETAIL_MODES = %i[short verbose].freeze

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
  # @param show_thinking [Boolean] whether reasoning blocks start shown
  #   (+[ui] show_thinking+); flipped at runtime by {#toggle_thinking}.
  # @param tool_detail [Symbol] the {TOOL_DETAIL_MODES} form to start on
  #   (+[ui] tool_lines+).
  # @param tool_formatters [Hash{String => #render_call, #render_result}]
  #   per-tool-name formatters that replace the default +Name(argument)+ /
  #   +OK, size+ rendering for those tools (the +edit+ / +write+ diff views).
  #   Defaults to +{}+.
  def initialize(markdown: true, show_thinking: true, tool_detail: TOOL_DETAIL_MODES.first, tool_formatters: {})
    super()
    @markdown = markdown
    @show_thinking = show_thinking
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
    @kinded_blocks = []
    self.tool_detail = tool_detail
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

  # @return [Symbol] the tool-line form currently drawn, one of
  #   {TOOL_DETAIL_MODES}.
  attr_reader :tool_detail

  # @return [Boolean] whether reasoning blocks are currently drawn.
  attr_reader :show_thinking

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

  # Append a block that can be redrawn later: +render+ is a zero-arg thunk
  # producing the block's text, filed under +kind+ so {#rerender} can re-run it
  # when the form it draws changes.
  #
  #   view.add_kinded_block(kind: :tool, indent: 2) { short? ? short_line : raw_line }
  #
  # The thunk closes over the event's content, so a redraw picks up the pane's
  # *current* width, theme and display flags.
  #
  # @param kind [Symbol] the redraw group.
  # @param indent [Integer] leading spaces on the block's first line.
  # @yieldreturn [String, Tuile::StyledString] the block's content.
  # @return [void]
  def add_kinded_block(kind:, indent: 0, &render)
    block = KindedBlock.new(region: create_region, kind: kind, indent: indent, render: render)
    @kinded_blocks << block
    draw_kinded(block)
  end

  # Redraw every block of +kind+ from its thunk, in place.
  #
  # @param kind [Symbol]
  # @return [void]
  def rerender(kind:)
    @kinded_blocks.each { |block| draw_kinded(block) if block.kind == kind }
  end

  # Show or hide every reasoning block in the transcript, this one included.
  # Hiding assigns +""+, which collapses a region's visible footprint without
  # detaching it, so the block's place — and its thunk — survive to be
  # revealed again.
  #
  # @param flag [Boolean]
  # @return [void]
  def show_thinking=(flag)
    return if @show_thinking == flag

    @show_thinking = flag
    rerender(kind: :thinking)
  end

  # @return [Boolean] the reasoning visibility now in force.
  def toggle_thinking
    self.show_thinking = !@show_thinking
    @show_thinking
  end

  # Apply a +/thinking+ argument — +on+ / +off+, or blank to toggle — and
  # report what happened for the command to echo. The echo names the config
  # key, since the flip is a session override that is never written back.
  #
  #   conversation.select_thinking('off')   # => "Thinking hidden for this session …"
  #
  # @param argument [String] the rest of the typed line.
  # @return [String] the outcome line.
  def select_thinking(argument)
    wanted = argument.strip.downcase
    return thinking_outcome(toggle_thinking) if wanted.empty?
    return "No thinking setting #{wanted.inspect} — try on / off." unless %w[on off].include?(wanted)

    self.show_thinking = wanted == 'on'
    thinking_outcome(@show_thinking)
  end

  # Switch the tool-line form and redraw the tool blocks already in the
  # transcript.
  #
  # @param mode [Symbol] one of {TOOL_DETAIL_MODES}.
  # @return [void]
  # @raise [ArgumentError] on a mode outside {TOOL_DETAIL_MODES}.
  def tool_detail=(mode)
    raise ArgumentError, "unknown tool-line form #{mode.inspect}" unless TOOL_DETAIL_MODES.include?(mode)

    @tool_detail = mode
    rerender(kind: :tool)
  end

  # Switch to the next {TOOL_DETAIL_MODES} entry, wrapping around.
  #
  # @return [Symbol] the form now in force.
  def toggle_tool_detail
    self.tool_detail = TOOL_DETAIL_MODES[(TOOL_DETAIL_MODES.index(@tool_detail) + 1) % TOOL_DETAIL_MODES.size]
    @tool_detail
  end

  # Apply a +/tools+ argument — a {TOOL_DETAIL_MODES} name, or blank to toggle
  # — and report what happened for the command to echo.
  #
  #   conversation.select_tool_detail('verbose')   # => "Tool lines: verbose."
  #   conversation.select_tool_detail('')          # => "Tool lines: short."
  #   conversation.select_tool_detail('loud')      # => "No tool-line form …"
  #
  # @param argument [String] the rest of the typed line.
  # @return [String] the outcome line.
  def select_tool_detail(argument)
    name = argument.strip.downcase
    return "Tool lines: #{toggle_tool_detail}." if name.empty?

    mode = TOOL_DETAIL_MODES.find { |candidate| candidate.to_s == name }
    return "No tool-line form #{name.inspect} — try #{TOOL_DETAIL_MODES.join(' / ')}." if mode.nil?

    self.tool_detail = mode
    "Tool lines: #{mode}."
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
  # The region is also registered as a +:thinking+ block, its thunk re-rendering
  # the buffer's own accumulated +#source+. That is what lets {#show_thinking=}
  # reach reasoning that has already streamed — whether the buffer went on to be
  # finalized, preserved, or is still open — without the pane holding a second
  # copy of the text.
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
    buffer = Shared::Markdown::StreamingBuffer.new(render: indent_render(render, indent), region: region)
    @kinded_blocks << KindedBlock.new(region: region, kind: :thinking, indent: indent,
                                      render: -> { render.call(buffer.source) })
    [region, buffer]
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

  # Drops every region, the asked decision's and the redrawable blocks'
  # included.
  #
  # @return [void]
  def clear
    super
    @kinded_blocks.clear
    @pending_decision = nil
    @decision_region = nil
    @decision_body = nil
  end

  private

  # One redrawable block: its region, the redraw group it belongs to, the
  # indent to re-apply, and the thunk producing its text.
  KindedBlock = Data.define(:region, :kind, :indent, :render)
  private_constant :KindedBlock

  # Draw one registered block, or collapse it to nothing when its kind is
  # currently hidden. The thunk is not consulted while hidden — visibility is
  # the pane's business, so a thunk only ever has to answer "what does this
  # block say".
  #
  # @param block [KindedBlock]
  # @return [void]
  def draw_kinded(block)
    text = hidden_kind?(block.kind) ? '' : block.render.call
    block.region.text = indent_block(text, block.indent)
  rescue StandardError => e
    # A reveal re-runs the Markdown renderer over reasoning that rendered fine
    # once; a kramdown surprise on the way back must not take the event loop
    # down with it. The block keeps whatever it was showing.
    LOG.warn("redrawing a #{block.kind} block failed (#{e.class}: #{e.message}); leaving it as it was")
  end

  # @param kind [Symbol]
  # @return [Boolean]
  def hidden_kind?(kind) = kind == :thinking && !@show_thinking

  # @param shown [Boolean]
  # @return [String] the +/thinking+ echo, naming the key that makes it stick.
  def thinking_outcome(shown)
    return 'Thinking shown.' if shown

    'Thinking hidden for this session — set ui.show_thinking = false in config.toml to keep it.'
  end

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
    return text if indent.zero? || text.to_s.empty?

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
  # Mirrors the terminal listener with four intentional departures:
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
  # 4. A tool call and its observation render in the pane's current
  #    {Shared::ConversationTextView::TOOL_DETAIL_MODES} form: +:short+
  #    ({#short_call_line} / {#short_result_line}) says *what happened*, which
  #    is what a transcript read while the agent works wants; +:verbose+
  #    ({#verbose_call_line} / {#verbose_result_line}) is the terminal
  #    listener's argument dump, kept for debugging. Each block goes in as a
  #    thunk, so the toggle redraws the ones already on screen. The +:short+
  #    pair is composed here only until pikuri's tools compose their own
  #    summaries, at which point it becomes a deletion.
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

    # Leading spaces a result line carries under the call line it answers, so
    # the pair reads as one block.
    #
    # @return [Integer]
    TOOL_RESULT_INDENT = 2

    # Characters of the first argument a call line shows before eliding — a
    # +command+ can be a 4 kB script.
    #
    # @return [Integer]
    TOOL_ARGUMENT_MAX_CHARS = 60

    # Characters of a failed observation's first line the +:short+ form shows
    # before eliding.
    #
    # @return [Integer]
    TOOL_ERROR_MAX_CHARS = 200

    # Characters of the observation the +:verbose+ form shows before eliding.
    # Mirrors the terminal listener's cap so the two renderers stay visually
    # consistent.
    #
    # @return [Integer]
    MAX_TOOL_RESULT_CHARS = 200

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
        # Hidden reasoning streams nowhere: no region is opened, and a stream
        # opened before the flip stops growing where it stands. The bookend
        # below carries the full text, so nothing is lost for a later reveal.
        if @view.show_thinking
          @thinking.append(content)
          @thinking_streamed = true
        end
      in Pikuri::Agent::Event::Thinking(content:)
        if @thinking.open?
          @thinking.finalize(content)
          # finalize writes straight to its region, around the pane's
          # visibility gate — put it back under the gate.
          @view.rerender(kind: :thinking) unless @view.show_thinking
        elsif !@thinking_streamed
          @view.add_kinded_block(kind: :thinking, indent: @indent) { @view.render_thinking(content) }
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
    # it; a missing / declining formatter goes in as a redrawable block picking
    # its form off {Shared::ConversationTextView#tool_detail}, and clears the
    # pending slot.
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
        @view.add_kinded_block(kind: :tool, indent: @indent) do
          short? ? short_call_line(name, arguments) : verbose_call_line(name, arguments)
        end
      end
    end

    # Render a {Pikuri::Agent::Event::ToolResult}. When the paired call was
    # formatter-handled, route to its +render_result+ (which returns +nil+ to
    # suppress a redundant success line, or a string for an error); otherwise a
    # redrawable block indented under the call it answers.
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
        @view.add_kinded_block(kind: :tool, indent: @indent + TOOL_RESULT_INDENT) do
          short? ? short_result_line(content) : verbose_result_line(content)
        end
      end
    end

    # @return [Boolean] whether the pane is currently drawing tool lines short.
    def short? = @view.tool_detail == :short

    # The +:short+ call line for a tool with no formatter of its own:
    #
    #   Bash(rm -rf build)          # name CamelCased, first argument's value
    #   EnterPlanMode               # no argument, so no parentheses
    #
    # The first *value* of +arguments+ stands in for the primary parameter:
    # models emit keys in schema order and the first schema parameter is the
    # primary one for every tool in play (+path+, +query+, +command+, +name+).
    # A stand-in until pikuri's own summaries carry the choice.
    #
    # @param name [String] the registered tool name.
    # @param arguments [Hash] the tool-call arguments.
    # @return [String] the toned line.
    def short_call_line(name, arguments)
      argument = display_argument(arguments)
      @view.theme.tool(argument.empty? ? display_name(name) : "#{display_name(name)}(#{argument})")
    end

    # The +:short+ result line for a tool with no formatter of its own:
    #
    #   OK, 4.9 kB                                        # dim
    #   Error: exit 1: rm: cannot remove 'build': …       # error-toned
    #
    # The size is the one structural fact worth carrying: it separates a +read+
    # that returned nothing from one that returned plenty. Whether the tool
    # failed is read off the +Error:+ prefix, which is a heuristic — pikuri's
    # +Tool#run+ returns recoverable failures as +"Error: …"+ strings (a genuine
    # raise aborts the turn and never reaches a +ToolResult+), but a +read+ of a
    # file whose first line starts that way misreports. Accepted until pikuri
    # sends a real summary; the +:verbose+ form shows the observation either way.
    #
    # @param content [String] the tool observation.
    # @return [String] the toned line.
    def short_result_line(content)
      text = content.to_s
      return @view.theme.detail("OK, #{format_size(text.bytesize)}") unless text.start_with?('Error:')

      @view.theme.error(cap(safe(text.lines.first.to_s), TOOL_ERROR_MAX_CHARS))
    end

    # The +:verbose+ call line — the terminal listener's argument dump,
    # +→ bash(command="rm -rf build")+. Every value goes through +inspect+,
    # which is what makes this form display-safe.
    #
    # @param name [String]
    # @param arguments [Hash]
    # @return [String] the toned line.
    def verbose_call_line(name, arguments)
      args = arguments.map { |k, v| "#{k}=#{v.inspect}" }.join(', ')
      @view.theme.tool("→ #{safe(name)}(#{args})")
    end

    # The +:verbose+ result line — the observation itself, += rm: cannot …+.
    #
    # @param content [String]
    # @return [String] the toned line.
    def verbose_result_line(content) = @view.theme.tool("= #{truncate_tool_result(content)}")

    # Flatten whitespace and cap to {MAX_TOOL_RESULT_CHARS}. Long results
    # (rendered HTML, PDF text) would otherwise drown the transcript; the
    # byte-count suffix distinguishes "tool returned exactly this" from "tool
    # returned much more."
    #
    # @param content [String] tool observation
    # @return [String] single-line display form, possibly truncated
    def truncate_tool_result(content)
      original_bytes = content.to_s.bytesize
      flattened = safe(content.to_s)
      return flattened if flattened.length <= MAX_TOOL_RESULT_CHARS

      "#{flattened[0, MAX_TOOL_RESULT_CHARS]}… (#{original_bytes} bytes total)"
    end

    # +web_search+ → +WebSearch+, +mcp__github__list_prs+ → +McpGithubListPrs+,
    # +EnterPlanMode+ → unchanged. Any run of non-alphanumerics is a word break,
    # which also leaves the result free of anything a terminal could act on.
    #
    # @param name [String]
    # @return [String]
    def display_name(name)
      words = name.to_s.scan(/[[:alnum:]]+/)
      words.empty? ? safe(name.to_s) : words.map { |word| word.sub(/\A./, &:upcase) }.join
    end

    # @param arguments [Hash] the tool-call arguments.
    # @return [String] the first value as one display-safe capped line, or +""+
    #   for a tool called with none.
    def display_argument(arguments)
      value = arguments.values.first
      value.nil? ? '' : cap(safe(value.to_s), TOOL_ARGUMENT_MAX_CHARS)
    end

    # Neutralize model-composed text and flatten it to one line.
    #
    # Sanitizing is not optional on any path that prints a value raw (the
    # +:short+ lines, the +:verbose+ observation): a path carrying +ESC[+ would
    # otherwise recolor the transcript from inside a tool argument. Only
    # {#verbose_call_line}'s arguments are safe without it, and only because
    # +inspect+ escapes them.
    #
    # @param text [String]
    # @return [String]
    def safe(text) = Pikuri::Sanitizer.sanitize(text).text.gsub(/\s+/, ' ').strip

    # Elide +text+ to +limit+ characters, ellipsis included. Applied after
    # {#safe} so a cut can't land inside an escaped +\xNN+ token.
    #
    # @param text [String]
    # @param limit [Integer]
    # @return [String]
    def cap(text, limit) = text.length <= limit ? text : "#{text[0, limit - 1]}…"

    # @param bytes [Integer]
    # @return [String] +"340 B"+ / +"4.9 kB"+ / +"1.2 MB"+ (SI, so kB is 1000).
    def format_size(bytes)
      return "#{bytes} B" if bytes < 1000
      return format('%.1f kB', bytes / 1000.0) if bytes < 1_000_000

      format('%.1f MB', bytes / 1_000_000.0)
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
