# frozen_string_literal: true

require 'logger'
require 'pikuri-core'
require 'tuile'

module Code
  # The Tuile shell behind +bin/pikuri-tui-code+: the framed
  # conversation pane, the framed input pane, the eager diagnostic
  # +LogWindow+ (popup-visible via the {Shared::LeaderMenu}'s +l+ entry), the
  # +Ctrl+K+ menu / +Ctrl+C+ cancel
  # status-bar hints, and the agent loop on a worker thread. A parallel
  # copy of {Chat::App} (see {Code} for the duplicate-don't-share
  # rationale) with one addition: it owns a {ConfirmerPopup} and hands
  # it to the build block so the boot script can wire it into the
  # +Write+ / +Pikuri::Code::Bash+ tools.
  #
  # == Construction order
  #
  # The agent needs the conversation listeners and a {ConfirmerPopup}; the
  # listeners need the conversation +TextView+ and the confirmer needs
  # the +Screen+ — neither exists until the screen is initialized.
  # Resolving that is why the constructor takes a block: App builds the
  # components (the {Shared::ConversationWindow} owns the
  # {Shared::ConversationTextView::Listener} / {Shared::StatusFooterUpdater::ModelListener}) and the confirmer,
  # then yields +(listener, confirmer, …)+; the block returns a constructed
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
  #
  # UI-thread-confined (App's own methods; the worker it spawns runs the
  # pikuri loop off-thread and marshals back).
  class App
    LOG = Pikuri.logger_for('code')
    private_constant :LOG

    # @return [Tuile::Screen] the (already-installed) screen this app
    #   runs on.
    attr_reader :screen

    # @return [Pikuri::Agent] the agent the build block returned.
    attr_reader :agent

    # @return [Tuile::Component::TextView] the conversation transcript
    #   pane. Exposed primarily for tests; production code should reach
    #   it through the {Shared::ConversationTextView::Listener}.
    def conversation_view = @conversation_window.view

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
    #   diagnostic window (owned by the {Shared::Log::UI}).
    def log_window = @log_ui.log_window

    # @return [Pikuri::Agent::Listener::TokenLog] the main agent's token
    #   log, fed into the conversation-window {Shared::StatusFooterUpdater}.
    attr_reader :token_log

    # @return [Shared::StatusFooterUpdater::ModelListener] the footer model-name listener yielded to
    #   the build block. The host must include it in the agent's
    #   +ListenerList+ so +ModelSwitched+ events reach the footer.
    def model_listener = @conversation_window.model_listener

    # @return [PlanModeListener] the footer plan-mode-badge listener
    #   yielded to the build block. The host must include it in the
    #   agent's +ListenerList+ so +Pikuri::Code::PlanModeChanged+ events
    #   reach the footer. Dormant until a plan-mode transition fires
    #   (via {#toggle_plan_mode} or the model's enter/exit tools).
    attr_reader :plan_mode_listener

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
    # @param markdown [Boolean] forwarded to {Shared::ConversationTextView}'s
    #   +markdown:+ flag (default +true+).
    # @param tool_formatters [Hash{String => Object}] forwarded to
    #   {Shared::ConversationTextView}'s +tool_formatters:+ — the per-tool diff
    #   formatters ({EditFormatter} / {WriteFormatter}) the bin wires for
    #   the +edit+ / +write+ tools. Defaults to +{}+.
    # @param models [Array<Shared::Model::Choice>] the connections the leader menu's
    #   +m+ model picker offers, in display order. The +m+ menu entry is
    #   registered only when more than one is given; the model id → name
    #   map drives the footer's model segment regardless. Defaults to
    #   empty.
    # @param plan_mode [Pikuri::Workspace::ReadOnly] the shared
    #   plan-mode (read-only) flag — pass the *same* instance the host
    #   threaded into the +read_only:+ of +Pikuri::Workspace::Extension+
    #   and +Pikuri::Code::Extension+, so the leader menu's +p+ toggle and
    #   the model's +enter_plan_mode+/+exit_plan_mode+ tools flip one flag.
    #   The +p+ toggle is always registered; the default is a fresh flag
    #   starting *not* in plan mode. The footer badge tracks it via
    #   {PlanModeListener}.
    # @yield [listener, confirmer, task_listener, model_listener, plan_mode_listener]
    #   one-shot factory invoked exactly once during construction.
    #   Receives the {Shared::ConversationTextView::Listener} bound to this app's conversation
    #   pane, the {ConfirmerPopup}, the {TaskListener} bound to the
    #   sidebar task pane, the {Shared::StatusFooterUpdater::ModelListener} that keeps the footer
    #   model name current, and the {PlanModeListener} that keeps the
    #   footer plan-mode badge current; must return a constructed
    #   +Pikuri::Agent+ whose +ListenerList+ includes the listeners and
    #   the +token_log+ exposed at {#token_log}, with the confirmer wired
    #   into its write/bash tools.
    # @yieldparam listener [Shared::ConversationTextView::Listener] the conversation-pane
    #   listener; include it in the agent's +ListenerList+.
    # @yieldparam confirmer [ConfirmerPopup] the modal confirmer; pass
    #   it to the +Write+ / +Pikuri::Code::Bash+ tools.
    # @yieldparam task_listener [TaskListener] the task-pane listener;
    #   include it in the agent's +ListenerList+ (alongside the
    #   +Pikuri::Tasks::Extension+ that emits the events it renders).
    # @yieldparam model_listener [Shared::StatusFooterUpdater::ModelListener] the footer model-name
    #   listener; include it in the agent's +ListenerList+.
    # @yieldparam plan_mode_listener [PlanModeListener] the footer
    #   plan-mode-badge listener; include it in the agent's
    #   +ListenerList+ (alongside the +Pikuri::Code::Extension+ that emits
    #   the events it renders).
    # @yieldreturn [Pikuri::Agent] the wired agent.
    # @raise [LocalJumpError] if no block is given.
    def initialize(token_log: Pikuri::Agent::Listener::TokenLog.new, project_root: Dir.pwd, markdown: true, tool_formatters: {}, models: [], plan_mode: Pikuri::Workspace::ReadOnly.new, &build_agent)
      raise LocalJumpError, 'Code::App requires a block that builds the Pikuri::Agent' unless block_given?

      @screen = Tuile::Screen.instance
      @token_log = token_log
      @project_root = project_root
      @markdown = markdown
      @tool_formatters = tool_formatters
      @model_picker = Shared::Model::Picker.new(models: models)
      @plan_mode = plan_mode
      @turn_in_progress = false

      build_components
      @log_ui.wire!
      @agent = build_agent.call(
        @conversation_window.listener, @confirmer, @task_listener,
        @conversation_window.model_listener, @plan_mode_listener
      )
      # Deferred from construction: the agent, hence its interloper,
      # doesn't exist until the build block has run.
      @conversation_window.interloper = @agent.interloper
      # Seed the footer with the boot model (resolved from its transport);
      # Shared::StatusFooterUpdater::ModelListener takes over on every later switch.
      @conversation_window.current_model = @agent.transport

      @leader_menu = build_leader_menu
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
      @screen.run_event_loop
    ensure
      @git_watcher.stop
      @screen.close
    end

    private

    # @return [void]
    def build_components
      @log_ui = Shared::Log::UI.new(screen: @screen)

      @conversation_window = Shared::ConversationWindow.new(
        token_log: @token_log, title: @project_root.to_s, markdown: @markdown,
        tool_formatters: @tool_formatters, model_names: @model_picker.names
      )

      @input = Shared::InputArea.new(on_submit: method(:submit_message))
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
      # near-fullscreen popup opened from the leader menu's 'd' entry. Built
      # eagerly (like the
      # diagnostic LogWindow) so the watcher can write the latest diff into
      # it every poll whether or not the popup is currently shown.
      @git_diff_view = Tuile::Component::TextView.new
      @git_diff_window = Tuile::Component::Window.new('Git diff')
      @git_diff_window.content = @git_diff_view
      @git_diff_window.scrollbar = true
      @git_diff_popup = GitDiffPopup.new(diff_window: @git_diff_window)

      @confirmer = ConfirmerPopup.new(screen: @screen)
      @task_listener = TaskListener.new(text_view: @tasks_view, screen: @screen)
      @plan_mode_listener = PlanModeListener.new(footer: @conversation_window.status_footer_updater, screen: @screen)
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
    # {Shared::InputArea} swallow them, and both surface a hint in the status bar
    # (which is why Ctrl+K is registered via {Shared::Log::UI#install_shortcut} —
    # its hint mutates as errors accrue).
    #
    # All app actions are reached through one of two keys; every other
    # binding (logs / git diff / plan mode / switch model) lives behind the
    # {Shared::LeaderMenu}:
    #
    # - +Ctrl+K+ opens the {Shared::LeaderMenu} command popup. +over_popups: false+
    #   (the default), so it can't stack over an open popup. The {Shared::Log::UI} owns
    #   this binding because its hint also carries the unread-error tally —
    #   the only always-visible status-bar surface.
    # - +Ctrl+C+ runs the {#on_interrupt} escalation (cancel turn ->
    #   unfocus -> quit). The one direct accelerator kept: it is the urgent
    #   mid-turn interrupt, not a command we want behind a chord. Also
    #   +over_popups: false+: a popup means the user isn't interacting with
    #   the LLM, so Ctrl+C is the popup's business, not ours. The trade-off
    #   is that you can't cancel a running turn while a popup happens to be
    #   open — close it (ESC/q) first — and that a {ConfirmerPopup} is
    #   dismissed by declining (ESC/q), not by Ctrl+C.
    #
    # @return [void]
    def register_shortcuts
      @screen.register_global_shortcut(
        Tuile::Keys::CTRL_C,
        hint: "^C #{@screen.theme.error('cancel')}"
      ) { on_interrupt }
      @log_ui.install_shortcut { @leader_menu.open }
    end

    # Build the {Shared::LeaderMenu} for the coding shell: logs, git diff, plan
    # mode, switch model (only when there's more than one connection), and
    # a hard quit. The model entry is registered only when there's
    # something to switch to, so the menu never offers a no-op pick.
    #
    # @return [Shared::LeaderMenu]
    def build_leader_menu
      menu = Shared::LeaderMenu.new(screen: @screen)
      menu.add('l', 'logs') { @log_ui.open }
      menu.add('d', 'git diff') { open_git_diff_popup }
      menu.add('p', 'plan mode') { toggle_plan_mode }
      menu.add('m', 'switch model') { @model_picker.open(current: @agent.transport) } if @model_picker.multiple?
      menu.add('c', 'clear conversation + context') { clear_conversation }
      menu.add('q', 'quit') { quit }
      menu
    end

    # Reset the agent to a fresh-conversation state via
    # +Pikuri::Agent#clear_conversation+ (chat history, controls, and
    # each extension's conversation-scoped state — the task list clears,
    # the workspace read-record drops). That emits a single
    # +Pikuri::Agent::Event::Reset+, off which the {Shared::ConversationTextView::Listener} wipes
    # the conversation pane and the +TokenLog+ zeroes the footer's context
    # snapshot — so this method only kicks the agent; the visible reset
    # falls out of the event stream. The leader menu's +c+ action.
    #
    # Confined to between-turns: +clear_conversation+ is not designed to
    # race an in-flight +run_loop+ (the chat is single-thread-confined,
    # like a mid-conversation model switch), so while a turn is running
    # this is a no-op, logged to the diagnostic pane. Runs on the
    # event-loop thread (deferred by {Shared::LeaderMenu}), so the
    # +@turn_in_progress+ read is safe.
    #
    # @return [void]
    def clear_conversation
      if @turn_in_progress
        LOG.warn('clear conversation ignored: a turn is in progress')
        return
      end

      @agent.clear_conversation
    end

    # Stop the event loop, unwinding {#run} into +Screen#close+. The leader
    # menu's +q+ action — a hard quit, distinct from {#on_interrupt}'s
    # escalation (no turn-cancel / unfocus steps). Runs on the event-loop
    # thread (deferred by {Shared::LeaderMenu}), so +stop+ is safe to call.
    #
    # @return [void]
    def quit
      @screen.event_queue.stop
    end

    # Flip the shared {Pikuri::Workspace::ReadOnly} plan-mode flag —
    # enter if off, exit if on. Runs on the UI thread (global-shortcut
    # dispatch); the flag is thread-safe, and the footer badge updates
    # through {PlanModeListener} off the +PlanModeChanged+ event the flip
    # emits, so this stays a one-liner and the model-flip path renders the
    # same way. Idempotent transitions
    # ({Pikuri::Workspace::ReadOnly#activate!}/{#deactivate!}) make a
    # double-press harmless.
    #
    # @return [void]
    def toggle_plan_mode
      @plan_mode.active? ? @plan_mode.deactivate! : @plan_mode.activate!
    end

    # @param message [String] non-empty draft handed up by {Shared::InputArea}
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
    # @param message [String] non-empty draft handed up by {Shared::InputArea}
    # @return [void]
    def queue_mid_turn(message)
      interloper = @agent.interloper
      if interloper.nil?
        LOG.warn('mid-turn message dropped: the agent has no Interloper wired')
        return
      end

      interloper.inject_user_message(message)
    end

    # Spawn a worker thread for one agent turn. Library exceptions are
    # logged (the long-running TUI takes the "exceptions logged, our
    # bugs raise" path from CLAUDE.md) and a short red one-liner is
    # echoed into the conversation pane; cancellation is silent because
    # {Shared::ConversationTextView::Listener} already rendered the +Cancelled+ event.
    #
    # @param message [String]
    # @return [void]
    def start_turn(message)
      # Consume the picker's pending model switch (if any) on the UI
      # thread, before the worker spawns: run_loop applies it at the top
      # of the turn. take_pending clears it so it's applied at most once.
      transport = @model_picker.take_pending
      @conversation_window.start_animation
      Thread.new do
        @agent.run_loop(user_message: message, transport: transport)
      rescue Pikuri::Agent::Control::Cancellable::Cancelled
        # Notice already rendered by the Shared::ConversationTextView::Listener; nothing else to do.
      rescue StandardError => e
        LOG.error(
          "agent turn failed: #{e.class}: #{e.message}\n#{(e.backtrace || []).join("\n")}"
        )
        @conversation_window.render_turn_error(e)
      ensure
        @screen.event_queue.submit do
          @conversation_window.stop_animation
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
    # 1. A turn is running -> cancel it. The
    #    {Shared::ConversationTextView::Listener} renders the +Cancelled+ event; the worker's
    #    +ensure+ clears {@turn_in_progress}.
    # 2. Nothing running but something is focused (normally the {Shared::InputArea})
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

    # @param exception [StandardError]
    # @return [void]
    def on_screen_error(exception)
      LOG.error(
        "#{exception.class}: #{exception.message}\n#{(exception.backtrace || []).join("\n")}"
      )
    end
  end
end
