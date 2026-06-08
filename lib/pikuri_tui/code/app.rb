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

      # @return [GitWatcher] the background poller that keeps the sidebar
      #   change summary and the {GitDiffPopup} diff current; started/stopped
      #   by {#run}. Exposed for tests.
      attr_reader :git_watcher

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
      # @param project_root [Pathname, String] the workspace root shown
      #   as the conversation window title. Defaults to the current
      #   working directory.
      # @param markdown [Boolean] forwarded to {TuileListener}'s
      #   +markdown:+ flag (default +true+).
      # @param tool_formatters [Hash{String => Object}] forwarded to
      #   {TuileListener}'s +tool_formatters:+ — the per-tool diff
      #   formatters ({EditFormatter} / {WriteFormatter}) the bin wires for
      #   the +edit+ / +write+ tools. Defaults to +{}+.
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
      def initialize(token_log: Pikuri::Agent::Listener::TokenLog.new, project_root: Dir.pwd, markdown: true, tool_formatters: {}, capture_mouse: true, &build_agent)
        raise LocalJumpError, 'Code::App requires a block that builds the Pikuri::Agent' unless block_given?

        @screen = Tuile::Screen.instance
        @token_log = token_log
        @project_root = project_root
        @markdown = markdown
        @tool_formatters = tool_formatters
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
      # user quits or the loop is otherwise stopped. Starts the
      # {GitWatcher}'s background poll before the loop and stops it in the
      # +ensure+, which also pairs +run_event_loop+ with
      # +Tuile::Screen#close+ so the terminal is cleared and the screen
      # singleton is unset regardless of how the loop exits.
      #
      # @return [void]
      def run
        @git_watcher.start
        @screen.run_event_loop(capture_mouse: @capture_mouse)
      ensure
        @git_watcher.stop
        @screen.close
      end

      private

      # @return [void]
      def build_components
        @log_window = Tuile::Component::LogWindow.new('Log')
        @log_popup = LogPopup.new(log_window: @log_window, on_dismiss: method(:reset_error_count))

        @conversation_view = Tuile::Component::TextView.new
        @conversation_view.auto_scroll = true

        @conversation_window = Tuile::Component::Window.new(@project_root.to_s)
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

        # Sidebar bottom: the change summary (one "XY path +N -N" line per
        # changed file), kept current by a {GitWatcher} polling git off the
        # UI thread (started in {#run}). The window exists from the start so
        # the layout is real before the first poll lands.
        @git_summary_view = Tuile::Component::TextView.new
        @git_window = Tuile::Component::Window.new('Changes')
        @git_window.content = @git_summary_view
        @git_window.scrollbar = true

        # The full colored diff is too wide for the sidebar, so it lives in a
        # near-fullscreen popup opened on Ctrl+G. Built eagerly (like the
        # diagnostic LogWindow) so the watcher can write the latest diff into
        # it every poll whether or not the popup is currently shown.
        @git_diff_view = Tuile::Component::TextView.new
        @git_diff_window = Tuile::Component::Window.new('Git diff')
        @git_diff_window.content = @git_diff_view
        @git_diff_window.scrollbar = true
        @git_diff_popup = GitDiffPopup.new(diff_window: @git_diff_window)

        @listener = TuileListener.new(
          text_view: @conversation_view, screen: @screen,
          markdown: @markdown, tool_formatters: @tool_formatters
        )
        @confirmer = ConfirmerPopup.new(screen: @screen)
        @task_listener = TaskListener.new(text_view: @tasks_view, screen: @screen)
        @git_watcher = GitWatcher.new(
          summary_view: @git_summary_view, diff_view: @git_diff_view, screen: @screen
        )

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
      # - +Ctrl+G+ opens the {GitDiffPopup} with the full colored diff. Like
      #   Ctrl+L it registers +over_popups: false+, so it never stacks a
      #   second popup over an open one.
      # - +Ctrl+C+ runs the {#on_interrupt} escalation (cancel turn ->
      #   unfocus -> quit). Also +over_popups: false+: a popup means the
      #   user isn't interacting with the LLM, so Ctrl+C is the popup's
      #   business, not ours. The trade-off is that you can't cancel a
      #   running turn while the log popup happens to be open — close it
      #   (ESC/q) first — and that a {ConfirmerPopup} is dismissed by
      #   declining (ESC/q), not by Ctrl+C.
      #
      # @return [void]
      def register_shortcuts
        install_log_shortcut
        @screen.register_global_shortcut(
          Tuile::Keys::CTRL_G,
          hint: "^G #{@screen.theme.hint('diff')}"
        ) { open_git_diff_popup }
        @screen.register_global_shortcut(
          Tuile::Keys::CTRL_C,
          hint: "^C #{@screen.theme.error('cancel')}"
        ) { on_interrupt }
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

      # Opens the {GitDiffPopup} with the latest full diff (already kept
      # current by {GitWatcher}). A no-op if it is already open. Runs on the
      # event-loop thread (global-shortcut dispatch).
      #
      # @return [void]
      def open_git_diff_popup
        return if @git_diff_popup.open?

        @git_diff_popup.open
      end

      # The +Ctrl+C+ escalation, mirroring ESC's two-press quit but driven
      # explicitly because a global shortcut fires before the pane and so
      # never "falls through" to the loop's unhandled-key quit the way ESC
      # does. Three states, in priority order:
      #
      # 1. A turn is running -> cancel it (the historical behavior). The
      #    {TuileListener} renders the +Cancelled+ event; the worker's
      #    +ensure+ clears {@turn_in_progress}.
      # 2. Nothing running but something is focused (normally the {Input})
      #    -> drop focus, the same visible effect as ESC on the input.
      # 3. Nothing running and nothing focused -> stop the event loop, which
      #    unwinds {#run} into +Screen#close+. This is exactly what an
      #    unhandled ESC does (+EventQueue#stop+).
      #
      # Registered +over_popups: false+, so this never runs while a popup is
      # open — no need to guard the unfocus/quit steps against orphaning a
      # modal popup's focus or quitting out from under it. In particular a
      # {ConfirmerPopup} (always open mid-turn) is dismissed by declining
      # (ESC/q), not by Ctrl+C.
      #
      # Runs on the UI thread (global-shortcut blocks dispatch from the event
      # loop), so touching +focused=+ / +event_queue.stop+ and reading
      # {@turn_in_progress} are all safe.
      #
      # @return [void]
      def on_interrupt
        if @turn_in_progress
          @agent.cancellable&.cancel!
        elsif @screen.focused
          @screen.focused = nil
        else
          @screen.event_queue.stop
        end
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
