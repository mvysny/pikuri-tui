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
  # {Shared::ConversationWindow::Listener} / {Shared::StatusFooterUpdater}) and the confirmer,
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
  # run on the UI thread. App runs {Tuile::Screen#run_event_loop} on the
  # caller's thread and delegates the off-thread turn lifecycle — worker
  # thread, mid-turn injection, concurrency guard, spinner, Ctrl+C
  # escalation — to a composed {Shared::AgentSession} (see its threading
  # contract). Enter routes to +session.submit+, Ctrl+C to
  # +session.interrupt+, leader +c+ to +session.clear_conversation+. The
  # {ConfirmerPopup} bridges the other way: a tool on the worker thread
  # calls +confirm?+, which submits the popup to the UI thread and blocks
  # the worker until the user answers (see its docs).
  #
  # UI-thread-confined.
  class App
    LOG = Pikuri.logger_for('code')
    private_constant :LOG

    # @return [Tuile::Screen] the (already-installed) screen this app
    #   runs on.
    attr_reader :screen

    # @return [Pikuri::Agent] the agent the build block returned.
    attr_reader :agent

    # @return [Shared::AgentSession] the turn-lifecycle engine this shell
    #   composes; Enter / Ctrl+C / leader +c+ delegate into it. Exposed for
    #   tests.
    attr_reader :session

    # @return [Tuile::Component::TextView] the conversation transcript
    #   pane. Exposed primarily for tests; production code should reach
    #   it through the {Shared::ConversationWindow::Listener}.
    def conversation_view = @conversation_window.view

    # @return [TaskListWindow::Listener] the task-pane listener (owned by
    #   the {WorkspaceSidebar}'s task pane) handed to the build block; the
    #   host wires it into the agent's +ListenerList+.
    def task_listener = @sidebar.task_listener

    # @return [WorkspaceSidebar] the tasks + git sidebar; owns the
    #   {GitWatcher} (started/stopped in {#run}) and the {GitDiffPopup} the
    #   leader menu's +d+ entry opens. Exposed for tests.
    attr_reader :sidebar

    # @return [Tuile::Component::LogWindow] the eager-constructed
    #   diagnostic window (owned by the {Shared::Log::UI}).
    def log_window = @log_ui.log_window

    # @return [Pikuri::Agent::Listener::TokenLog] the main agent's token
    #   log, fed into the conversation-window {Shared::StatusFooterUpdater}.
    attr_reader :token_log

    # @return [Shared::StatusFooterUpdater] the footer, which doubles as the
    #   model-name listener, yielded to the build block. The host must include
    #   it in the agent's +ListenerList+ so +ModelSwitched+ events reach it.
    def status_footer_updater = @conversation_window.status_footer_updater

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
    # @param markdown [Boolean] forwarded to {Shared::ConversationWindow}'s
    #   +markdown:+ flag (default +true+).
    # @param tool_formatters [Hash{String => Object}] forwarded to
    #   {Shared::ConversationWindow}'s +tool_formatters:+ — the per-tool diff
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
    # @yield [listener, confirmer, task_listener, status_footer_updater, plan_mode_listener]
    #   one-shot factory invoked exactly once during construction.
    #   Receives the {Shared::ConversationWindow::Listener} bound to this app's conversation
    #   pane, the {ConfirmerPopup}, the {TaskListWindow::Listener} bound to the
    #   sidebar task pane, the {Shared::StatusFooterUpdater} that keeps the footer
    #   model name current, and the {PlanModeListener} that keeps the
    #   footer plan-mode badge current; must return a constructed
    #   +Pikuri::Agent+ whose +ListenerList+ includes the listeners and
    #   the +token_log+ exposed at {#token_log}, with the confirmer wired
    #   into its write/bash tools.
    # @yieldparam listener [Shared::ConversationWindow::Listener] the conversation-pane
    #   listener; include it in the agent's +ListenerList+.
    # @yieldparam confirmer [ConfirmerPopup] the modal confirmer; pass
    #   it to the +Write+ / +Pikuri::Code::Bash+ tools.
    # @yieldparam task_listener [TaskListWindow::Listener] the task-pane listener;
    #   include it in the agent's +ListenerList+ (alongside the
    #   +Pikuri::Tasks::Extension+ that emits the events it renders).
    # @yieldparam status_footer_updater [Shared::StatusFooterUpdater] the footer,
    #   which doubles as the model-name listener; include it in the agent's +ListenerList+.
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

      build_components
      @log_ui.wire!
      @agent = build_agent.call(
        @conversation_window.listener, @confirmer, @sidebar.task_listener,
        @conversation_window.status_footer_updater, @plan_mode_listener
      )
      # Deferred from construction: the agent, hence its interloper,
      # doesn't exist until the build block has run.
      @session.agent = @agent
      @conversation_window.interloper = @agent.interloper
      # Seed the footer with the boot model (resolved from its transport);
      # Shared::StatusFooterUpdater#on_event takes over on every later switch.
      @conversation_window.current_model = @agent.transport

      @leader_menu = build_leader_menu
      @screen.on_error = method(:on_screen_error)
      @screen.content = @layout
      # Focus the window, not the inner area: Tuile's Window→content focus
      # cascade re-points onto the input area so the caret lands there.
      @screen.focused = @input_window
      register_shortcuts
    end

    # Runs the Tuile event loop, blocking the calling thread until the
    # user quits or the loop is otherwise stopped. Starts the
    # {WorkspaceSidebar}'s git poll before the loop and stops it in the
    # +ensure+, which also pairs +run_event_loop+ with
    # +Tuile::Screen#close+ so the terminal is cleared and the screen
    # singleton is unset regardless of how the loop exits.
    #
    # @return [void]
    def run
      @sidebar.start_git_watching
      @screen.run_event_loop
    ensure
      @sidebar.stop_git_watching
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

      @session = Shared::AgentSession.new(
        screen: @screen, conversation_window: @conversation_window,
        model_picker: @model_picker, logger: LOG
      )

      @input_window = Shared::InputWindow.new(on_submit: @session.method(:submit))

      # The tasks + git sidebar as one box: it owns its tasks-over-git split,
      # the GitWatcher poll (started/stopped in #run), and the diff popup the
      # leader menu's 'd' entry opens.
      @sidebar = WorkspaceSidebar.new

      @confirmer = ConfirmerPopup.new(screen: @screen)
      @plan_mode_listener = PlanModeListener.new(footer: @conversation_window.status_footer_updater, screen: @screen)

      @layout = Layout.new(
        conversation: @conversation_window,
        input: @input_window,
        sidebar: @sidebar
      )
    end

    # Wire app-level keyboard shortcuts on the screen. Both bypass the
    # cursor-owner suppression that would otherwise let the focused
    # {Shared::InputWindow} swallow them, and both surface a hint in the status bar
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
    # - +Ctrl+C+ runs the {Shared::AgentSession#interrupt} escalation (cancel turn ->
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
      ) { @session.interrupt }
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
      menu.add('d', 'git diff') { @sidebar.open_diff }
      menu.add('p', 'plan mode') { toggle_plan_mode }
      menu.add('m', 'switch model') { @model_picker.open(current: @agent.transport) } if @model_picker.multiple?
      menu.add('c', 'clear conversation + context') { @session.clear_conversation }
      menu.add('q', 'quit') { quit }
      menu
    end

    # Stop the event loop, unwinding {#run} into +Screen#close+. The leader
    # menu's +q+ action — a hard quit, distinct from
    # {Shared::AgentSession#interrupt}'s escalation (no turn-cancel /
    # unfocus steps). Runs on the event-loop
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

    # @param exception [StandardError]
    # @return [void]
    def on_screen_error(exception)
      LOG.error(
        "#{exception.class}: #{exception.message}\n#{(exception.backtrace || []).join("\n")}"
      )
    end
  end
end
