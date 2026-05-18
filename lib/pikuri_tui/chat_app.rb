# frozen_string_literal: true

require 'logger'
require 'pikuri'
require 'tuile'

module PikuriTui
  # The Tuile shell shared by +bin/pikuri-chat+ and +bin/pikuri-code+:
  # builds the framed conversation pane, the framed input pane, the eager
  # diagnostic +LogWindow+ (popup-visible on +l+), the conversation
  # Window's footer status cell, and wires the agent's loop onto a worker
  # thread so the UI thread stays free for repaints.
  #
  # == Construction order
  #
  # The agent needs a {TuileListener} in its +ListenerList+, and the
  # listener needs the conversation +TextView+ — which can't exist until
  # the screen is initialized. Resolving that cycle is why the
  # constructor takes a block: ChatApp builds the screen, the components,
  # and the listener, then yields the listener to the block; the block
  # returns a constructed +Pikuri::Agent+ that ChatApp installs. The bin
  # scripts use this seam to pick model/tools/transport without ChatApp
  # learning about either.
  #
  # == Screen ownership
  #
  # ChatApp assumes a {Tuile::Screen} (or {Tuile::FakeScreen}) is already
  # installed as the singleton — production code calls +Tuile::Screen.new+
  # in the bin script before constructing ChatApp; tests call
  # +Tuile::Screen.fake+. That's intentional: ChatApp doesn't unilaterally
  # mount a real terminal screen, so a host that wants to inject a fake
  # for an integration test doesn't have to fight constructor order.
  #
  # == Threading
  #
  # Per CLAUDE.md, Tuile is single-threaded and the agent loop must not
  # run on the UI thread. ChatApp enforces this:
  #
  # - {Tuile::Screen#run_event_loop} runs on the caller's thread (the
  #   main thread for the bin scripts).
  # - Each submitted user message spawns a fresh +Thread.new+ that calls
  #   +agent.run_loop+. The listener's renderings, the worker's status
  #   flag toggle, and any error logging marshal back via
  #   +screen.event_queue.submit+ so they execute on the UI thread.
  # - Concurrent turns are prevented by +@turn_in_progress+: Enter is a
  #   no-op while a turn is running. The flag is read and written only on
  #   the UI thread.
  class ChatApp
    # @return [Tuile::Screen] the (already-installed) screen this app
    #   runs on.
    attr_reader :screen

    # @return [Pikuri::Agent] the agent the build block returned. Exposed
    #   so callers (and tests) can inspect tools/listeners/transport
    #   after wiring.
    attr_reader :agent

    # @return [Tuile::Component::TextView] the conversation transcript
    #   pane. Exposed primarily for tests; production code should reach
    #   it through the {TuileListener}.
    attr_reader :conversation_view

    # @return [Tuile::Component::LogWindow] the eager-constructed
    #   diagnostic window. Exposed for tests and for callers that want
    #   to install additional logger sinks.
    attr_reader :log_window

    # @yield [listener] one-shot factory invoked exactly once during
    #   construction. The block receives the {TuileListener} bound to
    #   this app's conversation pane and must return a constructed
    #   +Pikuri::Agent+ whose +ListenerList+ includes that listener.
    # @yieldparam listener [TuileListener] the conversation-pane
    #   listener; include it in the agent's +ListenerList+.
    # @yieldreturn [Pikuri::Agent] the wired agent.
    # @raise [LocalJumpError] if no block is given (no agent → no app).
    def initialize(&build_agent)
      raise LocalJumpError, 'ChatApp requires a block that builds the Pikuri::Agent' unless block_given?

      @screen = Tuile::Screen.instance
      @error_count = 0
      @turn_in_progress = false

      build_components
      wire_logging
      @agent = build_agent.call(@listener)

      @screen.on_error = method(:on_screen_error)
      @screen.content = @layout
      @screen.focused = @input
    end

    # Runs the Tuile event loop, blocking the calling thread until the
    # user quits ({Tuile::Keys::ESC} or +q+) or the loop is otherwise
    # stopped. The +ensure+ pairs +run_event_loop+ with
    # +Tuile::Screen#close+ so the terminal is cleared and the screen
    # singleton is unset regardless of how the loop exits — including
    # exceptions escaping the loop. +run_event_loop+ itself only
    # restores stdin / cursor / mouse tracking; it does not clear the
    # screen, so without this an abnormal exit would leave the painted
    # frame frozen in the user's terminal scrollback.
    #
    # @return [void]
    def run
      @screen.run_event_loop
    ensure
      @screen.close
    end

    private

    # @return [void]
    def build_components
      @log_window = Tuile::Component::LogWindow.new('Log')
      @log_popup = LogPopup.new(log_window: @log_window, on_dismiss: method(:reset_error_count))

      @conversation_view = Tuile::Component::TextView.new
      @conversation_view.auto_scroll = true

      @conversation_window = Tuile::Component::Window.new('Conversation')
      @conversation_window.content = @conversation_view

      @status_label = Tuile::Component::Label.new
      @status_label.text = status_text
      @conversation_window.footer = @status_label

      @input = ChatInput.new(on_submit: method(:submit_message))
      @input_window = Tuile::Component::Window.new('You')
      @input_window.content = @input

      @listener = TuileListener.new(text_view: @conversation_view, screen: @screen)

      @layout = ChatLayout.new(
        conversation: @conversation_window,
        input: @input_window,
        on_log: method(:open_log_popup),
        on_cancel: method(:cancel_turn)
      )
    end

    # Routes every pikuri / Tuile log line — and any exception trapped
    # by {Tuile::Screen#on_error} — through a single {CountingLogIO}
    # that both renders into {@log_window} and bumps the error counter
    # for the status cell. Must run after {@log_window} exists and
    # before the agent is built (the agent's construction can already
    # log).
    #
    # @return [void]
    def wire_logging
      io = CountingLogIO.new(log_window: @log_window, on_error: method(:on_error_logged))
      Tuile.logger = Logger.new(io)
      Pikuri.log_io = io
    end

    # @param message [String] non-empty draft handed up by {ChatInput}
    # @return [void]
    def submit_message(message)
      return if @turn_in_progress

      @turn_in_progress = true
      start_turn(message)
    end

    # Spawn a worker thread for one agent turn. Library exceptions are
    # logged (the long-running TUI takes the "exceptions logged, our
    # bugs raise" path from CLAUDE.md); cancellation is silent because
    # {TuileListener} already rendered the {Pikuri::Agent::Event::Cancelled}
    # event before the exception re-raised.
    #
    # @param message [String]
    # @return [void]
    def start_turn(message)
      Thread.new do
        @agent.run_loop(user_message: message)
      rescue Pikuri::Agent::Control::Cancellable::Cancelled
        # Notice already rendered by the TuileListener; nothing else to do.
      rescue StandardError => e
        Tuile.logger.error(
          "agent turn failed: #{e.class}: #{e.message}\n#{(e.backtrace || []).join("\n")}"
        )
      ensure
        @screen.event_queue.submit { @turn_in_progress = false }
      end
    end

    # @return [void]
    def open_log_popup
      return if @log_popup.open?

      @log_popup.open
    end

    # @return [void]
    def cancel_turn
      return unless @turn_in_progress

      @agent.cancellable&.cancel!
    end

    # Called by {CountingLogIO} on every error-class log write. The
    # callback fires on the *logging* thread (any thread), so the
    # actual counter mutation and label update are marshaled to the
    # event-loop thread via +submit+.
    #
    # @param _line [String] the offending log line (ignored — we only
    #   need the count)
    # @return [void]
    def on_error_logged(_line)
      @screen.event_queue.submit do
        @error_count += 1
        @status_label.text = status_text
      end
    end

    # Fires when the log popup is dismissed (ESC / q from inside the
    # popup). Runs on the event-loop thread, so direct mutation is safe.
    #
    # @return [void]
    def reset_error_count
      @error_count = 0
      @status_label.text = status_text
    end

    # Whatever lands in {@status_label}'s slot — the conversation
    # Window's bottom border footer. Pure read of {@error_count}; all
    # callers are on the event-loop thread.
    #
    # @return [String]
    def status_text
      @error_count.zero? ? 'logs (l)' : "⚠ logs (#{@error_count})"
    end

    # @param exception [StandardError]
    # @return [void]
    def on_screen_error(exception)
      Tuile.logger.error(
        "#{exception.class}: #{exception.message}\n#{(exception.backtrace || []).join("\n")}"
      )
    end
  end
end
