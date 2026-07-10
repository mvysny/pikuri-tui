# frozen_string_literal: true

require 'pikuri-core'

module PikuriTui
  # Tuile-targeted equivalent of +Pikuri::Agent::Listener::Terminal+: renders
  # the normalized event stream into a {Tuile::Component::TextView} (the
  # conversation pane) instead of stdout.
  #
  # Each logical block — user turn, streamed reasoning, streamed assistant
  # answer, tool call, tool result, fallback notice, cancellation marker —
  # lives in its own {Tuile::Component::TextView::Region}. The listener
  # creates a region per block and assigns its content (or, for streaming,
  # hands the region to a {StreamingMarkdownBuffer} / {PassthroughBuffer}
  # that rewrites it on each delta). Per-block region addressing lets
  # earlier sections keep their content independently of what comes after:
  # the "wipe an unfinished preview" path becomes +region.remove+ and
  # "preserve the streamed text on cancel" becomes "just drop the buffer
  # handle."
  #
  # The agent's loop runs on a worker thread (Tuile owns the UI thread),
  # and the streaming buffers mutate their regions directly — which
  # requires the UI lock. {#on_event} therefore wraps the whole dispatch
  # in +screen.event_queue.submit+ so every region mutation runs on the
  # event-loop thread; the queue is FIFO, so events still land in order.
  #
  # Variant coverage mirrors the terminal listener with three intentional
  # departures:
  #
  # 1. {Pikuri::Agent::Event::UserTurn} is rendered as +"> #{content}"+
  #    instead of being silent. The CLI's reasoning ("the user just typed
  #    this") doesn't apply here — submitting clears the input area, so
  #    without an echo the user's message vanishes.
  # 2. Library failures during rendering (kramdown / rouge choking on
  #    assistant output) are caught and logged through the +'listener'+
  #    pikuri logger instead of bubbling out — an uncaught raise on the worker thread
  #    would silently kill the agent loop. Same "library exceptions are
  #    logged, our bugs raise" rule documented in CLAUDE.md.
  # 3. Streaming events ({Pikuri::Agent::Event::AssistantDelta} /
  #    {Pikuri::Agent::Event::ThinkingDelta}) are both rendered
  #    incrementally through a {StreamingMarkdownBuffer} wired to a
  #    dedicated region. The thinking buffer's renderer is wrapped with
  #    {AnsiGrayscale.recolor} so reasoning paints in one muted-gray
  #    tone with bold/italic/underline structure preserved — visually
  #    distinct from the assistant's full-color answer. When the
  #    bookend {Pikuri::Agent::Event::Thinking} arrives after deltas
  #    its content is handed to +StreamingMarkdownBuffer#finalize+
  #    on the open thinking buffer — same shape as the assistant
  #    bookend handler. The fast-path equality check inside
  #    +#finalize+ makes the common "deltas already match" case a
  #    no-op, but when the delta stream is incomplete (provider
  #    truncated the tail, network dropped a delta) the
  #    authoritative content replaces the preview so the user sees
  #    the full reasoning. On the non-streaming path (no deltas
  #    emitted) the bookend renders directly as grayscale Markdown.
  #
  # +Tokens+ and +ContextCap+ stay silent (their consumer is
  # +Pikuri::Agent::Listener::TokenLog+, which the host adds separately
  # if it wants token accounting in the diagnostic log).
  #
  # The Markdown render is gated on a +markdown:+ ctor flag (default
  # +true+). When the host wires +markdown: false+, the assistant
  # streaming path uses {PassthroughBuffer} and the non-streaming
  # assistant path skips {MarkdownRenderer} — content goes to the +TextView+
  # verbatim. The thinking pane's grayscale repaint is independent of
  # the toggle: a +markdown: false+ thinking buffer is still a
  # {StreamingMarkdownBuffer} but with a recolor-only render function,
  # so the gray tint survives.
  class TuileListener < Pikuri::Agent::Listener::Base
    # Cap, in characters, applied to tool-result content before it lands in
    # the conversation pane. Mirrors the terminal listener's cap so the two
    # renderers stay visually consistent.
    #
    # @return [Integer]
    MAX_TOOL_RESULT_CHARS = 200

    # Leading spaces prepended to every block a sub-agent's listener
    # renders, so its stream reads as visually indented under the parent's
    # +→ agent(...)+ call. Mirrors +Pikuri::Agent::Listener::Terminal+'s
    # +SUB_AGENT_PADDING+. The pad lands on the block's first line only —
    # wrapped continuation lines and the streamed markdown body aren't
    # re-indented per line (the render width is unchanged), which is the
    # agreed, cheap "first line pads" treatment. Sub-agent recursion is
    # blocked (a persona's tool set excludes +agent+), so depth never
    # exceeds 1 and a fixed indent reads cleanly.
    #
    # @return [Integer]
    SUB_AGENT_INDENT = 2

    LOG = Pikuri.logger_for('listener')
    private_constant :LOG

    # @param text_view [Tuile::Component::TextView] the conversation pane
    #   to render rendered events into. Lifetime is owned by the host
    #   ({PikuriTui::Chat::App}); the listener doesn't construct or
    #   destroy it.
    # @param screen [Tuile::Screen] the screen whose +event_queue+ marshals
    #   UI mutations back from the agent's worker thread. Passed explicitly
    #   (rather than reached for via +Tuile::Screen.instance+) so tests can
    #   inject a {Tuile::FakeScreen} without having to install it as the
    #   singleton at construction time.
    # @param markdown [Boolean] when +true+ (the default), assistant
    #   content is rendered through {MarkdownRenderer}. When +false+, the
    #   listener skips Markdown rendering for the assistant path —
    #   non-streaming events echo their content verbatim and the streaming
    #   path uses {PassthroughBuffer}. The thinking path always recolors
    #   to gray and so always goes through a {StreamingMarkdownBuffer}
    #   (with the renderer set to {MarkdownRenderer}→recolor or
    #   recolor-only, depending on the flag).
    # @param tool_formatters [Hash{String => #render_call, #render_result}]
    #   per-tool-name formatters that replace the default +→ name(args)+ /
    #   += result+ rendering for those tools. On a {Pikuri::Agent::Event::ToolCall}
    #   whose +name+ is a key, the formatter's +render_call+ produces the
    #   call block (the diff view for +edit+ / +write+); the paired
    #   {Pikuri::Agent::Event::ToolResult} is then routed to the same
    #   formatter's +render_result+ (which returns +nil+ to suppress a
    #   redundant success line, or a string for an error). Both hooks may
    #   return +nil+ to fall back to the default rendering. Defaults to +{}+
    #   — the chat shell registers none, so its behavior is unchanged.
    # @param indent [Integer] leading spaces prepended to every rendered
    #   block (see {SUB_AGENT_INDENT}). +0+ for the main agent; set to
    #   {SUB_AGENT_INDENT} on the instance {#for_sub_agent} returns so a
    #   delegate's output is indented under the parent's stream.
    def initialize(text_view:, screen:, markdown: true, tool_formatters: {}, indent: 0)
      super()
      @text_view = text_view
      @screen = screen
      @markdown = markdown
      @tool_formatters = tool_formatters
      @indent = indent
      @pad = ' ' * indent
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

    # Dispatches one event to the conversation pane. Called from the
    # agent's worker thread; the whole dispatch is marshaled onto the
    # event-loop thread via +screen.event_queue.submit+ so the
    # downstream region mutations execute under the UI lock.
    #
    # @param event [Pikuri::Agent::Event::UserTurn,
    #   Pikuri::Agent::Event::Thinking, Pikuri::Agent::Event::ThinkingDelta,
    #   Pikuri::Agent::Event::Assistant, Pikuri::Agent::Event::AssistantDelta,
    #   Pikuri::Agent::Event::ToolCall, Pikuri::Agent::Event::ToolResult,
    #   Pikuri::Agent::Event::FallbackNotice, Pikuri::Agent::Event::Cancelled,
    #   Pikuri::Agent::Event::Reset, Pikuri::Agent::Event::Tokens,
    #   Pikuri::Agent::Event::ContextCap]
    # @return [void]
    def on_event(event)
      @screen.event_queue.submit { dispatch_event(event) }
    end

    # @return [String] short label used by +Pikuri::Agent#to_s+ when this
    #   listener is in its +ListenerList+.
    def to_s = 'TuileListener'

    # Sub-agent variant (dispatched by +Pikuri::Agent::ListenerList#for_sub_agent+
    # when the +agent+ tool spawns a delegate): a fresh listener rendering into
    # the *same* conversation pane but with its output indented by
    # {SUB_AGENT_INDENT}, so a RESEARCHER's stream reads as nested under the
    # parent's +→ agent(...)+ call. It carries its own streaming/thinking state
    # (the parent's buffers are flushed before the tool call runs and the parent
    # is blocked until the delegate returns, so there's nothing to clobber) and
    # shares the parent's +markdown+ / +tool_formatters+ config.
    #
    # @return [TuileListener]
    def for_sub_agent(**)
      self.class.new(
        text_view: @text_view,
        screen: @screen,
        markdown: @markdown,
        tool_formatters: @tool_formatters,
        indent: SUB_AGENT_INDENT
      )
    end

    private

    # The actual case dispatch. Runs on the event-loop thread (via
    # {#on_event}'s +submit+) so every region mutation here is under the
    # UI lock.
    #
    # @param event [Pikuri::Agent::Event::Base]
    # @return [void]
    def dispatch_event(event)
      case event
      in Pikuri::Agent::Event::UserTurn(content:)
        flush_assistant(:wipe)
        release_thinking
        @thinking_streamed = false
        add_block(@screen.theme.user("> #{content}"))
      in Pikuri::Agent::Event::ThinkingDelta(content:)
        flush_assistant(:wipe)
        @thinking_region ||= @text_view.create_region
        @thinking_buffer ||= make_thinking_buffer(@thinking_region)
        @thinking_buffer.append(content)
        @thinking_streamed = true
      in Pikuri::Agent::Event::Thinking(content:)
        if @thinking_buffer
          @thinking_buffer.finalize(content)
          release_thinking
        elsif !@thinking_streamed
          add_block(AnsiGrayscale.recolor(render_markdown(content), fg: @screen.theme[:thinking]))
        end
        @thinking_streamed = false
      in Pikuri::Agent::Event::AssistantDelta(content:)
        release_thinking
        @assistant_region ||= @text_view.create_region
        @buffer ||= make_buffer(@assistant_region)
        @buffer.append(content)
      in Pikuri::Agent::Event::Assistant(content:)
        release_thinking
        if @buffer
          @buffer.finalize(content)
          @buffer = nil
          @assistant_region = nil
        else
          add_block(render_markdown(content))
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
        add_block(@screen.theme.notice("! #{reason}"))
      in Pikuri::Agent::Event::Cancelled
        flush_assistant(:preserve)
        release_thinking
        add_block(@screen.theme.error('! cancelled'))
      in Pikuri::Agent::Event::Reset
        reset_conversation
      else
        # Tokens / ContextCap: silent here. TokenLog handles them if the
        # host registered one.
      end
    end

    # Wipe the conversation pane and drop every per-turn render handle in
    # response to {Pikuri::Agent::Event::Reset} — the host cleared the
    # conversation via {Pikuri::Agent#clear_conversation}. The +TextView+ is
    # cleared (which detaches all regions, including any the open buffers
    # were writing into), and the streaming-buffer / region / pairing slots
    # are reset to their construction state so the next turn renders into a
    # clean view rather than extending a stale region.
    #
    # @return [void]
    def reset_conversation
      @text_view.clear
      @buffer = nil
      @assistant_region = nil
      @thinking_buffer = nil
      @thinking_region = nil
      @thinking_streamed = false
      @pending_formatter = nil
    end

    # Render a {Pikuri::Agent::Event::ToolCall}. A registered formatter for
    # +name+ (e.g. the +edit+ / +write+ diff view) takes precedence; when it
    # produces a block, it's also stashed in {@pending_formatter} so the
    # paired result routes back to it. A missing formatter — or one that
    # declines by returning +nil+ — falls back to the default
    # +→ name(args)+ line and clears the pending slot.
    #
    # @param name [String] the tool name.
    # @param arguments [Hash] the tool-call arguments.
    # @return [void]
    def render_tool_call(name, arguments)
      formatter = @tool_formatters[name]
      block = formatter&.render_call(arguments: arguments, width: buffer_width, theme: @screen.theme)
      if block
        @pending_formatter = formatter
        add_block(block)
      else
        @pending_formatter = nil
        args = arguments.map { |k, v| "#{k}=#{v.inspect}" }.join(', ')
        add_block(@screen.theme.tool("→ #{name}(#{args})"))
      end
    end

    # Render a {Pikuri::Agent::Event::ToolResult}. When the paired call was
    # handled by a formatter, route the result to its +render_result+ — which
    # returns +nil+ to suppress a redundant success line (the diff already
    # showed the change) or a string for an error. Otherwise fall back to the
    # default += result+ line.
    #
    # @param content [String] the tool observation.
    # @return [void]
    def render_tool_result(content)
      formatter = @pending_formatter
      @pending_formatter = nil
      if formatter
        block = formatter.render_result(content: content, theme: @screen.theme)
        add_block(block) if block
      else
        add_block(@screen.theme.tool("= #{truncate_tool_result(content)}"))
      end
    end

    # Append one logical block to the conversation pane: create a fresh
    # region and assign +text+ to it. Each pikuri event that isn't a
    # streaming delta lands as exactly one such block, so subsequent
    # mutations (a later +flush_assistant(:wipe)+, a re-render on resize)
    # can address it in isolation.
    #
    # @param text [String, Tuile::StyledString] the block's content (one
    #   or more lines; embedded +\n+ produce further hard lines), possibly
    #   with embedded ANSI styling.
    # @return [void]
    def add_block(text)
      @text_view.create_region.text = indent_block(text)
    end

    # Prepend the sub-agent indent ({@pad}) to a block, handling both the
    # ANSI +String+ blocks (theme helpers, rendered markdown) and the
    # +Tuile::StyledString+ blocks (the diff formatters). A no-op for the
    # main agent ({@indent} zero). The pad lands on the first line only —
    # per {SUB_AGENT_INDENT}, continuation lines aren't re-indented.
    #
    # @param text [String, Tuile::StyledString]
    # @return [String, Tuile::StyledString]
    def indent_block(text)
      return text if @indent.zero?
      return @pad + text if text.is_a?(String)

      Tuile::StyledString.plain(@pad) + text
    end

    # Construct a streaming buffer wired to +region+. The buffer rewrites
    # +region.text+ on every append, so the listener doesn't need to
    # marshal individual UI mutations — the surrounding submit in
    # {#on_event} already places the call under the UI lock.
    #
    # @param region [Tuile::Component::TextView::Region]
    # @return [StreamingMarkdownBuffer, PassthroughBuffer]
    def make_buffer(region)
      if @markdown
        StreamingMarkdownBuffer.new(render: indent_render(build_markdown_renderer), region: region)
      else
        PassthroughBuffer.new(region: region)
      end
    end

    # Wrap a +String -> String+ render proc so its output carries the
    # sub-agent indent ({@pad}) — prepended once, so only the rendered
    # block's first line is padded (see {SUB_AGENT_INDENT}). A no-op for
    # the main agent ({@indent} zero), returning the proc unchanged. The
    # {StreamingMarkdownBuffer}'s commit-probe sentinel is unaffected: the
    # pad lands on the first line, the sentinel sits on the last.
    #
    # @param render [#call] the underlying render proc.
    # @return [#call]
    def indent_render(render)
      return render if @indent.zero?

      pad = @pad
      ->(md) { pad + render.call(md) }
    end

    # Twin of {#make_buffer} for the reasoning pane. Always returns a
    # {StreamingMarkdownBuffer}: the renderer is {MarkdownRenderer}→recolor
    # when Markdown is on, recolor-only when it's off. Going through the
    # streaming buffer in both cases gives us the same lifecycle (one
    # buffer per thinking block, finalize at bookend) and keeps the gray
    # tint applied regardless of mode.
    #
    # The block-cutter inside {StreamingMarkdownBuffer} cuts on blank
    # lines and fences. With a pure recolor render it just commits each
    # paragraph as-is, which is fine — the end result is +region.text =
    # recolor(source)+ either way.
    #
    # @param region [Tuile::Component::TextView::Region]
    # @return [StreamingMarkdownBuffer]
    def make_thinking_buffer(region)
      # Snapshot the theme's reasoning tone at build time (one buffer per
      # thinking block), the same way {#build_markdown_renderer} snapshots
      # the width — an OS appearance flip mid-block keeps the tone it
      # started with rather than splicing two tones into one paragraph.
      thinking = @screen.theme[:thinking]
      render = if @markdown
                 markdown = build_markdown_renderer
                 ->(md) { AnsiGrayscale.recolor(markdown.call(md), fg: thinking) }
               else
                 ->(md) { AnsiGrayscale.recolor(md, fg: thinking) }
               end
      StreamingMarkdownBuffer.new(render: indent_render(render), region: region)
    end

    # Builds a callable +String -> String+ that snapshots the current
    # {#buffer_width} and terminal scheme, then routes through
    # {MarkdownRenderer.render}. Used by {#make_buffer} and
    # {#make_thinking_buffer} as the +render:+ arg (the thinking variant
    # composes it with recolor, which flattens the colors away — so the
    # +dark:+ snapshot only matters on the assistant path). Both are
    # snapshot at build time (one buffer per block), the same way the
    # reasoning tone is, so an OS appearance flip mid-block keeps the
    # scheme it started with rather than splicing two palettes into one.
    # @return [Proc]
    def build_markdown_renderer
      width = buffer_width
      dark = dark_scheme?
      ->(md) { MarkdownRenderer.render(md, width: width, dark: dark) }
    end

    # Whether the conversation pane is on a dark terminal background, so
    # {MarkdownRenderer} can pick a code-highlighting theme legible against
    # it ({MarkdownRenderer::AnsiConverter}'s default Rouge theme has
    # near-white base text that vanishes on light). The screen holds
    # exactly the {AppTheme::DARK} / {AppTheme::LIGHT} constant its
    # {Tuile::ThemeDef} resolved — re-picked on every OS appearance flip —
    # so identity against {AppTheme::LIGHT} is the live scheme.
    # @return [Boolean]
    def dark_scheme?
      !@screen.theme.equal?(AppTheme::LIGHT)
    end

    # @return [Integer] render width for a fresh streaming buffer. Reads
    #   the +TextView+'s current rect and reserves two columns for the
    #   scrollbar gutter / any future padding; floors at 1 so a
    #   not-yet-laid-out view doesn't pass a non-positive width to
    #   {MarkdownRenderer}.
    def buffer_width
      [@text_view.rect.width - 2, 1].max
    end

    # Close out the assistant streaming buffer.
    #
    # +:wipe+ removes the streamed region entirely (a +ToolCall+ /
    # +UserTurn+ / etc. arrived mid-stream and the preview is no longer
    # what the user should see). +:preserve+ just drops the buffer
    # handle — the region keeps its rendered content (the cancel-preserve
    # case: the partial assistant reply the user had when they hit
    # cancel must stay visible).
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

    # Drop the thinking buffer + region handles. The region itself stays
    # in the +TextView+ with its rendered content — there's no UI
    # mutation here, just bookkeeping. Called from every handler except
    # {Pikuri::Agent::Event::ThinkingDelta} so that the next
    # +ThinkingDelta+ in a later step opens a fresh region rather than
    # extending the previous one.
    # @return [void]
    def release_thinking
      @thinking_buffer = nil
      @thinking_region = nil
    end

    # Render assistant Markdown for the conversation pane, degrading to
    # the raw string when the renderer raises — LLM output is arbitrary
    # and a kramdown / rouge surprise shouldn't be fatal; on a
    # long-running TUI we'd rather show ugly
    # Markdown than abort an in-flight conversation. Used on the
    # non-streaming +Assistant+ / +Thinking+ paths; the streaming path
    # lets the buffer do its own catch-and-log.
    #
    # When the listener was constructed with +markdown: false+, this is
    # a no-op — the +content+ comes back unchanged, matching the
    # passthrough behavior on the streaming path.
    #
    # @param content [String] assistant Markdown
    # @return [String] rendered ANSI text, or +content+ unchanged on
    #   render failure (or when +@markdown+ is false)
    def render_markdown(content)
      return content unless @markdown

      MarkdownRenderer.render(content, width: buffer_width, dark: dark_scheme?)
    rescue StandardError => e
      LOG.warn("MarkdownRenderer.render failed (#{e.class}: #{e.message}); falling back to raw text")
      content
    end

    # Flatten whitespace and cap to {MAX_TOOL_RESULT_CHARS}. Long results
    # (rendered HTML, PDF text) would otherwise drown the conversation;
    # the byte-count suffix on a truncated result distinguishes "tool
    # returned exactly this" from "tool returned much more."
    #
    # @param content [String] tool observation
    # @return [String] single-line display form, possibly truncated
    def truncate_tool_result(content)
      original_bytes = content.to_s.bytesize
      flattened = content.to_s.gsub(/\s+/, ' ').strip
      return flattened if flattened.length <= MAX_TOOL_RESULT_CHARS

      "#{flattened[0, MAX_TOOL_RESULT_CHARS]}… (#{original_bytes} bytes total)"
    end
  end
end
