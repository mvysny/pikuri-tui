# frozen_string_literal: true

require 'logger'
require 'pikuri-core'
require 'tuile'

module Code
  # The Tuile shell behind +bin/pikuri-tui-code+: the borderless conversation
  # pane, the status rule, the tinted full-width prompt, the tasks + git sidebar
  # ({WorkspaceSidebar}), the eager diagnostic +LogWindow+ (popup-visible via
  # the {Shared::LeaderMenu}'s +l+ entry), the +Ctrl+K+ menu / +Ctrl+C+ cancel
  # status-bar hints, and the agent loop on a worker thread.
  #
  # A parallel copy of {Chat::App} (see {Code} for the duplicate-don't-share
  # rationale), plus the coding-shell surface: a {TranscriptConfirmer} gating
  # +write+ / +bash+, the {WorkspaceSidebar} (tasks + git changes + diff
  # popup), plan mode (a status-rule badge via {PlanModeListener} + a leader-menu
  # +p+ toggle), and +edit+ / +write+ diffs.
  #
  # == Construction: App owns the agent
  #
  # App builds its own +Pikuri::Agent+ (see {#default_build_agent}) from the
  # {Shared::Config} handed to it plus the pre-built workspace objects the bin
  # assembles — see "What the bin still owns" below. The bin's job ends at CLI
  # + config + workspace/sandbox/trust + screen; the agent, its tools, and its
  # listeners are the shell's identity and live here.
  #
  # The optional +transport:+ is a **test seam**, not production ceremony: a
  # spec passes a +Pikuri::Testing.fake_transport+ so App builds its *real*
  # agent — the real {#default_build_agent} listener/tool/extension wiring — on
  # a scripted-HTTP backend, skipping the network / RubyLLM / MCP-verify cost.
  # Production omits it and boots on the config's first connection. Only the
  # transport is injectable because the agent's collaborators (the conversation
  # listener, the confirmer, the task listener, the status rule, the plan-mode
  # listener) are App's own objects, reached through the
  # {Shared::ConversationTextView} / {WorkspaceSidebar} and App ivars directly.
  #
  # == What the bin still owns (why this isn't just +config:+)
  #
  # Unlike {Chat::App} / {Computer::App}, this constructor takes several
  # already-built objects because they can't be a pure post-screen object
  # graph: the interactive git-trust prompt needs +filesystem.project_root+
  # and a live pre-screen terminal (→ +trusted_repo+), so +filesystem+ is
  # pre-screen; +filesystem.readable+ folds in +skill_catalog.roots+, so
  # +skill_catalog+ is pre-screen; +filesystem+ / +sandbox+ / +system_prompt+
  # all depend on CLI flags absent from config (+--yolo+ / +--readable+ /
  # +--writable+). The bin builds those and passes them; App owns everything
  # derivable from +config+ (models, plan-mode flag, tool formatters, the MCP
  # registry) plus the agent graph.
  #
  # == Screen ownership
  #
  # App assumes a {Tuile::Screen} (or {Tuile::FakeScreen}) is already
  # installed as the singleton — the bin calls +Tuile::Screen.new+ before
  # constructing App; tests call +Tuile::Screen.fake+.
  #
  # == Threading
  #
  # Per CLAUDE.md, Tuile is single-threaded and the agent loop must not run on
  # the UI thread. App runs {Tuile::Screen#run_event_loop} on the caller's
  # thread and delegates the off-thread turn lifecycle — worker thread,
  # mid-turn injection, concurrency guard, spinner, Ctrl+C escalation — to a
  # composed {Shared::AgentSession} (see its threading contract). Enter routes
  # to +session.submit+, Ctrl+C to {#interrupt}, leader +c+ to
  # +session.clear_conversation+. The {TranscriptConfirmer} bridges the other
  # way: a tool on the worker thread calls +confirm?+, which submits the
  # question to the UI thread and parks the worker until the user answers (see
  # its docs).
  #
  # UI-thread-confined.
  class App
    LOG = Pikuri.logger_for('code')
    private_constant :LOG

    # The +/sidebar+ arguments, onto {Layout::SIDEBAR_MODES}. +off+ is an alias
    # for +hidden+ because that is what a hand reaches for; a blank argument
    # cycles instead.
    #
    # @return [Hash{String => Symbol}]
    SIDEBAR_ARGUMENTS = { 'full' => :full, 'narrow' => :narrow, 'hidden' => :hidden, 'off' => :hidden }.freeze

    # @return [Tuile::Screen] the (already-installed) screen this app
    #   runs on.
    attr_reader :screen

    # The shell's pane layout — not the screen's content component, which is
    # the {Shared::RootLayout} stacking this over {#status_bar}.
    #
    # @return [Code::Layout]
    attr_reader :layout

    # @return [Shared::StatusBar] the bottom row.
    attr_reader :status_bar

    # @return [Shared::Config] the resolved configuration the bin loaded;
    #   drives the model list, the sandbox/confirm posture, the web-search
    #   provider keys, and the MCP registry {#default_build_agent} builds.
    attr_reader :config

    # @return [Pikuri::Agent] the agent App built ({#default_build_agent}, or a
    #   test override block's stand-in). Exposed so callers (and tests) can
    #   inspect tools/listeners/transport after wiring.
    attr_reader :agent

    # @return [Shared::AgentSession] the turn-lifecycle engine this shell
    #   composes; Enter / Ctrl+C / leader +c+ delegate into it. Exposed for
    #   tests.
    attr_reader :session

    # @return [Tuile::Component::TextView] the conversation transcript
    #   pane. Exposed primarily for tests; production code should reach
    #   it through the {Shared::ConversationTextView::Listener}.
    attr_reader :conversation

    # @return [Pathname] the workspace root — the passed filesystem's
    #   normalized project root (writable ceiling + bash chdir target + the
    #   conversation window title). The single source of truth for where this
    #   shell is rooted.
    def project_root = @filesystem.project_root

    # @return [TaskListPane::Listener] the task-pane listener (owned by
    #   the {WorkspaceSidebar}'s task pane); {#default_build_agent} wires it
    #   into the agent's +ListenerList+.
    def task_listener = @sidebar.task_listener

    # @return [WorkspaceSidebar] the tasks + git sidebar; owns the
    #   {GitWatcher} (started/stopped in {#run}) and the {GitDiffPopup} the
    #   leader menu's +d+ entry opens. Exposed for tests.
    attr_reader :sidebar

    # @return [Tuile::Component::LogWindow] the eager-constructed
    #   diagnostic window (owned by the {Shared::Log::UI}).
    def log_window = @log_ui.log_window

    # @return [Pikuri::Agent::Listener::TokenLog] the main agent's token
    #   log, App-owned and fed into the {Shared::StatusRuleLabel}. {#default_build_agent} registers this
    #   same instance in the agent's +ListenerList+.
    attr_reader :token_log

    # @return [Shared::StatusRuleLabel] the status rule, which doubles as the
    #   model-name listener. {#default_build_agent} registers it in the
    #   agent's +ListenerList+ so +ModelSwitched+ events reach it.
    attr_reader :status_rule

    # @return [PlanModeListener] the status rule's plan-mode-badge listener,
    #   registered by {#default_build_agent} so +Pikuri::Code::PlanModeChanged+
    #   events reach the status rule. Dormant until a plan-mode transition fires
    #   (via {#toggle_plan_mode} or the model's enter/exit tools).
    attr_reader :plan_mode_listener

    # @return [TranscriptConfirmer] the in-transcript confirmer wired into the
    #   +write+ / +bash+ tools; exposed for tests and for callers that want to
    #   inspect how those tools were gated.
    attr_reader :confirmer

    # @param config [Shared::Config] the resolved configuration; App derives
    #   the model list (one {Shared::Model::Choice} per +config.llms+ entry,
    #   the first the boot connection), reads the sandbox/confirm posture, the
    #   web-search provider keys, and the +config.mcp+ server list.
    # @param filesystem [Pikuri::Workspace::Filesystem] the pre-built
    #   workspace (writable ceiling, bind root, relative-path base) — built in
    #   the bin because the git-trust prompt needs it pre-screen and it folds
    #   in +--readable+/+--writable+ and the skill-catalog roots. Threaded into
    #   the +Workspace+ / +Code+ extensions and the +write+ diff formatter.
    # @param sandbox [Pikuri::Code::Bash::Sandbox] the pre-built bash sandbox
    #   (Bubblewrap, or +NONE+ under +--no-sandbox+/+--yolo+) — built in the
    #   bin so its bwrap probe raises to a normal terminal pre-screen, next to
    #   the filesystem it wraps.
    # @param skill_catalog [Pikuri::Skill::Catalog] the skill catalog whose
    #   roots the bin already folded into +filesystem.readable+; wired into the
    #   +Skill+ extension.
    # @param command_registry [Pikuri::Command::Registry] the on-disk slash
    #   commands, whose roots the bin folded into +filesystem.readable+ for the
    #   same reason. Becomes one palette entry each, and one +Command+ extension
    #   so +/trifecta+ counts their untrusted leg.
    # @param system_prompt [String] the fully-assembled coding system prompt —
    #   built in the bin because it reads AGENTS.md/CLAUDE.md and reflects the
    #   sandbox / writable-paths / yolo posture (all bin-local decisions).
    # @param trusted_repo [Boolean] whether read-only git auto-approves — the
    #   result of the bin's interactive, persisted git-trust prompt. Flips the
    #   +PassiveCommandDetector+'s +allow_git:+. Default +false+.
    # @param markdown [Boolean] forwarded to {Shared::ConversationTextView}'s
    #   +markdown:+ flag (default +true+).
    # @param transport [Pikuri::Agent::ChatTransport, nil] test seam: the
    #   backend to build the real agent on. Omit in production (boots on the
    #   config's first connection); a spec passes a
    #   +Pikuri::Testing.fake_transport+ to run real turns against scripted
    #   HTTP — skipping the network / RubyLLM / MCP-verify cost. See the class
    #   header.
    def initialize(config:, filesystem:, sandbox:, skill_catalog:, command_registry:, system_prompt:,
                   trusted_repo: false, markdown: true, transport: nil)
      @screen = Tuile::Screen.instance
      @config = config
      @filesystem = filesystem
      @sandbox = sandbox
      @skill_catalog = skill_catalog
      @command_registry = command_registry
      @system_prompt = system_prompt
      @trusted_repo = trusted_repo
      @markdown = markdown
      @token_log = Pikuri::Agent::Listener::TokenLog.new
      # The shared plan-mode (read-only) flag: the leader menu's +p+ toggle and
      # the model's enter/exit tools flip this one instance (threaded into the
      # Workspace + Code extensions' read_only: by default_build_agent). The
      # message: is the plan-mode-specific refusal wording Edit/Write splice
      # into their "cannot write …" observation.
      @plan_mode = Pikuri::Workspace::ReadOnly.new(
        message: Pikuri::Code::Extension::PLAN_MODE_READONLY_MESSAGE
      )
      @models = config.llms.map { |llm| Shared::Model::Choice.from_llm(llm) }
      @model_picker = Shared::Model::Picker.new(models: @models)
      # Test seam: the backend the agent boots on. Production uses the config's
      # first connection; a spec injects a fake_transport (see class header).
      @boot_transport = transport || @models.first.transport
      # Built here, not in the agent block: the palette's
      # SkillActivationListener needs its gate before the agent exists.
      # +root:+ is what a `paths:` skill's globs are matched against.
      @skill_ext = Pikuri::Skill::Extension.new(catalog: @skill_catalog, root: project_root)

      build_components
      @log_ui.wire!
      @agent = default_build_agent
      @session.agent = @agent
      # Seeds the /<skill-name> palette entries. After the agent build, because
      # Skill::Extension#configure decides there whether the gate is armed.
      @skill_activation.refresh
      @status_rule.interloper = @agent.interloper
      # Seed the status rule with the boot model (resolved from its transport);
      # Shared::StatusRuleLabel#on_event takes over on every later switch.
      @status_rule.current_model = @agent.transport

      @leader_menu = build_leader_menu
      @screen.on_error = method(:on_screen_error)
      @screen.content = Shared::RootLayout.new(@layout, @status_bar)
      # Focus the window, not the inner area: Tuile's Window→content focus
      # cascade re-points onto the input area so the caret lands there.
      @input.focus
      register_shortcuts
    end

    # Runs the Tuile event loop, blocking the calling thread until the user
    # quits or the loop is otherwise stopped. Starts the {WorkspaceSidebar}'s
    # git poll before the loop and stops it in the +ensure+. Does NOT close the
    # screen: the bin owns teardown via +begin/ensure Tuile::Screen.close+
    # around both +App.new+ and this call, so the screen is torn down whether
    # the failure is in construction (an MCP verify / transport probe) or in
    # the loop.
    #
    # @return [void]
    def run
      @sidebar.start_git_watching
      @screen.run_event_loop
    ensure
      @sidebar.stop_git_watching
    end

    private

    # @return [void]
    def build_components
      # Fold the terminal's reported background into the theme before any
      # component below bakes a derived hairline into its text.
      Shared::AppTheme.install(@screen)
      @status_bar = Shared::StatusBar.new
      @log_ui = Shared::Log::UI.new(screen: @screen, status_bar: @status_bar)

      # Per-tool diff formatters for the conversation pane: the edit / write
      # ToolCall renders as a before/after diff (the write side reads the
      # existing file through the same filesystem the Write tool uses) instead
      # of an argument dump, and the paired ToolResult is suppressed on success
      # / surfaced on error.
      @tool_formatters = {
        'edit'  => EditFormatter.new,
        'write' => WriteFormatter.new(filesystem: @filesystem)
      }

      @conversation = Shared::ConversationTextView.new(
        markdown: @markdown, tool_formatters: @tool_formatters
      )
      # The project root was the conversation window's border caption before
      # the frames went away; it reads just as well as the rule's leading
      # segment, and it is the one thing about this shell a glance should
      # answer first.
      @status_rule = Shared::StatusRuleLabel.new(
        token_log: @token_log, names: @model_picker.names,
        context: @filesystem.project_root.to_s
      )

      @session = Shared::AgentSession.new(
        screen: @screen, conversation: @conversation, status_rule: @status_rule,
        model_picker: @model_picker, logger: LOG
      )

      # Precedence: built-in > file command > skill. Match built-ins first or a
      # cloned repo shipping .claude/commands/plan.md captures the /plan that
      # flips a safety gate.
      built_ins = build_slash_commands
      base_commands = built_ins + Shared::FileCommands.build(
        registry: @command_registry, reserved: built_ins.map(&:name),
        screen: @screen, logger: LOG,
        on_expand: ->(text) { @session.submit(text) }
      )
      @slash_menu = Shared::SlashMenuPopup.new(
        screen: @screen, commands: base_commands, conversation: @conversation
      )
      @skill_activation = SkillActivationListener.new(
        skill_extension: @skill_ext, slash_menu: @slash_menu,
        conversation: @conversation, screen: @screen,
        base: base_commands,
        on_load: ->(name, rest) { @skill_ext.schedule_load_skill(name); @session.submit(rest) }
      )
      @input = Shared::InputPane.new(
        on_submit: @session.method(:submit), slash_menu: @slash_menu,
        conversation: @conversation
      )

      # The tasks + git sidebar as one box: it owns its tasks-over-git split,
      # the GitWatcher poll (started/stopped in #run), and the diff popup the
      # leader menu's 'd' entry opens.
      @sidebar = WorkspaceSidebar.new

      @confirmer = TranscriptConfirmer.new(
        screen: @screen, conversation: @conversation,
        status_rule: @status_rule, input: @input
      )
      # ESC on the transcript (where the user answers a confirmation) hands the
      # caret back rather than falling through to the loop's unhandled-key quit.
      @conversation.on_escape = -> { @input.focus }
      @plan_mode_listener = PlanModeListener.new(status_rule: @status_rule, screen: @screen)

      @layout = Layout.new(
        conversation: @conversation,
        status_rule: @status_rule,
        input: @input,
        sidebar: @sidebar
      )
      # The status rule stands in for the sidebar's counts while the column is
      # off screen. Two independent feeds — the panes' data, and whether they
      # are showing — so App holds both halves and re-pushes on either.
      @workspace_digest = nil
      @sidebar_visible = true
      @sidebar.on_digest do |digest|
        @workspace_digest = digest
        refresh_workspace_digest
      end
      @layout.on_sidebar_visibility do |visible|
        @sidebar_visible = visible
        refresh_workspace_digest
      end
    end

    # Build the coding shell's +Pikuri::Agent+: a streaming agent on the boot
    # connection (+@models.first+), the bin-assembled +system_prompt+, and the
    # full coding tool surface. The production factory, called unless the
    # constructor was handed an override block. Wires the conversation listener
    # (rate-limited to 15 fps), {#token_log}, the sidebar {#task_listener},
    # {#status_rule}, and {#plan_mode_listener} into the agent's
    # +ListenerList+ — all reached through App's own objects, so nothing has to
    # be passed in.
    #
    # File/shell tools first (declaration order biases some models toward
    # earlier tools); calculator as auxiliary. Network tools go on the
    # sub-agent-only pool so untrusted web content lands in a child context
    # with no file read/write/bash to hijack (pikuri's SECURITY.md "capability
    # boundaries via sub-agents"). The five file tools come from one
    # +Workspace::Extension+ (a single +Workspace+ composite shared across
    # them, so the read-before-edit gate works); +Bash+ / +git_clone+ come from
    # +Code::Extension+. Both take the shared plan-mode flag so Edit/Write
    # refuse while it's active.
    #
    # == The MCP registry + verify
    #
    # Translates +config.mcp+'s Pikuri-free +McpServer+ value objects into
    # +Registry+ entries here (a wiring layer where +Pikuri::*+ is allowed).
    # Empty by default — an empty registry makes +Mcp::Extension+'s boot-time
    # synthesize/verify LLM calls no-ops, so a no-MCP agent stays offline.
    #
    # @return [Pikuri::Agent] the wired agent.
    def default_build_agent
      listener = @conversation.listener
      task_listener = @sidebar.task_listener

      Pikuri::Extractors::PDF.register

      # The in-transcript confirmer for writes + bash, unless confirmations are
      # disabled (--no-confirm / --yolo), in which case approve everything.
      confirmer = @config.confirm ? @confirmer : Pikuri::Workspace::Confirmer::AUTO_APPROVE

      # Bash auto-gates provably passive commands on top of the human
      # confirmer: the frequent harmless inspections (ls, cat, grep, `cd x &&
      # ls`) stop popping the modal, while every mutation still reaches the y/n
      # popup. The gate is asymmetric — only Code::Extension (Bash) gets a
      # passive_detector; Write/Edit keep the bare confirmer. allow_git tracks
      # the persisted trust grant. Under --no-confirm/--yolo there is nothing
      # to skip, so no detector is built.
      code_passive_detector = @config.confirm ? Pikuri::Code::Bash::PassiveCommandDetector.new(allow_git: @trusted_repo) : nil

      # MCP servers declared in [[code.mcp]]. Empty by default (see the "MCP
      # registry" note above).
      mcp_entries = @config.mcp.map do |m|
        if m.stdio?
          Pikuri::Mcp::Registry::StdioEntry.new(id: m.id, command: m.command, env: m.env)
        else
          Pikuri::Mcp::Registry::HttpEntry.new(id: m.id, url: m.url, headers: m.headers)
        end
      end
      mcp_registry = Pikuri::Mcp::Registry.new(entries: mcp_entries)

      # Coalesce streaming delta chunks at 15 fps before they reach the
      # Markdown-rendering Shared::ConversationTextView (see Chat::App for the
      # rationale). flush_pending_on_non_delta: false because the bookend
      # Assistant / Thinking events re-render the authoritative final content.
      rate_limited_listener = Pikuri::Agent::Listener::RateLimited.new(
        listener, fps: 15, flush_pending_on_non_delta: false
      )

      Pikuri::Agent.new(
        transport: @boot_transport,
        system_prompt: @system_prompt,
        # Default :raise policy, deliberately NOT :synthesize — a coding turn
        # ends in a changed working tree, not an answer. On exhaustion the turn
        # stops; the chat history survives and "continue" just works.
        step_limit: Pikuri::Agent::Control::StepLimit.new(max: 250),
        cancellable: Pikuri::Agent::Control::Cancellable.new,
        interloper: Pikuri::Agent::Control::Interloper.new,
        streaming: true
      ) do |c|
        c.add_listener rate_limited_listener
        c.add_listener @token_log
        # Renders the Pikuri::Tasks::Extension list into the sidebar task pane.
        # Not rate-limited — task mutations are rare and each snapshot is
        # authoritative.
        c.add_listener task_listener
        # Keeps the status rule's model name in step with leader-menu model switches.
        c.add_listener @status_rule
        # Keeps the status rule's plan-mode badge in step with the shared flag
        # (the leader menu's 'p' toggle or the model's enter/exit tools).
        c.add_listener @plan_mode_listener
        # Lists a `paths:`-gated skill's /<name> the moment a touched file
        # brings it into play.
        c.add_listener @skill_activation
        c.add_extension Pikuri::Workspace::Extension.new(filesystem: @filesystem, confirmer: confirmer, read_only: @plan_mode)
        c.add_tool Pikuri::Tool::CALCULATOR
        c.add_sub_agent_tool Pikuri::Tool::WebSearch.build(**@config.search.to_h)
        c.add_sub_agent_tool Pikuri::Tool::WEB_SCRAPE
        c.add_sub_agent_tool Pikuri::Tool::FETCH
        c.add_extension Pikuri::Code::Extension.new(
          filesystem: @filesystem,
          confirmer: confirmer,
          passive_detector: code_passive_detector,
          sandbox: @sandbox,
          read_only: @plan_mode
        )
        c.add_extension @skill_ext
        # Declaration only — commands register no tool and render no prompt, so
        # without this /trifecta would miss their untrusted leg entirely.
        c.add_extension Pikuri::Command::Extension.new(registry: @command_registry)
        c.add_extension Pikuri::Tasks::Extension.new
        c.add_extension Pikuri::Mcp::Extension.new(
          registry: mcp_registry,
          synthesize_descriptions: true,
          verify_mcp_servers: true
        )
        # Privilege-separated read-only sub-agents: FILE_MINER (read/grep/glob)
        # for code/fs lookups, RESEARCHER (web_search/scrape/fetch) for
        # external docs, GIT_REPO_RESEARCHER for cloning + mining other repos.
        c.add_extension Pikuri::SubAgent::Extension.new(
          personas: [
            Pikuri::SubAgent::FILE_MINER,
            Pikuri::SubAgent::RESEARCHER,
            Pikuri::Code::GIT_REPO_RESEARCHER
          ]
        )
      end
    end

    # Wire app-level keyboard shortcuts on the screen. Both bypass the
    # cursor-owner suppression that would otherwise let the focused
    # {Shared::InputPane} swallow them, and both surface a hint in the status bar
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
    # - +Ctrl+C+ runs {#interrupt}. The one direct accelerator kept: it is the
    #   urgent mid-turn interrupt, not a command we want behind a chord. Also
    #   +over_popups: false+: a popup means the user isn't interacting with
    #   the LLM, so Ctrl+C is the popup's business, not ours. The trade-off
    #   is that you can't cancel a running turn while a popup happens to be
    #   open — close it (ESC/q) first.
    #
    # @return [void]
    def register_shortcuts
      @screen.register_global_shortcut(Tuile::Keys::CTRL_C) { interrupt }
      @log_ui.install_shortcut { @leader_menu.open }
    end

    # +Ctrl+C+: decline a parked confirmation if there is one, else run the
    # {Shared::AgentSession#interrupt} escalation (cancel turn -> unfocus ->
    # quit).
    #
    # The decision comes first because a parked tool has the worker blocked, so
    # cancelling the turn alone would look like nothing happened until the
    # decision was answered.
    #
    # @return [void]
    def interrupt
      @session.interrupt unless @confirmer.reject_pending!
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
      menu.add('s', 'sidebar width') { @layout.cycle_sidebar_mode }
      menu.add('p', 'plan mode') { toggle_plan_mode }
      menu.add('v', 'tool line detail') { @conversation.toggle_tool_detail }
      menu.add('m', 'switch model') { @model_picker.open(current: @agent.transport) } if @model_picker.multiple?
      menu.add('c', 'clear conversation + context') { clear_conversation }
      menu.add('q', 'quit') { quit }
      menu
    end

    # The coding shell's built-in slash commands — the {Shared::LeaderMenu}
    # actions reachable by name: +/logs+, +/diff+ (the git-diff popup), +/plan+
    # (toggle), +/model+ (only with more than one connection, like the menu's
    # +m+), +/clear+, and +/exit+ = +/quit+ — plus +/trifecta+, the one with no
    # menu counterpart: a report to read when you wonder, not an action worth a
    # leader key. Its private leg is whatever the bin's startup question
    # recorded ({PrivacyStore}), carried in on +filesystem+.
    #
    # These lead the palette and reserve their names; {SkillActivationListener}
    # appends the +/<skill-name>+ half and re-lists it as the path gate opens.
    #
    # Callbacks are lazy (they resolve +@log_ui+ / +@sidebar+ / +@plan_mode+ /
    # +@session+ / +@agent+ / +quit+ at run time), so this is safe to build
    # before the agent/sidebar; only the +/model+ *presence* is decided now,
    # from {Shared::Model::Picker#multiple?}.
    #
    # @return [Array<Shared::SlashCommand>]
    def build_slash_commands
      quit_action = ->(_rest) { quit; nil }
      commands = [
        Shared::SlashCommand.new('/logs', 'open the diagnostic log', ->(_rest) { @log_ui.open; 'Opened the diagnostic log.' }),
        Shared::SlashCommand.new('/trifecta', 'lethal-trifecta report for this agent',
                                 ->(_rest) { Shared::TrifectaRenderer.render(@agent.trifecta, theme: @screen.theme) }),
        Shared::SlashCommand.new('/diff', 'show the git diff', ->(_rest) { @sidebar.open_diff; 'Opened the git diff.' }),
        Shared::SlashCommand.new('/sidebar', 'sidebar full / narrow / off (blank cycles)', ->(rest) { set_sidebar(rest) }),
        Shared::SlashCommand.new('/plan', 'toggle plan mode', ->(_rest) { toggle_plan_mode; @plan_mode.active? ? 'Plan mode on.' : 'Plan mode off.' }),
        Shared::SlashCommand.new('/tools', 'tool lines short / verbose (blank toggles)',
                                 ->(rest) { @conversation.select_tool_detail(rest) })
      ]
      if @model_picker.multiple?
        commands << Shared::SlashCommand.new('/model', 'switch model', ->(_rest) { @model_picker.open(current: @agent.transport); nil })
      end
      commands.push(
        Shared::SlashCommand.new('/clear', 'clear conversation + context', ->(_rest) { clear_conversation; nil }),
        Shared::SlashCommand.new('/exit', 'quits the app', quit_action),
        Shared::SlashCommand.new('/quit', 'quits the app', quit_action)
      )
    end

    # Clear the conversation, then re-list the palette — the clear re-hides
    # every +paths:+-gated skill, so their +/<name>+ entries have to go with it.
    #
    # @return [void]
    def clear_conversation
      @session.clear_conversation
      @skill_activation.refresh
    end

    # Stop the event loop, unwinding {#run} back to the bin's +ensure+ (which
    # calls +Screen#close+). The leader menu's +q+ action — a hard quit,
    # distinct from {Shared::AgentSession#interrupt}'s escalation (no
    # turn-cancel / unfocus steps). Runs on the event-loop thread (deferred by
    # {Shared::LeaderMenu}), so +stop+ is safe to call.
    #
    # @return [void]
    def quit
      # Decline anything parked first: a tool blocked on an answer would
      # otherwise be abandoned mid-operation rather than told no.
      @confirmer.reject_pending!
      @screen.event_queue.stop
    end

    # Flip the shared {Pikuri::Workspace::ReadOnly} plan-mode flag —
    # enter if off, exit if on. Runs on the UI thread (global-shortcut
    # dispatch); the flag is thread-safe, and the status-rule badge updates
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

    # Pushes the sidebar's counts into the status rule, or clears them: the rule
    # is a stand-in, so it carries them only while the column itself is not.
    #
    # @return [void]
    def refresh_workspace_digest
      @status_rule.workspace_digest = @sidebar_visible ? nil : @workspace_digest
    end

    # Applies a +/sidebar+ argument, or cycles when it is blank. Unlike the
    # leader menu's +s+, which lets the re-split speak for itself, this echoes —
    # a typed command that answered nothing reads as a command that did nothing.
    #
    # @param rest [String] the rest of the typed line: a {SIDEBAR_ARGUMENTS}
    #   key, or blank to cycle.
    # @return [String] the outcome to echo under the command.
    def set_sidebar(rest)
      argument = rest.strip.downcase
      return "Sidebar: #{@layout.cycle_sidebar_mode}." if argument.empty?

      mode = SIDEBAR_ARGUMENTS[argument]
      return "No sidebar mode #{argument.inspect} — try #{SIDEBAR_ARGUMENTS.keys.join(' / ')}." unless mode

      @layout.sidebar_mode = mode
      "Sidebar: #{mode}."
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
