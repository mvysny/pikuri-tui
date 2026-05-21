# frozen_string_literal: true

require 'pikuri'
require 'rainbow'

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
  # 2. Library failures during rendering (+tty-markdown+ choking on
  #    assistant output) are caught and logged through {Tuile.logger}
  #    instead of bubbling out — an uncaught raise on the worker thread
  #    would silently kill the agent loop. Same "library exceptions are
  #    logged, our bugs raise" rule documented in CLAUDE.md.
  # 3. Streaming events ({Pikuri::Agent::Event::AssistantDelta} /
  #    {Pikuri::Agent::Event::ThinkingDelta}) are both rendered
  #    incrementally through a {StreamingMarkdownBuffer} wired to a
  #    dedicated region. The thinking buffer's renderer is wrapped with
  #    {AnsiGrayscale.recolor} so reasoning paints in one muted-gray
  #    tone with bold/italic/underline structure preserved — visually
  #    distinct from the assistant's full-color answer. The bookend
  #    {Pikuri::Agent::Event::Thinking} is suppressed when deltas
  #    already produced the visible reasoning block (the streamed
  #    preview is committed as-is rather than replaced); on the
  #    non-streaming path the bookend renders directly as grayscale
  #    Markdown.
  #
  # +Tokens+ and +ContextCap+ stay silent (their consumer is
  # +Pikuri::Agent::Listener::TokenLog+, which the host adds separately
  # if it wants token accounting in the diagnostic log).
  #
  # The Markdown render is gated on a +markdown:+ ctor flag (default
  # +true+). When the host wires +markdown: false+, the assistant
  # streaming path uses {PassthroughBuffer} and the non-streaming
  # assistant path skips +TTY::Markdown+ — content goes to the +TextView+
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

    # Path of the debug event-dump file. Truncated on construction when
    # the listener is built with +dump_events: true+, and appended to on
    # every {#on_event} call thereafter.
    #
    # @return [String]
    EVENT_DUMP_PATH = '/tmp/pikuri-tui-events.txt'

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
    #   content is rendered through +TTY::Markdown+. When +false+, the
    #   listener skips Markdown rendering for the assistant path —
    #   non-streaming events echo their content verbatim and the streaming
    #   path uses {PassthroughBuffer}. The thinking path always recolors
    #   to gray and so always goes through a {StreamingMarkdownBuffer}
    #   (with the renderer set to +TTY::Markdown+→recolor or
    #   recolor-only, depending on the flag).
    # @param dump_events [Boolean] when +true+, every event handed to
    #   {#on_event} is also +inspect+-ed and appended to
    #   {EVENT_DUMP_PATH}. The file is truncated here so each run starts
    #   clean. Off by default; intended as a local debugging aid.
    def initialize(text_view:, screen:, markdown: true, dump_events: false)
      super()
      @text_view = text_view
      @screen = screen
      @markdown = markdown
      @dump_events = dump_events
      @buffer = nil
      @assistant_region = nil
      @thinking_buffer = nil
      @thinking_region = nil
      @thinking_streamed = false

      File.write(EVENT_DUMP_PATH, '') if @dump_events
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
    #   Pikuri::Agent::Event::Tokens, Pikuri::Agent::Event::ContextCap]
    # @return [void]
    def on_event(event)
      File.open(EVENT_DUMP_PATH, 'a') { |f| f.puts(event.inspect) } if @dump_events
      @screen.event_queue.submit { dispatch_event(event) }
    end

    # @return [String] short label used by +Pikuri::Agent#to_s+ when this
    #   listener is in its +ListenerList+.
    def to_s = 'TuileListener'

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
        add_block("> #{content}")
      in Pikuri::Agent::Event::ThinkingDelta(content:)
        flush_assistant(:wipe)
        @thinking_region ||= @text_view.create_region
        @thinking_buffer ||= make_thinking_buffer(@thinking_region)
        @thinking_buffer.append(content)
        @thinking_streamed = true
      in Pikuri::Agent::Event::Thinking(content:)
        if @thinking_buffer
          release_thinking
        elsif !@thinking_streamed
          add_block(AnsiGrayscale.recolor(render_markdown(content)))
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
        args = arguments.map { |k, v| "#{k}=#{v.inspect}" }.join(', ')
        add_block(Rainbow("→ #{name}(#{args})").cyan.to_s)
      in Pikuri::Agent::Event::ToolResult(content:)
        flush_assistant(:wipe)
        release_thinking
        add_block(Rainbow("= #{truncate_tool_result(content)}").cyan.to_s)
      in Pikuri::Agent::Event::FallbackNotice(reason:)
        flush_assistant(:wipe)
        release_thinking
        add_block(Rainbow("! #{reason}").yellow.to_s)
      in Pikuri::Agent::Event::Cancelled
        flush_assistant(:preserve)
        release_thinking
        add_block(Rainbow('! cancelled').red.to_s)
      else
        # Tokens / ContextCap: silent here. TokenLog handles them if the
        # host registered one.
      end
    end

    # Append one logical block to the conversation pane: create a fresh
    # region and assign +text+ to it. Each pikuri event that isn't a
    # streaming delta lands as exactly one such block, so subsequent
    # mutations (a later +flush_assistant(:wipe)+, a re-render on resize)
    # can address it in isolation.
    #
    # @param text [String] the block's content (one or more lines;
    #   embedded +\n+ produce further hard lines), possibly with embedded
    #   ANSI styling.
    # @return [void]
    def add_block(text)
      @text_view.create_region.text = text
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
        StreamingMarkdownBuffer.new(render: build_markdown_renderer, region: region)
      else
        PassthroughBuffer.new(region: region)
      end
    end

    # Twin of {#make_buffer} for the reasoning pane. Always returns a
    # {StreamingMarkdownBuffer}: the renderer is +TTY::Markdown+→recolor
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
      render = if @markdown
                 markdown = build_markdown_renderer
                 ->(md) { AnsiGrayscale.recolor(markdown.call(md)) }
               else
                 AnsiGrayscale.method(:recolor)
               end
      StreamingMarkdownBuffer.new(render: render, region: region)
    end

    # Builds a callable +String -> String+ that snapshots the current
    # {#buffer_width} and routes through {MarkdownRenderer.render}. Used
    # by {#make_buffer} and {#make_thinking_buffer} as the +render:+ arg
    # (the thinking variant composes it with recolor).
    # @return [Proc]
    def build_markdown_renderer
      width = buffer_width
      ->(md) { MarkdownRenderer.render(md, width: width) }
    end

    # @return [Integer] render width for a fresh streaming buffer. Reads
    #   the +TextView+'s current rect and reserves two columns for the
    #   scrollbar gutter / any future padding; floors at 1 so a
    #   not-yet-laid-out view doesn't pass a non-positive width to
    #   +TTY::Markdown+.
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
    # the raw string when the renderer raises. +tty-markdown+ has known
    # issues around ANSI inside tables (+Strings::Wrap.insert_ansi+
    # raising +IndexError+); on a long-running TUI we'd rather show ugly
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

      MarkdownRenderer.render(content, width: buffer_width)
    rescue StandardError => e
      Tuile.logger.warn("MarkdownRenderer.render failed (#{e.class}: #{e.message}); falling back to raw text")
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
