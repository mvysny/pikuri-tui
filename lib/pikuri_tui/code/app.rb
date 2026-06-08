# frozen_string_literal: true

require 'logger'
require 'pikuri-core'
require 'tuile'

module PikuriTui
  module Code
    # The Tuile shell behind +bin/pikuri-tui-code+: the framed
    # conversation pane, the framed input pane, the eager diagnostic
    # +LogWindow+ (popup-visible on Ctrl+L), the +Ctrl+L+ / +Ctrl+C+
    # status-bar hints, and the agent loop on a worker thread. A parallel
    # copy of {Chat::App} (see {Code} for the duplicate-don't-share
    # rationale) with one addition: it owns a {ConfirmerPopup} and hands
    # it to the build block so the boot script can wire it into the
    # +Write+ / +Pikuri::Code::Bash+ tools.
    #
    # == Construction order
    #
    # The agent needs a {TuileListener} and a {ConfirmerPopup}; the
    # listener needs the conversation +TextView+ and the confirmer needs
    # the +Screen+ — neither exists until the screen is initialized.
    # Resolving that is why the constructor takes a block: App builds the
    # screen, components, listener and confirmer, then yields
    # +(listener, confirmer)+; the block returns a constructed
    # +Pikuri::Agent+ that App installs. The bin uses this seam to pick
    # model / tools / workspace / sandbox without App learning about any
    # of them.
    #
    # == Screen ownership
    #
    # App assumes a {Tuile::Screen} (or {Tuile::FakeScreen}) is already
    # installed as the singleton — production code calls
    # +Tuile::Screen.new+ in the bin before constructing App; tests call
    # +Tuile::Screen.fake+.
    #
    # == Threading
    #
    # Per CLAUDE.md, Tuile is single-threaded and the agent loop must not
    # run on the UI thread:
    #
    # - {Tuile::Screen#run_event_loop} runs on the caller's thread.
    # - Each submitted user message spawns a fresh +Thread.new+ that calls
    #   +agent.run_loop+. The listener's renderings, the worker's status
    #   flag toggle, and any error logging marshal back via
    #   +screen.event_queue.submit+.
    # - The {ConfirmerPopup} bridges the other way: a tool on the worker
    #   thread calls +confirm?+, which submits the popup to the UI thread
    #   and blocks the worker until the user answers (see its docs).
    # - Concurrent turns are prevented by +@turn_in_progress+: while a
    #   turn is running, Enter routes the message into the agent's
    #   +Pikuri::Agent::Control::Interloper+ instead of starting a second
    #   +run_loop+. The flag is read and written only on the UI thread.
    class App
      # @return [Tuile::Screen] the (already-installed) screen this app
      #   runs on.
      attr_reader :screen

      # @return [Pikuri::Agent] the agent the build block returned.
      attr_reader :agent

      # @return [Tuile::Component::TextView] the conversation transcript
      #   pane. Exposed primarily for tests; production code should reach
      #   it through the {TuileListener}.
      attr_reader :conversation_view

      # @return [Tuile::Component::TextView] the sidebar task-list pane.
      #   Exposed for tests; production code reaches it through the
      #   {TaskListener}.
      attr_reader :tasks_view

      # @return [TaskListener] the task-pane listener handed to the build
      #   block; the host wires it into the agent's +ListenerList+.
      attr_reader :task_listener

      # @return [Tuile::Component::LogWindow] the eager-constructed
      #   diagnostic window.
      attr_reader :log_window

      # @return [Pikuri::Agent::Listener::TokenLog] the main agent's token
      #   log, fed into the conversation-window {FooterLabel}.
      attr_reader :token_log

      # @return [ConfirmerPopup] the modal confirmer handed to the build
      #   block; exposed for tests and for callers that want to inspect
      #   how the write/bash tools were wired.
      attr_reader :confirmer

      # @param token_log [Pikuri::Agent::Listener::TokenLog] the
      #   per-conversation token log whose +status_line+ feeds the footer.
      #   The host is responsible for wiring the same instance into the
      #   agent's +ListenerList+. Defaults to a fresh instance.
      # @param markdown [Boolean] forwarded to {TuileListener}'s
      #   +markdown:+ flag (default +true+).
      # @param capture_mouse [Boolean] forwarded to
      #   {Tuile::Screen#run_event_loop} (default +true+).
      # @yield [listener, confirmer, task_listener] one-shot factory
      #   invoked exactly once during construction. Receives the
      #   {TuileListener} bound to this app's conversation pane, the
      #   {ConfirmerPopup}, and the {TaskListener} bound to the sidebar
      #   task pane; must return a constructed +Pikuri::Agent+ whose
      #   +ListenerList+ includes both listeners and the +token_log+
      #   exposed at {#token_log}, with the confirmer wired into its
      #   write/bash tools.
      # @yieldparam listener [TuileListener] the conversation-pane
      #   listener; include it in the agent's +ListenerList+.
      # @yieldparam confirmer [ConfirmerPopup] the modal confirmer; pass
      #   it to the +Write+ / +Pikuri::Code::Bash+ tools.
      # @yieldparam task_listener [TaskListener] the task-pane listener;
      #   include it in the agent's +ListenerList+ (alongside the
      #   +Pikuri::Tasks::Extension+ that emits the events it renders).
      # @yieldreturn [Pikuri::Agent] the wired agent.
      # @raise [LocalJumpError] if no block is given.
      def initialize(token_log: Pikuri::Agent::Listener::TokenLog.new, markdown: true, capture_mouse: true, &build_agent)
        raise LocalJumpError, 'Code::App requires a block that builds the Pikuri::Agent' unless block_given?

        @screen = Tuile::Screen.instance
        @token_log = token_log
        @markdown = markdown
        @capture_mouse = capture_mouse
        @error_count = 0
        @turn_in_progress = false

        build_components
        wire_logging
        @agent = build_agent.call(@listener, @confirmer, @task_listener)
        # The footer renders a "N queued" segment off the interloper's
        # +peek+ while mid-turn injections are pending. Installed here
        # (rather than at FooterLabel construction) because the agent —
        # and therefore its interloper — doesn't exist until the build
        # block has run.
        @footer_label.interloper = @agent.interloper

        @screen.on_error = method(:on_screen_error)
        @screen.content = @layout
        @screen.focused = @input
        register_shortcuts
      end

      # Runs the Tuile event loop, blocking the calling thread until the
      # user quits or the loop is otherwise stopped. The +ensure+ pairs
      # +run_event_loop+ with +Tuile::Screen#close+ so the terminal is
      # cleared and the screen singleton is unset regardless of how the
      # loop exits.
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
        # Wrap-content: the footer covers only as much of the bottom
        # border as its text needs (and none of it while idle/empty).
        @conversation_window.footer_sizing = Tuile::Sizing::WRAP_CONTENT

        @input = Input.new(on_submit: method(:submit_message))
        @input_window = Tuile::Component::Window.new('You')
        @input_window.content = @input

        # Sidebar top: the agent's task list, fed by the TaskListener off
        # the Pikuri::Tasks::ListChanged stream.
        @tasks_view = Tuile::Component::TextView.new
        @tasks_window = Tuile::Component::Window.new('Tasks')
        @tasks_window.content = @tasks_view
        @tasks_window.scrollbar = true

        # Sidebar bottom: the git-diff pane. Empty for now — a later
        # session fills its content; the window exists so the layout is
        # real from the start.
        @git_view = Tuile::Component::TextView.new
        @git_window = Tuile::Component::Window.new('Git diff')
        @git_window.content = @git_view
        @git_window.scrollbar = true

        @listener = TuileListener.new(text_view: @conversation_view, screen: @screen, markdown: @markdown)
        @confirmer = ConfirmerPopup.new(screen: @screen)
        @task_listener = TaskListener.new(text_view: @tasks_view, screen: @screen)

        @layout = Layout.new(
          conversation: @conversation_window,
          input: @input_window,
          tasks: @tasks_window,
          git: @git_window
        )
      end

      # Wire app-level keyboard shortcuts on the screen. Both bypass the
      # cursor-owner suppression that would otherwise let the focused
      # {Input} swallow them, and both surface a hint in the status bar.
      #
      # - +Ctrl+L+ opens the log popup (suppressed while a popup is open).
      # - +Ctrl+C+ cancels the in-flight agent turn (+over_popups: true+
      #   so "stop what you're doing" works even with a popup open — and
      #   it lets the user bail out of a confirmation prompt's turn).
      #
      # @return [void]
      def register_shortcuts
        install_log_shortcut
        @screen.register_global_shortcut(
          Tuile::Keys::CTRL_C,
          over_popups: true,
          hint: "^C #{@screen.theme.error('cancel')}"
        ) { cancel_turn }
      end

      # (Re-)registers the +Ctrl+L+ global shortcut with a status-bar hint
      # reflecting the current {@error_count}. {Tuile::Screen} replaces
      # the binding in place on re-register, so this keeps the hint in
      # sync with the error counter.
      #
      # @return [void]
      def install_log_shortcut
        @screen.register_global_shortcut(Tuile::Keys::CTRL_L, hint: log_hint) { open_log_popup }
      end

      # Routes every pikuri / Tuile log line — and any exception trapped
      # by {Tuile::Screen#on_error} — through a single {CountingLogIO}
      # that both renders into {@log_window} and bumps the error counter.
      # Must run after {@log_window} exists and before the agent is built.
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
        if @turn_in_progress
          queue_mid_turn(message)
          return
        end

        @turn_in_progress = true
        start_turn(message)
      end

      # Route a message submitted while a turn is in flight into the
      # agent's +Pikuri::Agent::Control::Interloper+. The agent drains the
      # queue at its next +after_tool_result+ boundary. When the host
      # wired no interloper, the message is dropped with a warn in the
      # diagnostic log.
      #
      # @param message [String] non-empty draft handed up by {Input}
      # @return [void]
      def queue_mid_turn(message)
        interloper = @agent.interloper
        if interloper.nil?
          Tuile.logger.warn('mid-turn message dropped: the agent has no Interloper wired')
          return
        end

        interloper.inject_user_message(message)
      end

      # Spawn a worker thread for one agent turn. Library exceptions are
      # logged (the long-running TUI takes the "exceptions logged, our
      # bugs raise" path from CLAUDE.md) and a short red one-liner is
      # echoed into the conversation pane; cancellation is silent because
      # {TuileListener} already rendered the +Cancelled+ event.
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
            @conversation_view.add_line(@screen.theme.error("! #{e.class}: #{e.message}"))
          end
        ensure
          @screen.event_queue.submit do
            @footer_label.stop_animation
            @turn_in_progress = false
            deliver_pending_injections
          end
        end
      end

      # A turn can end with messages still sitting in the interloper queue
      # (the agent only drains it at +after_tool_result+ boundaries). Drain
      # the leftovers here and start a fresh turn with them, in submission
      # order, so every mid-turn message is delivered promptly. Fires after
      # a cancelled turn too: a mid-turn message is usually a correction,
      # and the cancel is what makes room for it.
      #
      # Runs on the UI thread (the caller marshals via +submit+), so the
      # +@turn_in_progress+ read inside {#submit_message} is safe.
      #
      # @return [void]
      def deliver_pending_injections
        pending = @agent.interloper&.drain! || []
        return if pending.empty?

        submit_message(pending.join("\n\n"))
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
      # callback fires on the *logging* thread, so the counter mutation
      # and hint refresh are marshaled to the event-loop thread.
      #
      # @param _line [String] the offending log line (ignored)
      # @return [void]
      def on_error_logged(_line)
        @screen.event_queue.submit do
          @error_count += 1
          install_log_shortcut
        end
      end

      # Fires when the log popup is dismissed. Runs on the event-loop
      # thread, so direct mutation is safe.
      #
      # @return [void]
      def reset_error_count
        @error_count = 0
        install_log_shortcut
      end

      # The status-bar hint advertised for +Ctrl+L+: plain "logs" in the
      # theme's +hint_color+ at zero errors, a +:error+-toned "⚠ logs (N)"
      # tally otherwise. Pure read of {@error_count}; all callers are on
      # the event-loop thread.
      #
      # @return [String]
      def log_hint
        if @error_count.zero?
          "^L #{@screen.theme.hint('logs')}"
        else
          "^L #{@screen.theme.error("⚠ logs (#{@error_count})")}"
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
