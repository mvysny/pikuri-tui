# frozen_string_literal: true

require 'pikuri-core'
require 'tuile'

# The conversation transcript as one cohesive Tuile component: a
# {Tuile::Component::TextView} that renders an agent conversation into itself —
# user turns, streamed reasoning, streamed assistant answers, tool calls, tool
# observations, cancellation markers. The host folds the listener it exposes
# into the agent:
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
# *Display* state is the pane's own, though: {#pending_decision}, because the
# pane is what the answering keys arrive at, and the display flags below with
# their block register, because a flag on a listener would be copied into every
# sub-agent sibling at mint time and go stale.
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
# == Display flags
#
# Two flags reshape what is already in the transcript, not just what arrives
# next. {#tool_detail=} picks a tool line's form:
#
#   Bash(rm -rf build)                      # :short — the tool's own summary
#     Error: exit 1: rm: cannot remove 'build'
#   → bash(command="rm -rf build")          # :verbose — the argument dump
#     = rm: cannot remove 'build': Permis…
#
# and {#show_thinking=} shows or hides every reasoning block. Both work by
# re-running each affected block's thunk ({#add_kinded_block}), because both
# answer a *retrospective* question — "that call looked wrong, show me its
# arguments". Never reach for +#clear+ plus a replay instead: +#clear+ drops
# the region a parked {#pending_decision} is asking in, so the question would
# vanish while the tool thread stays blocked on its answer.
#
# A flag reaches only what was filed under its kind, and the roster of kinds —
# +:tool+ and +:thinking+, nothing else — is the whole statement of what a
# reader may *not* turn off: user echoes, assistant prose, +⊕+ injections, +!+
# notices, cancel markers, a {Shared::PendingDecision}'s block (a parked
# decision blocks the turn, so it stays loud) and the +edit+ / +write+ diffs (a
# diff is reviewed, not skimmed) are all rendered unkinded on purpose. Filing
# one of those under a kind is what a new toggle must not do.
#
# Neither flag keeps scroll bookkeeping: Tuile clamps +scroll_top_row+ on every
# region rewrite and re-tails a following view, so collapsing a screenful under
# a scrolled-up reader lands where it should.
#
# Hiding reasoning skips only its *rendering*: the block still opens where the
# reasoning streamed and collects it, so a reveal draws it in place — above the
# answer — instead of wherever its +Thinking+ bookend happened to land. The one
# cost: a reveal mid-stream draws the prefix collected so far and then stops
# growing, and the block catches up on the next toggle.
#
# == Markdown flag
#
# +markdown:+ (default +true+) gates the assistant render path: when off, the
# assistant streaming path uses {Shared::Markdown::PassthroughBuffer} and
# {#render_markdown} returns its input verbatim. The thinking pane's grayscale
# repaint is independent of the flag — a +markdown: false+ reasoning block
# renders through a recolor-only function, so the gray tint survives.
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

  # Columns the scrollbar claims off the right edge once shown: its glyph and
  # the blank Tuile keeps beside it.
  #
  # @return [Integer]
  BAR_COLUMNS = 2

  LOG = Pikuri.logger_for('markdown')
  private_constant :LOG

  # @param markdown [Boolean] when +true+ (the default), assistant content is
  #   rendered through {Shared::Markdown::Renderer}; when +false+, echoed
  #   verbatim and streamed through {Shared::Markdown::PassthroughBuffer}. The
  #   thinking path always recolors to gray.
  # @param show_thinking [Boolean] whether reasoning blocks start shown.
  # @param tool_detail [Symbol] the {TOOL_DETAIL_MODES} form to start on.
  # @param tool_formatters [Hash{String => #render_call, #render_result}]
  #   per-tool-name formatters that replace the default +Name(argument)+ /
  #   summary rendering for those tools (the +edit+ / +write+ diff views).
  #   Defaults to +{}+.
  def initialize(markdown: true, show_thinking: true, tool_detail: TOOL_DETAIL_MODES.first, tool_formatters: {})
    super()
    @markdown = markdown
    @show_thinking = show_thinking
    @tool_formatters = tool_formatters
    self.auto_scroll = true
    # Genuinely scrollable, by the prompt's PageUp/PageDown; the bar shows only
    # once the transcript overflows, so a short one has no idle track.
    self.scrollbar_visibility = :auto
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
  end

  # @return [Listener] the transcript listener bound to this pane, created once
  #   at construction. The host includes it in the agent's +ListenerList+;
  #   pikuri mints indented siblings off it via {Listener#for_sub_agent}.
  attr_reader :listener

  # @return [Shared::PendingDecision, nil] the decision this pane is currently
  #   asking, +nil+ when there is none. While set, {#handle_key?} claims that
  #   decision's keys.
  attr_reader :pending_decision

  # What {#on_escape} fires.
  #
  # @!attribute [r] source
  #   @return [Shared::ConversationTextView] the pane the user is leaving.
  EscapeEvent = Data.define(:source) { include Tuile::Event }

  # @!method on_escape
  #   Fired with an {EscapeEvent} when the user leaves this pane
  #   ({LEAVE_KEYS}) — normally "put focus back on the prompt".
  #
  #   **Empty means the pane declines those keys**, so they fall through
  #   unclaimed and the event loop stops on them.
  #   @return [Tuile::Listeners]
  listener :on_escape

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

  # Render width for a fresh block: the pane's width less {BAR_COLUMNS} whether
  # or not the +:auto+ bar is showing yet. A block is rendered once, so one
  # rendered at the full width would rewrap — a padded diff bar into two rows —
  # the moment the transcript overflows and the bar takes its columns. Floored
  # at 1 so a not-yet-laid-out pane doesn't pass a non-positive width to
  # {Shared::Markdown::Renderer}.
  #
  # @return [Integer]
  def buffer_width = [rect.width - BAR_COLUMNS, 1].max

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
  #   view.add_kinded_block(kind: :tool, indent: @indent) do
  #     short? ? short_call_line(name, arguments) : verbose_call_line(name, arguments)
  #   end
  #
  # Closing over the event's content is what makes a redraw pick up the pane's
  # *current* width, theme and flags. A thunk answers only "what does this block
  # say" — whether the kind is currently hidden is the pane's business, and a
  # hidden one is never called.
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

  # Show or hide every reasoning block, the ones already in the transcript
  # included. Hiding assigns +""+, which collapses a region's visible footprint
  # without detaching it, so the block's place — and its thunk — survive.
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

  # Apply a +/thinking+ argument — +on+ / +off+, or blank to toggle — and report
  # what happened for the command to echo.
  #
  #   conversation.select_thinking('off')   # => "Thinking hidden for this session …"
  #
  # The echo names the config key, since a flip lasts only for the session.
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

  # Twin of {#open_assistant_block} for the reasoning pane, tinted gray in both
  # Markdown modes: the render is {Shared::Markdown::Renderer}→recolor when
  # Markdown is on, recolor-only when off. The reasoning tone is snapshot at
  # build time, like the width.
  #
  # Hidden reasoning still opens its region — so the block holds the place the
  # reasoning *streamed* at, not the place its +Thinking+ bookend arrives at,
  # which is after the answer — but takes a
  # {Shared::Markdown::CollectingBuffer}: the deltas pile up unrendered until a
  # reveal.
  #
  # The region registers as a +:thinking+ block whose thunk re-renders the
  # buffer's own +#source+ — which is what lets {#show_thinking=} reach
  # reasoning that already streamed, whether its buffer went on to be finalized,
  # preserved, or is still open.
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
    buffer = if @show_thinking
               Shared::Markdown::StreamingBuffer.new(render: indent_render(render, indent), region: region)
             else
               Shared::Markdown::CollectingBuffer.new
             end
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
  def handle_key?(key)
    return true if choose(key)

    if LEAVE_KEYS.include?(key) && !on_escape.empty?
      on_escape.fire(EscapeEvent.new(source: self))
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
  # hidden.
  #
  # @param block [KindedBlock]
  # @return [void]
  def draw_kinded(block)
    text = hidden_kind?(block.kind) ? '' : block.render.call
    block.region.text = indent_block(text, block.indent)
  rescue StandardError => e
    # A reveal re-runs the Markdown renderer over content that rendered fine
    # once, so this catches a kramdown surprise on the way back.
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
  # The screen holds {Shared::AppTheme::DARK} or {Shared::AppTheme::LIGHT}
  # resolved against its background (their tints are derived tokens), so
  # equality against +LIGHT+ resolved the same way is the live scheme — a
  # transient +Tuile::Screen#theme=+ included, which
  # +Tuile::Screen#color_scheme+ would miss.
  #
  # @return [Boolean]
  def dark_scheme? = screen.theme != Shared::AppTheme::LIGHT.resolve(screen.background_color)

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
  # 4. Tool lines default to the short +Bash(rm -rf build)+ /
  #    +Returned 3 lines+ pair — the strings the *tool* composed, styled and
  #    capped here. The terminal listener's argument dump survives as the
  #    pane's +:verbose+ form.
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
    # stream reads as indented under the parent's +Agent(...)+ call. Mirrors
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

    # Characters of a call's argument the +:short+ form shows before eliding —
    # a +command+ can be a 4 kB script.
    #
    # @return [Integer]
    TOOL_ARGUMENT_MAX_CHARS = 60

    # Characters of a tool's name or its result summary the +:short+ form
    # shows before eliding.
    #
    # @return [Integer]
    TOOL_SUMMARY_MAX_CHARS = 200

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
        @thinking.append(content)
        @thinking_streamed = true
      in Pikuri::Agent::Event::Thinking(content:)
        if @thinking.open?
          @thinking.finalize(content)
          # A block opened while shown and hidden since finalizes straight into
          # its region, around the pane's gate.
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
      in Pikuri::Agent::Event::ToolCall(name:, arguments:, display_name:, argument:)
        @assistant.wipe
        @thinking.preserve
        render_tool_call(name: name, arguments: arguments,
                         display_name: display_name, argument: argument)
      in Pikuri::Agent::Event::ToolResult(content:, summary:)
        @assistant.wipe
        @thinking.preserve
        render_tool_result(content: content, summary: summary)
      in Pikuri::Agent::Event::SystemInjected(content:)
        @assistant.wipe
        @thinking.preserve
        render_system_injection(content)
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
    # @param name [String] the registered tool name.
    # @param arguments [Hash] the raw tool-call arguments.
    # @param display_name [String] the tool's own +Bash+ / +WebSearch+ label.
    # @param argument [String] the tool's own one-argument description.
    # @return [void]
    def render_tool_call(name:, arguments:, display_name:, argument:)
      formatter = @view.tool_formatters[name]
      block = formatter&.render_call(arguments: arguments, width: @view.buffer_width, theme: @view.theme)
      if block
        @pending_formatter = formatter
        @view.add_block(block, indent: @indent)
      else
        @pending_formatter = nil
        @view.add_kinded_block(kind: :tool, indent: @indent) do
          short? ? short_call_line(display_name, argument) : verbose_call_line(name, arguments)
        end
      end
    end

    # Render a {Pikuri::Agent::Event::ToolResult}. When the paired call was
    # formatter-handled, route to its +render_result+ (which returns +nil+ to
    # suppress a redundant success line, or a string for an error); otherwise a
    # redrawable block indented under the call it answers.
    #
    # @param content [String] the observation the model reads.
    # @param summary [String] the tool's own one-line status.
    # @return [void]
    def render_tool_result(content:, summary:)
      formatter = @pending_formatter
      @pending_formatter = nil
      if formatter
        block = formatter.render_result(summary: summary, theme: @view.theme)
        @view.add_block(block, indent: @indent) if block
      else
        @view.add_kinded_block(kind: :tool, indent: @indent + TOOL_RESULT_INDENT) do
          short? ? short_result_line(summary) : verbose_result_line(content)
        end
      end
    end

    # @return [Boolean] whether the pane is currently drawing tool lines short.
    def short? = @view.tool_detail == :short

    # The +:short+ call line for a tool with no formatter of its own:
    #
    #   Bash(rm -rf build)
    #   EnterPlanMode               # empty argument, so no parentheses
    #
    # @param display_name [String] +Pikuri::Tool#display_name+.
    # @param argument [String] +Pikuri::Tool#describe_call+.
    # @return [String] the toned line.
    def short_call_line(display_name, argument)
      label = cap(safe(display_name), TOOL_SUMMARY_MAX_CHARS)
      text = argument.to_s.empty? ? label : "#{label}(#{cap(safe(argument), TOOL_ARGUMENT_MAX_CHARS)})"
      @view.theme.tool(text)
    end

    # The +:short+ result line for a tool with no formatter of its own — dim,
    # or error-toned when the summary reports a failure:
    #
    #   Returned 23 search results
    #   Error: exit 1: rm: cannot remove 'build'
    #
    # The +Error:+ test reads the tool's own status rather than guessing at the
    # observation: pikuri composes that prefix in +Tool::Result.error+.
    #
    # @param summary [String] +Pikuri::Agent::Event::ToolResult#summary+.
    # @return [String] the toned line.
    def short_result_line(summary)
      text = cap(safe(summary), TOOL_SUMMARY_MAX_CHARS)
      text.start_with?('Error:') ? @view.theme.error(text) : @view.theme.detail(text)
    end

    # The +:verbose+ call line — the terminal listener's argument dump,
    # +→ bash(command="rm -rf build")+. The arguments skip {#safe} because
    # +inspect+ already escapes them.
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

    # Neutralize model-composed text and flatten it to one line. Every path that
    # prints a tool value raw owes the transcript this call: a filename carrying
    # +ESC[+ recolors everything after it otherwise.
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
