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
  # Variant coverage mirrors the terminal listener with two intentional
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
    #   ({PikuriTui::ChatApp}); the listener doesn't construct or destroy it.
    # @param screen [Tuile::Screen] the screen whose +event_queue+ marshals
    #   UI mutations back from the agent's worker thread. Passed explicitly
    #   (rather than reached for via +Tuile::Screen.instance+) so tests can
    #   inject a {Tuile::FakeScreen} without having to install it as the
    #   singleton at construction time.
    def initialize(text_view:, screen:)
      super()
      @text_view = text_view
      @screen = screen
    end

    # Dispatches one event to the conversation pane. Called from the agent's
    # worker thread; every write to {@text_view} is wrapped in
    # +screen.event_queue.submit+ so the UI mutation runs on the event-loop
    # thread.
    #
    # @param event [Pikuri::Agent::Event::UserTurn,
    #   Pikuri::Agent::Event::Thinking, Pikuri::Agent::Event::Assistant,
    #   Pikuri::Agent::Event::ToolCall, Pikuri::Agent::Event::ToolResult,
    #   Pikuri::Agent::Event::FallbackNotice, Pikuri::Agent::Event::Cancelled,
    #   Pikuri::Agent::Event::Tokens, Pikuri::Agent::Event::ContextCap]
    # @return [void]
    def on_event(event)
      case event
      in Pikuri::Agent::Event::UserTurn(content:)
        append("> #{content}")
      in Pikuri::Agent::Event::Thinking(content:)
        append(Rainbow(content).color(85, 85, 85).to_s)
      in Pikuri::Agent::Event::Assistant(content:)
        append(render_markdown(content))
      in Pikuri::Agent::Event::ToolCall(name:, arguments:)
        args = arguments.map { |k, v| "#{k}=#{v.inspect}" }.join(', ')
        append(Rainbow("→ #{name}(#{args})").cyan.to_s)
      in Pikuri::Agent::Event::ToolResult(content:)
        append(Rainbow("= #{truncate_tool_result(content)}").cyan.to_s)
      in Pikuri::Agent::Event::FallbackNotice(reason:)
        append(Rainbow("! #{reason}").yellow.to_s)
      in Pikuri::Agent::Event::Cancelled
        append(Rainbow('! cancelled').red.to_s)
      else
        # Tokens / ContextCap: silent here. TokenLog handles them if the host
        # registered one.
      end
    end

    # @return [String] short label used by +Pikuri::Agent#to_s+ when this
    #   listener is in its +ListenerList+.
    def to_s = 'TuileListener'

    private

    # Marshal a single appended line back onto the UI thread. The
    # {Tuile::Component::TextView}'s +#append+ method is the one place
    # that requires the UI lock; the rendering work above (Rainbow, Markdown
    # parsing) is pure and stays on the worker thread.
    #
    # @param text [String] one or more lines to append, possibly with
    #   embedded ANSI styling (the TextView parses ANSI via StyledString)
    # @return [void]
    def append(text)
      @screen.event_queue.submit { @text_view.append(text) }
    end

    # Render assistant Markdown for the conversation pane, degrading to the
    # raw string when the renderer raises. +tty-markdown+ has known issues
    # around ANSI inside tables (+Strings::Wrap.insert_ansi+ raising
    # +IndexError+); on a long-running TUI we'd rather show ugly Markdown
    # than abort an in-flight conversation.
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
