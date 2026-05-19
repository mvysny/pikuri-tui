# frozen_string_literal: true

require 'pikuri'
require 'rainbow'
require 'tty-markdown'

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
  #    {Pikuri::Agent::Event::ThinkingDelta}) are rendered incrementally.
  #    For assistant Markdown the listener owns a
  #    {StreamingMarkdownBuffer} that re-renders the accumulated source
  #    per token and applies the diff via +TextView#remove_last_n_lines+
  #    + +#add_line+; the buffer is finalized against the authoritative
  #    {Pikuri::Agent::Event::Assistant#content} when it arrives. For
  #    thinking deltas there's no Markdown to render, so they're
  #    streamed as plain dim-gray text directly into the +TextView+,
  #    with the bookend {Pikuri::Agent::Event::Thinking} suppressed
  #    when deltas already produced the visible reasoning block.
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
      @thinking_open = false
      @streamed_thinking = false
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
        flush_buffer(:wipe)
        @thinking_open = false
        @streamed_thinking = false
        add_line("> #{content}")
      in Pikuri::Agent::Event::ThinkingDelta(content:)
        flush_buffer(:wipe)
        styled = Rainbow(content).color(85, 85, 85).to_s
        if @thinking_open
          append_inline(styled)
        else
          add_line(styled)
          @thinking_open = true
        end
        @streamed_thinking = true
      in Pikuri::Agent::Event::Thinking(content:)
        flush_buffer(:wipe)
        @thinking_open = false
        unless @streamed_thinking
          add_line(Rainbow(content).color(85, 85, 85).to_s)
        end
        @streamed_thinking = false
      in Pikuri::Agent::Event::AssistantDelta(content:)
        @thinking_open = false
        @buffer ||= make_buffer
        @buffer.append(content)
      in Pikuri::Agent::Event::Assistant(content:)
        @thinking_open = false
        if @buffer
          @buffer.finalize(content)
          @buffer = nil
        else
          add_line(render_markdown(content))
        end
      in Pikuri::Agent::Event::ToolCall(name:, arguments:)
        flush_buffer(:wipe)
        @thinking_open = false
        args = arguments.map { |k, v| "#{k}=#{v.inspect}" }.join(', ')
        add_line(Rainbow("→ #{name}(#{args})").cyan.to_s)
      in Pikuri::Agent::Event::ToolResult(content:)
        flush_buffer(:wipe)
        @thinking_open = false
        add_line(Rainbow("= #{truncate_tool_result(content)}").cyan.to_s)
      in Pikuri::Agent::Event::FallbackNotice(reason:)
        flush_buffer(:wipe)
        @thinking_open = false
        add_line(Rainbow("! #{reason}").yellow.to_s)
      in Pikuri::Agent::Event::Cancelled
        flush_buffer(:preserve)
        @thinking_open = false
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

    # Inline continuation of the current last hard line. Used for the
    # second-and-subsequent +ThinkingDelta+ within a streak so the
    # streamed reasoning grows in place instead of starting a new line
    # per token.
    #
    # @param text [String]
    # @return [void]
    def append_inline(text)
      @screen.event_queue.submit { @text_view.append(text) }
    end

    # Construct a {StreamingMarkdownBuffer} wired to a sink that
    # applies the diff to {@text_view} on the UI thread. The render
    # width is read off the +TextView+'s current rect, minus a small
    # buffer for the scrollbar gutter and any future padding.
    # @return [StreamingMarkdownBuffer]
    def make_buffer
      width = [@text_view.rect.width - 2, 1].max
      StreamingMarkdownBuffer.new(width: width) do |remove_n, lines_to_add|
        @screen.event_queue.submit do
          @text_view.remove_last_n_lines(remove_n) if remove_n.positive?
          @text_view.add_line(lines_to_add.join("\n")) if lines_to_add.any?
        end
      end
    end

    # Close out an open {StreamingMarkdownBuffer}. +:wipe+ finalizes
    # against the empty string (the buffer emits a diff that removes
    # its rendered region from the +TextView+), which is the right
    # call when an unrelated event arrives mid-stream — the new event
    # then renders directly on a fresh line. +:preserve+ finalizes
    # against the buffer's accumulated source (the diff is a no-op
    # against the last render), keeping the streamed region visible —
    # the right call for {Pikuri::Agent::Event::Cancelled} so the user
    # sees the partial assistant reply they had when they hit cancel.
    #
    # @param mode [:wipe, :preserve]
    # @return [void]
    def flush_buffer(mode)
      return unless @buffer

      case mode
      when :wipe     then @buffer.finalize('')
      when :preserve then @buffer.finalize(@buffer.source)
      else raise ArgumentError, "expected :wipe or :preserve, got #{mode.inspect}"
      end
      @buffer = nil
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
      TTY::Markdown.parse(content)
    rescue StandardError => e
      Tuile.logger.warn("TTY::Markdown render failed (#{e.class}: #{e.message}); falling back to raw text")
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
