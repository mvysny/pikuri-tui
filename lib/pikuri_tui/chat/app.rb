# frozen_string_literal: true

require 'logger'
require 'pikuri-core'
require 'rainbow'
require 'tuile'

module PikuriTui
  module Chat
    # The Tuile shell behind +bin/pikuri-chat+: builds the framed conversation
    # pane, the framed input pane, the eager diagnostic +LogWindow+
    # (popup-visible on Ctrl+L), the +Ctrl+L+ / +Ctrl+C+ global-shortcut hints
    # in the screen-wide status bar, and wires the agent's loop onto a worker
    # thread so the UI thread stays free for repaints.
    #
    # == Construction order
    #
    # The agent needs a {TuileListener} in its +ListenerList+, and the
    # listener needs the conversation +TextView+ — which can't exist until
    # the screen is initialized. Resolving that cycle is why the
    # constructor takes a block: App builds the screen, the components,
    # and the listener, then yields the listener to the block; the block
    # returns a constructed +Pikuri::Agent+ that App installs. The bin
    # script uses this seam to pick model/tools/transport without App
    # learning about any of them.
    #
    # == Screen ownership
    #
    # App assumes a {Tuile::Screen} (or {Tuile::FakeScreen}) is already
    # installed as the singleton — production code calls +Tuile::Screen.new+
    # in the bin script before constructing App; tests call
    # +Tuile::Screen.fake+. That's intentional: App doesn't unilaterally
    # mount a real terminal screen, so a host that wants to inject a fake
    # for an integration test doesn't have to fight constructor order.
    #
    # == Threading
    #
    # Per CLAUDE.md, Tuile is single-threaded and the agent loop must not
    # run on the UI thread. App enforces this:
    #
    # - {Tuile::Screen#run_event_loop} runs on the caller's thread (the
    #   main thread for the bin script).
    # - Each submitted user message spawns a fresh +Thread.new+ that calls
    #   +agent.run_loop+. The listener's renderings, the worker's status
    #   flag toggle, and any error logging marshal back via
    #   +screen.event_queue.submit+ so they execute on the UI thread.
    # - Concurrent turns are prevented by +@turn_in_progress+: Enter is a
    #   no-op while a turn is running. The flag is read and written only on
    #   the UI thread.
    class App
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

      # @return [Pikuri::Agent::Listener::TokenLog] the main agent's
      #   token log, fed into the conversation-window {FooterLabel}.
      #   The host's build block must include this instance (or one
      #   the host supplied via the +token_log:+ ctor arg) in the
      #   agent's +ListenerList+ so it actually receives +Tokens+
      #   events; the App doesn't register listeners itself.
      attr_reader :token_log

      # @param token_log [Pikuri::Agent::Listener::TokenLog] the
      #   per-conversation token log whose +status_line+ feeds the
      #   conversation-window footer. The host is responsible for
      #   wiring the same instance into the agent's +ListenerList+
      #   (so it actually receives +Tokens+ events). Defaults to a
      #   fresh instance — tests that don't exercise the footer can
      #   ignore this knob.
      # @param markdown [Boolean] forwarded to {TuileListener}'s
      #   +markdown:+ flag (default +true+). When +false+, the
      #   conversation pane skips +TTY::Markdown+ and the streaming path
      #   uses {PassthroughBuffer} — appropriate for back-ends whose
      #   content is already in display form.
      # @yield [listener] one-shot factory invoked exactly once during
      #   construction. The block receives the {TuileListener} bound to
      #   this app's conversation pane and must return a constructed
      #   +Pikuri::Agent+ whose +ListenerList+ includes that listener
      #   and the +token_log+ exposed at {#token_log}.
      # @yieldparam listener [TuileListener] the conversation-pane
      #   listener; include it in the agent's +ListenerList+.
      # @yieldreturn [Pikuri::Agent] the wired agent.
      # @raise [LocalJumpError] if no block is given (no agent → no app).
      def initialize(token_log: Pikuri::Agent::Listener::TokenLog.new, markdown: true, capture_mouse: true, &build_agent)
        raise LocalJumpError, 'Chat::App requires a block that builds the Pikuri::Agent' unless block_given?

        @screen = Tuile::Screen.instance
        @token_log = token_log
        @markdown = markdown
        @capture_mouse = capture_mouse
        @error_count = 0
        @turn_in_progress = false

        build_components
        wire_logging
        @agent = build_agent.call(@listener)

        @screen.on_error = method(:on_screen_error)
        @screen.content = @layout
        @screen.focused = @input
        register_shortcuts
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
        @screen.run_event_loop(capture_mouse: @capture_mouse)
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
        @conversation_window.scrollbar = true
        @footer_label = FooterLabel.new(screen: @screen, token_log: @token_log)
        @conversation_window.footer = @footer_label

        @input = Input.new(on_submit: method(:submit_message))
        @input_window = Tuile::Component::Window.new('You')
        @input_window.content = @input

        @listener = TuileListener.new(text_view: @conversation_view, screen: @screen, markdown: @markdown)

        @layout = Layout.new(
          conversation: @conversation_window,
          input: @input_window
        )
      end

      # Wire app-level keyboard shortcuts on the screen. Both bypass the
      # cursor-owner suppression that would otherwise let the focused
      # {Input} swallow them, and both surface a hint in the screen's
      # status bar (which is why Ctrl+L is registered via
      # {#install_log_shortcut} — its hint mutates as errors accrue).
      #
      # - +Ctrl+L+ opens the log popup. +over_popups: false+ (the default)
      #   so the binding is suppressed while the popup is already open
      #   (the popup gets the key normally; {LogWindow} ignores it).
      # - +Ctrl+C+ cancels the in-flight agent turn. +over_popups: true+
      #   so "stop what you're doing" works even with the log popup open
      #   — the user's expectation that Ctrl+C interrupts a running turn
      #   shouldn't depend on which window happens to be on top.
      #
      # @return [void]
      def register_shortcuts
        install_log_shortcut
        @screen.register_global_shortcut(
          Tuile::Keys::CTRL_C,
          over_popups: true,
          hint: "^C #{Rainbow('cancel').red}"
        ) { cancel_turn }
      end

      # (Re-)registers the +Ctrl+L+ global shortcut with a status-bar hint that
      # reflects the current {@error_count}. {Tuile::Screen} replaces the
      # binding in place on re-register, so this is also how the hint stays in
      # sync with the error counter — {#on_error_logged} and
      # {#reset_error_count} both call back here after touching the count.
      #
      # @return [void]
      def install_log_shortcut
        @screen.register_global_shortcut(Tuile::Keys::CTRL_L, hint: log_hint) { open_log_popup }
      end

      # Routes every pikuri / Tuile log line — and any exception trapped
      # by {Tuile::Screen#on_error} — through a single {CountingLogIO}
      # that both renders into {@log_window} and bumps the error counter
      # backing the +Ctrl+L+ status-bar hint. Must run after {@log_window}
      # exists and before the agent is built (the agent's construction
      # can already log).
      #
      # @return [void]
      def wire_logging
        io = CountingLogIO.new(log_window: @log_window, on_error: method(:on_error_logged))
        Tuile.logger = Logger.new(io)
        Pikuri.log_io = io
      end

      # @param message [String] non-empty draft handed up by {Input}
      # @return [void]
      def submit_message(message)
        return if @turn_in_progress

        @turn_in_progress = true
        start_turn(message)
      end

      # Spawn a worker thread for one agent turn. Library exceptions are
      # logged (the long-running TUI takes the "exceptions logged, our
      # bugs raise" path from CLAUDE.md) and a short red one-liner is
      # echoed into the conversation pane so the user notices the turn
      # ended in failure without having to open the log popup;
      # cancellation is silent because {TuileListener} already rendered
      # the {Pikuri::Agent::Event::Cancelled} event before the exception
      # re-raised.
      #
      # @param message [String]
      # @return [void]
      def start_turn(message)
        @footer_label.start_animation
        Thread.new do
          @agent.run_loop(user_message: message)
        rescue Pikuri::Agent::Control::Cancellable::Cancelled
          # Notice already rendered by the TuileListener; nothing else to do.
        rescue StandardError => e
          Tuile.logger.error(
            "agent turn failed: #{e.class}: #{e.message}\n#{(e.backtrace || []).join("\n")}"
          )
          @screen.event_queue.submit do
            @conversation_view.add_line(Rainbow("! #{e.class}: #{e.message}").red.to_s)
          end
        ensure
          @screen.event_queue.submit do
            @footer_label.stop_animation
            @turn_in_progress = false
          end
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
      # actual counter mutation and hint refresh are marshaled to the
      # event-loop thread via +submit+.
      #
      # @param _line [String] the offending log line (ignored — we only
      #   need the count)
      # @return [void]
      def on_error_logged(_line)
        @screen.event_queue.submit do
          @error_count += 1
          install_log_shortcut
        end
      end

      # Fires when the log popup is dismissed (ESC / q from inside the
      # popup). Runs on the event-loop thread, so direct mutation is safe.
      #
      # @return [void]
      def reset_error_count
        @error_count = 0
        install_log_shortcut
      end

      # The status-bar hint advertised for +Ctrl+L+. The plain "logs"
      # variant in cadetblue matches the Tuile-supplied "q quit" /
      # "q Close" styling; the warning variant in red foregrounds the
      # error tally so the user notices something broke without us
      # writing log lines into the conversation pane.
      #
      # Pure read of {@error_count}; all callers are on the event-loop
      # thread.
      #
      # @return [String]
      def log_hint
        if @error_count.zero?
          "^L #{Rainbow('logs').cadetblue}"
        else
          "^L #{Rainbow("⚠ logs (#{@error_count})").red}"
        end
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
end
