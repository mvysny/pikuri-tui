# frozen_string_literal: true

require 'pikuri-core'
require 'tuile'

# The conversation transcript pane: a {Tuile::Component::TextView} subclass
# that owns the *vocabulary* for rendering an agent conversation — user
# turns, streamed reasoning, streamed assistant answers, tool calls, tool
# observations, fallback notices, cancellation markers — plus the render
# config (Markdown on/off, per-tool diff formatters). It renders each
# logical block into its own {Tuile::Component::TextView::Region} so earlier
# sections keep their content independently of what comes after ("wipe an
# unfinished preview" is +region.remove+; "preserve on cancel" is "drop the
# buffer handle").
#
# The pikuri seam lives in the nested {Listener}, not here: this component
# exposes UI verbs ({#add_block}, {#build_assistant_buffer},
# {#render_markdown}, …) and knows nothing about +Pikuri::Agent::Event+. The
# {Listener} is the sole translator from the event stream into these verbs.
# That split follows AGENTS.md's "Design with components": the widget owns
# "how a conversation is drawn," and the listener is a thin event→verb
# adapter.
#
# == State ownership
#
# This component is *stateless* with respect to a conversation's progress:
# it holds no "currently-open block" cursor. Each {Listener} carries its own
# open-stream state (the assistant/thinking streaming buffers, the
# tool-call/result pairing) and drives this component's stateless helpers.
# That is what lets a sub-agent be "another thin listener with a bigger
# indent" writing into this same pane without sharing the parent's open
# blocks (see {Listener#for_sub_agent}).
#
# == Markdown flag
#
# +markdown:+ (default +true+) gates the assistant render path: when off,
# the assistant streaming path uses {Shared::Markdown::PassthroughBuffer}
# and {#render_markdown} returns its input verbatim. The thinking pane's
# grayscale repaint is independent of the flag — a +markdown: false+
# thinking buffer is still a {Shared::Markdown::StreamingBuffer} with a
# recolor-only render function, so the gray tint survives.
class Shared::ConversationTextView < Tuile::Component::TextView
  # Cap, in characters, applied to tool-result content before it lands in
  # the pane. Mirrors the terminal listener's cap so the two renderers stay
  # visually consistent.
  #
  # @return [Integer]
  MAX_TOOL_RESULT_CHARS = 200

  LOG = Pikuri.logger_for('markdown')
  private_constant :LOG

  # @param markdown [Boolean] when +true+ (the default), assistant content
  #   is rendered through {Shared::Markdown::Renderer}. When +false+, the
  #   assistant path echoes content verbatim and streams through
  #   {Shared::Markdown::PassthroughBuffer}. The thinking path always recolors
  #   to gray.
  # @param tool_formatters [Hash{String => #render_call, #render_result}]
  #   per-tool-name formatters that replace the default +→ name(args)+ /
  #   += result+ rendering for those tools (the +edit+ / +write+ diff views).
  #   Defaults to +{}+.
  def initialize(markdown: true, tool_formatters: {})
    super()
    self.auto_scroll = true
    @markdown = markdown
    @tool_formatters = tool_formatters
    # Resolve the Screen singleton once for theme access + the listener's
    # event-queue marshaling (fake-able via +Tuile::Screen.fake+), the same
    # way {Shared::ConversationWindow} does.
    @screen = Tuile::Screen.instance
    @listener = Listener.new(view: self, screen: @screen, indent: 0)
  end

  # @return [Shared::ConversationTextView::Listener] the main-agent listener
  #   bound to this pane, created once at construction. The host includes it
  #   in the agent's +ListenerList+; pikuri mints indented siblings off it
  #   via {Listener#for_sub_agent}.
  attr_reader :listener

  # @return [Hash{String => #render_call, #render_result}] the per-tool
  #   formatters, consulted by the {Listener} on each tool call.
  attr_reader :tool_formatters

  # @return [Tuile::Theme] the screen's current theme (re-read each call so
  #   an OS light/dark flip is picked up).
  def theme = @screen.theme

  # Render width for a fresh streaming buffer: the pane's current width less
  # two columns for the scrollbar gutter, floored at 1 so a not-yet-laid-out
  # pane doesn't pass a non-positive width to {Shared::Markdown::Renderer}.
  #
  # @return [Integer]
  def buffer_width = [rect.width - 2, 1].max

  # Append one logical block to the pane: create a fresh region and assign
  # +text+ (prefixed with +indent+ spaces on its first line). Each
  # non-streaming event lands as exactly one such block.
  #
  # @param text [String, Tuile::StyledString] the block's content, possibly
  #   with embedded ANSI styling / hard +\n+ lines.
  # @param indent [Integer] leading spaces on the block's first line (0 for
  #   the main agent, {Listener::SUB_AGENT_INDENT} for a sub-agent).
  # @return [void]
  def add_block(text, indent: 0)
    create_region.text = indent_block(text, indent)
  end

  # Build a streaming buffer bound to +region+ for the assistant answer. A
  # {Shared::Markdown::StreamingBuffer} (Markdown → ANSI) when +@markdown+,
  # else a {Shared::Markdown::PassthroughBuffer}. The render proc snapshots
  # the width + terminal scheme at build time (one buffer per block), so an
  # appearance flip mid-block keeps the scheme it started with.
  #
  # @param region [Tuile::Component::TextView::Region]
  # @param indent [Integer] leading spaces baked into the render proc.
  # @return [Shared::Markdown::StreamingBuffer, Shared::Markdown::PassthroughBuffer]
  def build_assistant_buffer(region, indent: 0)
    if @markdown
      Shared::Markdown::StreamingBuffer.new(render: indent_render(build_markdown_renderer, indent), region: region)
    else
      Shared::Markdown::PassthroughBuffer.new(region: region)
    end
  end

  # Twin of {#build_assistant_buffer} for the reasoning pane. Always a
  # {Shared::Markdown::StreamingBuffer}: the render is
  # {Shared::Markdown::Renderer}→recolor when Markdown is on, recolor-only
  # when off — so the gray tint applies in both modes. The reasoning tone is
  # snapshot at build time, like the width.
  #
  # @param region [Tuile::Component::TextView::Region]
  # @param indent [Integer] leading spaces baked into the render proc.
  # @return [Shared::Markdown::StreamingBuffer]
  def build_thinking_buffer(region, indent: 0)
    thinking = @screen.theme[:thinking]
    render = if @markdown
               markdown = build_markdown_renderer
               ->(md) { Shared::Markdown::Grayscale.recolor(markdown.call(md), fg: thinking) }
             else
               ->(md) { Shared::Markdown::Grayscale.recolor(md, fg: thinking) }
             end
    Shared::Markdown::StreamingBuffer.new(render: indent_render(render, indent), region: region)
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
  # the theme's single muted reasoning tone (structure preserved). Used when
  # a {Pikuri::Agent::Event::Thinking} arrives with no preceding deltas.
  #
  # @param content [String] reasoning Markdown
  # @return [String] gray-toned ANSI text
  def render_thinking(content)
    Shared::Markdown::Grayscale.recolor(render_markdown(content), fg: @screen.theme[:thinking])
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

  # Wrap a +String -> String+ render proc so its output carries +indent+
  # spaces on the first line. A no-op (returns the proc unchanged) for the
  # main agent. The {Shared::Markdown::StreamingBuffer}'s commit-probe
  # sentinel is unaffected: the pad lands on the first line, the sentinel on
  # the last.
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
  # constant its {Tuile::ThemeDef} resolved, so identity against +LIGHT+ is
  # the live scheme.
  #
  # @return [Boolean]
  def dark_scheme? = !@screen.theme.equal?(Shared::AppTheme::LIGHT)

  # Translates a +Pikuri::Agent+'s normalized event stream into
  # {Shared::ConversationTextView} render calls — the Tuile-targeted
  # equivalent of +Pikuri::Agent::Listener::Terminal+, rendering into the
  # conversation pane instead of stdout.
  #
  # This holds the per-conversation *state* the component deliberately does
  # not: the open assistant streaming buffer + region, the open thinking
  # buffer + region, the streamed-thinking flag, and the tool-call/result
  # pairing slot. Everything visual is delegated to the view's stateless
  # verbs. Because the state lives here (not on the shared view), a
  # sub-agent listener minted by {#for_sub_agent} renders into the same pane
  # with its own independent open blocks.
  #
  # == Variant coverage
  #
  # Mirrors the terminal listener with three intentional departures:
  #
  # 1. {Pikuri::Agent::Event::UserTurn} renders as +"> #{content}"+ instead
  #    of staying silent — submitting clears the input, so without an echo
  #    the user's message would vanish.
  # 2. Library failures during rendering are caught + logged (by the view's
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
  # == Threading
  #
  # {#on_event} fires on the agent's worker thread; it wraps the whole
  # dispatch in +screen.event_queue.submit+ so every region mutation runs on
  # the event-loop thread under the UI lock. The queue is FIFO, so events
  # still land in order.
  class Listener < Pikuri::Agent::Listener::Base
    # Leading spaces a sub-agent's listener prepends to every block, so its
    # stream reads as indented under the parent's +→ agent(...)+ call.
    # Mirrors +Pikuri::Agent::Listener::Terminal+'s +SUB_AGENT_PADDING+. The
    # pad lands on the first line only; sub-agent recursion is blocked
    # (depth never exceeds 1), so a fixed indent reads cleanly.
    #
    # @return [Integer]
    SUB_AGENT_INDENT = 2

    # @param view [Shared::ConversationTextView] the pane this listener
    #   renders into. Lifetime owned by the view; the listener neither
    #   constructs nor destroys it.
    # @param screen [Tuile::Screen] the screen whose +event_queue+ marshals
    #   UI mutations back from the worker thread. Passed explicitly so the
    #   listener can be unit-tested with a {Tuile::FakeScreen}.
    # @param indent [Integer] leading spaces prepended to every block (0 for
    #   the main agent, {SUB_AGENT_INDENT} on a {#for_sub_agent} sibling).
    def initialize(view:, screen:, indent: 0)
      super()
      @view = view
      @screen = screen
      @indent = indent
      @buffer = nil
      @assistant_region = nil
      @thinking_buffer = nil
      @thinking_region = nil
      @thinking_streamed = false
      # Set on a ToolCall a formatter handled, consumed by the next
      # ToolResult to pair the result with that call. ruby_llm runs tool
      # calls strictly call→result→call→result, so a single slot is exact.
      @pending_formatter = nil
    end

    # Dispatch one event to the pane, marshaled onto the event-loop thread
    # so the downstream region mutations execute under the UI lock.
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
    # +Pikuri::Agent::ListenerList#for_sub_agent+ when the +agent+ tool
    # spawns a delegate). It carries its own open-stream state — the parent's
    # buffers are flushed before the tool call runs and the parent is blocked
    # until the delegate returns, so there is nothing to clobber.
    #
    # @return [Shared::ConversationTextView::Listener]
    def for_sub_agent(**)
      self.class.new(view: @view, screen: @screen, indent: @indent + SUB_AGENT_INDENT)
    end

    private

    # The actual case dispatch. Runs on the event-loop thread (via
    # {#on_event}'s +submit+) so every region mutation is under the UI lock.
    #
    # @param event [Pikuri::Agent::Event::Base]
    # @return [void]
    def dispatch_event(event)
      case event
      in Pikuri::Agent::Event::UserTurn(content:)
        flush_assistant(:wipe)
        release_thinking
        @thinking_streamed = false
        @view.add_block(@view.theme.user("> #{content}"), indent: @indent)
      in Pikuri::Agent::Event::ThinkingDelta(content:)
        flush_assistant(:wipe)
        @thinking_region ||= @view.create_region
        @thinking_buffer ||= @view.build_thinking_buffer(@thinking_region, indent: @indent)
        @thinking_buffer.append(content)
        @thinking_streamed = true
      in Pikuri::Agent::Event::Thinking(content:)
        if @thinking_buffer
          @thinking_buffer.finalize(content)
          release_thinking
        elsif !@thinking_streamed
          @view.add_block(@view.render_thinking(content), indent: @indent)
        end
        @thinking_streamed = false
      in Pikuri::Agent::Event::AssistantDelta(content:)
        release_thinking
        @assistant_region ||= @view.create_region
        @buffer ||= @view.build_assistant_buffer(@assistant_region, indent: @indent)
        @buffer.append(content)
      in Pikuri::Agent::Event::Assistant(content:)
        release_thinking
        if @buffer
          @buffer.finalize(content)
          @buffer = nil
          @assistant_region = nil
        else
          @view.add_block(@view.render_markdown(content), indent: @indent)
        end
      in Pikuri::Agent::Event::ToolCall(name:, arguments:)
        flush_assistant(:wipe)
        release_thinking
        render_tool_call(name, arguments)
      in Pikuri::Agent::Event::ToolResult(content:)
        flush_assistant(:wipe)
        release_thinking
        render_tool_result(content)
      in Pikuri::Agent::Event::FallbackNotice(reason:)
        flush_assistant(:wipe)
        release_thinking
        @view.add_block(@view.theme.notice("! #{reason}"), indent: @indent)
      in Pikuri::Agent::Event::Cancelled
        flush_assistant(:preserve)
        release_thinking
        @view.add_block(@view.theme.error('! cancelled'), indent: @indent)
      in Pikuri::Agent::Event::Reset
        reset_conversation
      else
        # Tokens / ContextCap: silent here. TokenLog handles them if the
        # host registered one.
      end
    end

    # Render a {Pikuri::Agent::Event::ToolCall}. A registered formatter for
    # +name+ takes precedence and is stashed so the paired result routes back
    # to it; a missing / declining formatter falls back to +→ name(args)+ and
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

    # Close out the assistant streaming buffer. +:wipe+ removes the streamed
    # region entirely (a +ToolCall+ / +UserTurn+ / etc. arrived mid-stream);
    # +:preserve+ drops the handle but keeps the region's content (the
    # cancel-preserve case).
    #
    # @param mode [:wipe, :preserve]
    # @return [void]
    def flush_assistant(mode)
      return unless @buffer

      case mode
      when :wipe
        @assistant_region.remove
      when :preserve
        # Region keeps its content; drop the handle below.
      else
        raise ArgumentError, "expected :wipe or :preserve, got #{mode.inspect}"
      end
      @buffer = nil
      @assistant_region = nil
    end

    # Drop the thinking buffer + region handles (no UI mutation — the region
    # keeps its rendered content). Called from every handler except
    # +ThinkingDelta+ so the next +ThinkingDelta+ opens a fresh region.
    #
    # @return [void]
    def release_thinking
      @thinking_buffer = nil
      @thinking_region = nil
    end

    # Wipe the pane and drop every per-turn render handle on
    # {Pikuri::Agent::Event::Reset} (the host cleared the conversation). The
    # view is cleared (detaching all regions, including any open buffers'),
    # and the streaming / pairing slots reset to construction state.
    #
    # @return [void]
    def reset_conversation
      @view.clear
      @buffer = nil
      @assistant_region = nil
      @thinking_buffer = nil
      @thinking_region = nil
      @thinking_streamed = false
      @pending_formatter = nil
    end
  end
end
