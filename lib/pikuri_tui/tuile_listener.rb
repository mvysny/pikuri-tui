# frozen_string_literal: true

require 'pikuri'
require 'rainbow'

module PikuriTui
  # Tuile-targeted equivalent of +Pikuri::Agent::Listener::Terminal+: renders
  # the normalized event stream into a {Tuile::Component::TextView} (the
  # conversation pane) instead of stdout.
  #
  # The agent's loop runs on a worker thread (Tuile owns the UI thread), so
  # every {#on_event} call marshals its render through
  # +screen.event_queue.submit+ to satisfy Tuile's single-threaded UI rule.
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
  #    incrementally through a {StreamingMarkdownBuffer} that
  #    re-renders the accumulated source per token and applies the
  #    diff via +TextView#remove_last_n_lines+ + +#add_line+. The
  #    assistant buffer is finalized against the authoritative
  #    {Pikuri::Agent::Event::Assistant#content} when it arrives; the
  #    thinking buffer's sink routes each emitted line through
  #    {AnsiGrayscale.recolor} so reasoning renders in one muted-gray
  #    tone with bold/italic/underline structure preserved — visually
  #    distinct from the assistant's full-color answer. The bookend
  #    {Pikuri::Agent::Event::Thinking} is suppressed when deltas
  #    already produced the visible reasoning block (the streamed
  #    preview is committed as-is rather than replaced); on the
  #    non-streaming path the bookend renders directly as grayscale
  #    Markdown.
  #
  # +Tokens+ and +ContextCap+ stay silent (their consumer is
  # +Pikuri::Agent::Listener::TokenLog+, which the host adds separately if
  # it wants token accounting in the diagnostic log).
  class TuileListener < Pikuri::Agent::Listener::Base
    # Cap, in characters, applied to tool-result content before it lands in
    # the conversation pane. Mirrors the terminal listener's cap so the two
    # renderers stay visually consistent.
    #
    # @return [Integer]
    MAX_TOOL_RESULT_CHARS = 200

    # @param text_view [Tuile::Component::TextView] the conversation pane
    #   to append rendered events into. Lifetime is owned by the host
    #   ({PikuriTui::Chat::App}); the listener doesn't construct or
    #   destroy it.
    # @param screen [Tuile::Screen] the screen whose +event_queue+ marshals
    #   UI mutations back from the agent's worker thread. Passed explicitly
    #   (rather than reached for via +Tuile::Screen.instance+) so tests can
    #   inject a {Tuile::FakeScreen} without having to install it as the
    #   singleton at construction time.
    def initialize(text_view:, screen:)
      super()
      @text_view = text_view
      @screen = screen
      @buffer = nil
      @thinking_buffer = nil
    end

    # Dispatches one event to the conversation pane. Called from the agent's
    # worker thread; every write to {@text_view} is wrapped in
    # +screen.event_queue.submit+ so the UI mutation runs on the event-loop
    # thread.
    #
    # @param event [Pikuri::Agent::Event::UserTurn,
    #   Pikuri::Agent::Event::Thinking, Pikuri::Agent::Event::ThinkingDelta,
    #   Pikuri::Agent::Event::Assistant, Pikuri::Agent::Event::AssistantDelta,
    #   Pikuri::Agent::Event::ToolCall, Pikuri::Agent::Event::ToolResult,
    #   Pikuri::Agent::Event::FallbackNotice, Pikuri::Agent::Event::Cancelled,
    #   Pikuri::Agent::Event::Tokens, Pikuri::Agent::Event::ContextCap]
    # @return [void]
    def on_event(event)
      case event
      in Pikuri::Agent::Event::UserTurn(content:)
        flush_assistant(:wipe)
        flush_thinking
        add_line("> #{content}")
      in Pikuri::Agent::Event::ThinkingDelta(content:)
        flush_assistant(:wipe)
        @thinking_buffer ||= make_thinking_buffer
        @thinking_buffer.append(content)
      in Pikuri::Agent::Event::Thinking(content:)
        flush_assistant(:wipe)
        if @thinking_buffer
          flush_thinking
        else
          add_line(AnsiGrayscale.recolor(render_markdown(content)))
        end
      in Pikuri::Agent::Event::AssistantDelta(content:)
        flush_thinking
        @buffer ||= make_buffer
        @buffer.append(content)
      in Pikuri::Agent::Event::Assistant(content:)
        flush_thinking
        if @buffer
          @buffer.finalize(content)
          @buffer = nil
          add_line('')
        else
          add_line(render_markdown(content))
        end
      in Pikuri::Agent::Event::ToolCall(name:, arguments:)
        flush_assistant(:wipe)
        flush_thinking
        args = arguments.map { |k, v| "#{k}=#{v.inspect}" }.join(', ')
        add_line(Rainbow("→ #{name}(#{args})").cyan.to_s)
      in Pikuri::Agent::Event::ToolResult(content:)
        flush_assistant(:wipe)
        flush_thinking
        add_line(Rainbow("= #{truncate_tool_result(content)}").cyan.to_s)
      in Pikuri::Agent::Event::FallbackNotice(reason:)
        flush_assistant(:wipe)
        flush_thinking
        add_line(Rainbow("! #{reason}").yellow.to_s)
      in Pikuri::Agent::Event::Cancelled
        flush_assistant(:preserve)
        flush_thinking
        add_line(Rainbow('! cancelled').red.to_s)
      else
        # Tokens / ContextCap: silent here. TokenLog handles them if the host
        # registered one.
      end
    end

    # @return [String] short label used by +Pikuri::Agent#to_s+ when this
    #   listener is in its +ListenerList+.
    def to_s = 'TuileListener'

    private

    # Marshal an event onto a fresh hard line in the conversation pane.
    # Each pikuri event maps to its own hard line, so this — not
    # +TextView#append+ — is the right primitive for the per-event
    # dispatch in {#on_event}. Rendering work (Markdown, Rainbow) is
    # done on the worker thread; only the UI mutation is submitted.
    #
    # @param text [String] one or more lines (embedded +\n+ produce
    #   further hard lines), possibly with embedded ANSI styling.
    # @return [void]
    def add_line(text)
      @screen.event_queue.submit { @text_view.add_line(text) }
    end

    # Construct a {StreamingMarkdownBuffer} wired to a sink that
    # applies the diff to {@text_view} on the UI thread. The render
    # width is read off the +TextView+'s current rect, minus a small
    # buffer for the scrollbar gutter and any future padding.
    # @return [StreamingMarkdownBuffer]
    def make_buffer
      StreamingMarkdownBuffer.new(render: build_renderer) do |remove_n, lines_to_add|
        @screen.event_queue.submit do
          @text_view.remove_last_n_lines(remove_n) if remove_n.positive?
          @text_view.add_line(lines_to_add.join("\n")) if lines_to_add.any?
        end
      end
    end

    # Twin of {#make_buffer} for the reasoning pane. Same diff plumbing,
    # but each emitted line is repainted via {AnsiGrayscale.recolor}
    # before it lands in the +TextView+ — so streamed Markdown thinking
    # keeps its bold/italic/list structure while the eye still reads
    # the whole block as "reasoning, not answer." The recolor runs on
    # the worker thread (CPU work) so only the +TextView+ mutation is
    # marshaled onto the UI thread.
    # @return [StreamingMarkdownBuffer]
    def make_thinking_buffer
      StreamingMarkdownBuffer.new(render: build_renderer) do |remove_n, lines_to_add|
        recolored = lines_to_add.map { |line| AnsiGrayscale.recolor(line) }
        @screen.event_queue.submit do
          @text_view.remove_last_n_lines(remove_n) if remove_n.positive?
          @text_view.add_line(recolored.join("\n")) if recolored.any?
        end
      end
    end

    # Builds a callable +String -> String+ that snapshots the current
    # {#buffer_width} and routes through {MarkdownRenderer.render}. Used
    # by {#make_buffer} and {#make_thinking_buffer} as the +render:+ arg
    # to {StreamingMarkdownBuffer}; the snapshot is what the buffer's
    # docs call "the wrap-width at the moment the buffer is created."
    # @return [Proc]
    def build_renderer
      width = buffer_width
      ->(md) { MarkdownRenderer.render(md, width: width) }
    end

    # @return [Integer] render width for a fresh
    #   {StreamingMarkdownBuffer}. Reads the +TextView+'s current rect
    #   and reserves two columns for the scrollbar gutter / any future
    #   padding; floors at 1 so a not-yet-laid-out view doesn't pass a
    #   non-positive width to +TTY::Markdown+.
    def buffer_width
      [@text_view.rect.width - 2, 1].max
    end

    # Close out the assistant {StreamingMarkdownBuffer}. +:wipe+
    # finalizes against the empty string (the buffer emits a diff that
    # removes its rendered region from the +TextView+), which is the
    # right call when an unrelated event arrives mid-stream — the new
    # event then renders directly on a fresh line. +:preserve+ finalizes
    # against the buffer's accumulated source (the diff is a no-op
    # against the last render), keeping the streamed region visible —
    # the right call for {Pikuri::Agent::Event::Cancelled} so the user
    # sees the partial assistant reply they had when they hit cancel.
    #
    # +:preserve+ also appends a blank hard line below the kept region
    # as a separator between it and whatever event renders next. The
    # streaming buffer's renderer drops trailing empty lines (it splits
    # on +\n+ without preserving trailing empties, so a "para.\n" or
    # "para.\n\n" both end up as +["para."]+), so without this the next
    # event lands flush against the last paragraph. +:wipe+ deliberately
    # skips the separator: there's nothing to separate from once the
    # preview is gone.
    #
    # @param mode [:wipe, :preserve]
    # @return [void]
    def flush_assistant(mode)
      return unless @buffer

      case mode
      when :wipe
        @buffer.finalize('')
      when :preserve
        @buffer.finalize(@buffer.source)
        add_line('')
      else
        raise ArgumentError, "expected :wipe or :preserve, got #{mode.inspect}"
      end
      @buffer = nil
    end

    # Close out the thinking {StreamingMarkdownBuffer}. Always commits
    # the streamed text as-is — there's no +:wipe+ counterpart because
    # the reasoning preview is never speculative the way an assistant
    # preview is: by the time any cross-event reaches us the thinking
    # has *happened*, and erasing it would drop the only record. The
    # {Pikuri::Agent::Event::Thinking} bookend's "suppress when streamed"
    # behavior is the same preserve, just stated from the bookend's side.
    #
    # Appends a blank hard line below the committed region as a
    # separator between it and whatever event renders next. The buffer's
    # renderer drops trailing empty lines (see {#flush_assistant}), so
    # without this the next event lands flush against the last
    # paragraph of the reasoning.
    # @return [void]
    def flush_thinking
      return unless @thinking_buffer

      @thinking_buffer.finalize(@thinking_buffer.source)
      @thinking_buffer = nil
      add_line('')
    end

    # Render assistant Markdown for the conversation pane, degrading to the
    # raw string when the renderer raises. +tty-markdown+ has known issues
    # around ANSI inside tables (+Strings::Wrap.insert_ansi+ raising
    # +IndexError+); on a long-running TUI we'd rather show ugly Markdown
    # than abort an in-flight conversation. Used on the non-streaming
    # +Assistant+ path; the streaming path lets
    # {StreamingMarkdownBuffer} do its own catch-and-log.
    #
    # @param content [String] assistant Markdown
    # @return [String] rendered ANSI text, or +content+ unchanged on
    #   render failure
    def render_markdown(content)
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
