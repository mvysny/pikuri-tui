# frozen_string_literal: true

require 'logger'
require 'pikuri-core'
require 'pikuri-conversations'
require 'pikuri-web'
require 'tuile'

module Code
  # The Tuile shell behind +bin/pikuri-tui-code+: the borderless conversation
  # pane, the status rule, the tinted full-width prompt, the tasks + git sidebar
  # ({WorkspaceSidebar}), the eager diagnostic {Shared::Log::Dialog} (popup-visible via
  # the {Shared::LeaderMenu}'s +l+ entry), the +Ctrl+K+ menu / +Ctrl+C+ cancel
  # status-bar hints, and the agent on one +Pikuri::Conversations+
  # conversation.
  #
  # A parallel copy of {Chat::App} (see {Code} for the duplicate-don't-share
  # rationale), plus the coding-shell surface: a {TranscriptConfirmer} gating
  # +write+ / +bash+, the {WorkspaceSidebar} (tasks + git changes + diff
  # popup), plan mode (a status-rule badge via {PlanModeListener} + a leader-menu
  # +p+ toggle), and +edit+ / +write+ diffs.
  #
  # == Construction: App owns the conversation
  #
  # App opens its own conversation (see {#configure_agent}) from the
  # {Shared::Config} handed to it plus the pre-built workspace objects the bin
  # assembles — see "What the bin still owns" below. The bin's job ends at CLI
  # + config + workspace/sandbox/trust + screen; the agent, its tools, and its
  # listeners are the shell's identity and live here.
  #
  # The optional +transport:+ is a **test seam**, not production ceremony: a
  # spec passes a +Pikuri::Testing.fake_transport+ so App builds its *real*
  # agent — the real {#configure_agent} tool/extension wiring and listeners —
  # on a scripted-HTTP backend, skipping the network / RubyLLM cost.
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
  # registry) plus the agent graph, rebuilt for every agent.
  #
  # == Screen ownership
  #
  # App assumes a {Tuile::Screen} (or {Tuile::FakeScreen}) is already
  # installed as the singleton — the bin calls +Tuile::Screen.new+ before
  # constructing App; tests call +Tuile::Screen.fake+.
  #
  # == Threading
  #
  # Per AGENTS.md's threading invariant, Tuile is single-threaded and the agent loop must not run on
  # the UI thread. App runs {Tuile::Screen#run_event_loop} on the caller's
  # thread; the conversation ({#session}) builds the agent and runs each turn
  # on threads of its own, and every call into it returns at once. Enter
  # routes to +session.submit+, Ctrl+C to {#interrupt}, leader +c+ to
  # {#clear_conversation}. The {TranscriptConfirmer} bridges the other
  # way: a tool on the turn thread calls +ask+, which submits the
  # question to the UI thread and parks the worker until the user answers (see
  # its docs).
  #
  # UI-thread-confined.
  class App
    # @return [Logger]
    LOG = Pikuri.logger_for('code')
    private_constant :LOG

    # Seconds {#close} waits for the agent to unwind a cancelled turn.
    #
    # @return [Integer]
    CLOSE_TIMEOUT_S = 5
    private_constant :CLOSE_TIMEOUT_S

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
    #   provider keys, and the MCP registry {#configure_agent} wires.
    attr_reader :config

    # @return [Pikuri::Conversations::Conversation] the one conversation this
    #   shell runs; Enter, Ctrl+C, the model picker and leader +c+ drive it.
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
    #   the {WorkspaceSidebar}'s task pane), in the conversation's listener.
    def task_listener = @sidebar.task_listener

    # @return [WorkspaceSidebar] the tasks + git sidebar; owns the
    #   {GitWatcher} (started/stopped in {#run}) and the diff dialog the
    #   leader menu's +d+ entry opens. Exposed for tests.
    attr_reader :sidebar

    # @return [Shared::Log::Dialog] the eager-constructed
    #   diagnostic log (owned by the {Shared::Log::UI}).
    def log_dialog = @log_ui.log_dialog

    # @return [Shared::StatusRuleLabel] the status rule; it follows the
    #   conversation as a listener.
    attr_reader :status_rule

    # @return [PlanModeListener] the status rule's plan-mode-badge listener,
    #   in the conversation's listener so +Pikuri::Code::PlanModeChanged+
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
    #   roots the bin already folded into +filesystem.readable+; wired into
    #   every agent's +Skill+ extension.
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
    #   HTTP. See the class header.
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
      # One flag for the process, outliving every agent a /clear builds: the
      # leader menu's +p+ toggle and the model's enter/exit tools flip it.
      @plan_mode = Pikuri::Code::PlanMode.new
      @models = config.llms.map { |llm| Shared::Model::Choice.from_llm(llm) }
      Shared::RequestPermits.install(config.servers)
      Pikuri::Extractors::PDF.register
      @model_picker = Shared::Model::Picker.new(models: @models)
      @mcp_registry = build_mcp_registry
      @mcp_catalog = nil

      build_components
      @log_ui.wire!
      # Seeds the /<skill-name> palette entries; each agent's extension re-lists them.
      @skill_activation.refresh
      @session = open_session(transport || @models.first.transport)
      # Shared::StatusRuleLabel#on_event takes over on every later switch.
      @status_rule.current_model = @session.status.model

      @leader_menu = build_leader_menu
      @screen.on_error << method(:on_screen_error)
      @screen.content = Shared::RootLayout.new(@layout, @status_bar)
      @input.focus
      register_shortcuts
    end

    # Runs the Tuile event loop, blocking the calling thread until the user
    # quits or the loop is otherwise stopped, then {#close}s the conversation.
    # Starts the {WorkspaceSidebar}'s git poll before the loop and stops it in
    # the +ensure+. Does NOT close the screen: the bin owns teardown via
    # +begin/ensure Tuile::Screen.close+ around both +App.new+ and this call.
    #
    # @return [void]
    def run
      @sidebar.start_git_watching
      @screen.run_event_loop
    ensure
      @sidebar.stop_git_watching
      close
    end

    # Close the conversation, cancelling a running turn — a question parked on
    # the human included: every way out of the event loop ends here, so a tool
    # blocked on an answer is unwound rather than abandoned mid-operation — then
    # wait a moment for its agent (and the MCP servers it started) to be released.
    # Idempotent.
    #
    # @return [void]
    def close
      @conversations.shutdown(timeout: CLOSE_TIMEOUT_S)
      nil
    end

    private

    # @return [void]
    def build_components
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
        markdown: @markdown, show_thinking: @config.show_thinking,
        tool_detail: @config.tool_lines, tool_formatters: @tool_formatters
      )
      # The project root was the conversation window's border caption before
      # the frames went away; it reads just as well as the rule's leading
      # segment, and it is the one thing about this shell a glance should
      # answer first.
      @status_rule = Shared::StatusRuleLabel.new(
        names: @model_picker.names, context: @filesystem.project_root.to_s
      )

      # Precedence: built-in > file command > skill. Match built-ins first or a
      # cloned repo shipping .claude/commands/plan.md captures the /plan that
      # flips a safety gate.
      built_ins = build_slash_commands
      base_commands = built_ins + Shared::FileCommands.build(
        registry: @command_registry, reserved: built_ins.map(&:name),
        screen: @screen, logger: LOG,
        on_expand: ->(text) { submit(text) }
      )
      @slash_menu = Shared::SlashMenuPopup.new(
        screen: @screen, commands: base_commands, conversation: @conversation
      )
      @skill_activation = SkillActivationListener.new(
        catalog: @skill_catalog, slash_menu: @slash_menu,
        conversation: @conversation, screen: @screen,
        base: base_commands,
        on_load: method(:load_skill)
      )
      @input = Shared::InputPane.new(
        on_submit: method(:submit), slash_menu: @slash_menu,
        conversation: @conversation, attachment_refusal: method(:attachment_refusal)
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
      @ui_toggles = Shared::UIToggleMenu.new(screen: @screen, conversation: @conversation)
      @conversation.on_escape { @input.focus }
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

    # Open the shell's one conversation on +transport+, which boots its agent
    # on a thread of its own: the bin-assembled system prompt, the coding tool
    # surface {#configure_agent} adds, and the panes' listeners — the transcript
    # rate-limited to 15 fps (see {Chat::App} for why), the status rule, the
    # sidebar's task pane, the plan-mode badge and the skill palette.
    #
    # @param transport [Pikuri::Agent::ChatTransport] the model it starts on.
    # @return [Pikuri::Conversations::Conversation]
    def open_session(transport)
      @conversations = Pikuri::Conversations.new(system_prompt: @system_prompt, configure: method(:configure_agent))
      transcript = Pikuri::Conversations::RateLimitedListener.new(@conversation.listener, fps: 15)
      listener = Pikuri::Agent::ListenerList.new([transcript, @status_rule, @sidebar.task_listener,
                                                  @plan_mode_listener, @skill_activation])
      @conversations.open(id: 'code', transport: transport, listener: listener)
    end

    # The coding tool surface, built fresh for each agent — at boot and after
    # every clear — on the boot thread.
    #
    # File/shell tools first (declaration order biases some models toward
    # earlier tools); calculator as auxiliary. Network tools go on the
    # sub-agent-only pool so untrusted web content lands in a child context
    # with no file read/write/bash to hijack (pikuri's SECURITY.md "capability
    # boundaries via sub-agents"). The five file tools come from one
    # +Workspace::Extension+ (a single +Workspace+ composite shared across
    # them, so the read-before-edit gate works), over the plan-mode guard so
    # Edit/Write refuse while it's on; +Bash+ and the plan-mode tools come from
    # +Code::Extension+, over the raw filesystem.
    #
    # @param configurator [Pikuri::Agent::Configurator]
    # @param _conversation [Pikuri::Conversations::Conversation]
    # @return [void]
    def configure_agent(configurator, _conversation)
      # The in-transcript confirmer for writes + bash, unless confirmations are
      # disabled (--no-confirm / --yolo), in which case approve everything.
      confirmer = @config.confirm ? @confirmer : Pikuri::Workspace::Confirmer::AUTO_APPROVE

      # Bash auto-gates provably passive commands on top of the human
      # confirmer: the frequent harmless inspections (ls, cat, grep, `cd x &&
      # ls`) stop popping the question, while every mutation still reaches it.
      # The gate is asymmetric — only Code::Extension (Bash) gets a
      # passive_detector; Write/Edit keep the bare confirmer. allow_git tracks
      # the persisted trust grant. Under --no-confirm/--yolo there is nothing
      # to skip, so no detector is built.
      passive_detector =
        @config.confirm ? Pikuri::Code::Bash::PassiveCommandDetector.new(allow_git: @trusted_repo) : nil

      configurator.add_extension Pikuri::Workspace::Extension.new(filesystem: @plan_mode.guard(@filesystem),
                                                                  confirmer: confirmer)
      configurator.add_tool Pikuri::Tool::CALCULATOR
      configurator.add_sub_agent_tool Pikuri::Web::Search.build(**@config.search.to_h)
      configurator.add_sub_agent_tool Pikuri::Web::SCRAPE
      configurator.add_sub_agent_tool Pikuri::Web::FETCH
      configurator.add_extension Pikuri::Code::Extension.new(
        filesystem: @filesystem,
        confirmer: confirmer,
        passive_detector: passive_detector,
        sandbox: @sandbox,
        plan_mode: @plan_mode
      )
      # +root:+ is what a `paths:` skill's globs are matched against.
      skills = Pikuri::Skill::Extension.new(catalog: @skill_catalog, root: project_root)
      configurator.add_extension skills
      @skill_activation.extension = skills
      # Declaration only — commands register no tool and render no prompt, so
      # without this /trifecta would miss their untrusted leg entirely.
      configurator.add_extension Pikuri::Command::Extension.new(registry: @command_registry)
      configurator.add_extension Pikuri::Tasks::Extension.new
      configurator.add_extension Pikuri::Mcp::Extension.new(catalog: mcp_catalog(configurator.agent))
      # Privilege-separated read-only sub-agents: FILE_MINER (read/grep/glob)
      # for code/fs lookups, RESEARCHER (web_search/scrape/fetch) for
      # external docs.
      configurator.add_extension Pikuri::SubAgent::Extension.new(
        personas: [Pikuri::SubAgent::FILE_MINER, Pikuri::SubAgent::RESEARCHER]
      )
      # Not a persona: its child clones into a throwaway folder of its own and
      # never sees this project. Must follow the web tools it hands the child.
      configurator.add_extension Pikuri::Code::GitRepoResearcher.new
    end

    # The +[[code.mcp]]+ servers, translated from the config's Pikuri-free
    # +McpServer+ value objects (a wiring layer, where +Pikuri::*+ is allowed).
    #
    # @return [Pikuri::Mcp::Registry]
    def build_mcp_registry
      Pikuri::Mcp::Registry.new(entries: @config.mcp.map do |m|
        if m.stdio?
          Pikuri::Mcp::Registry::StdioEntry.new(id: m.id, command: m.command, env: m.env)
        else
          Pikuri::Mcp::Registry::HttpEntry.new(id: m.id, url: m.url, headers: m.headers)
        end
      end)
    end

    # The verified MCP servers, built on the first agent's boot thread and kept
    # for every agent after: building one spawns each server and asks the
    # model to describe and vet it, which a /clear should not repeat. An empty
    # registry makes this a no-op, so a no-MCP shell stays offline. Only ever
    # called from the one boot thread a conversation runs at a time.
    #
    # @param agent [Pikuri::Agent] the agent being built, whose model, cancel
    #   token and throttle the build's own requests use — so Ctrl+C aborts it.
    # @return [Pikuri::Mcp::Catalog]
    # @raise [Pikuri::Mcp::Verifier::InjectionDetected] when a server is flagged;
    #   the boot fails, and the next message tries again.
    def mcp_catalog(agent)
      @mcp_catalog ||= Pikuri::Mcp::Catalog.build(
        @mcp_registry, transport: agent.transport, cancellable: agent.cancellable,
                       around_request: agent.around_request
      )
    end

    # A +/<skill-name>+ from the palette: the skill's body, then +rest+ as the
    # message — a bare load when +rest+ is blank. Once an agent runs, the
    # skill goes in through its extension and lands ahead of the message in one
    # turn; before that (booting, or after a /clear) the conversation carries
    # both, in order, for the agent to come.
    #
    # @param name [String] a skill the palette listed, so in play.
    # @param rest [String] the rest of the typed line.
    # @return [void]
    def load_skill(name, rest)
      extension = @skill_activation.extension
      if extension && %i[idle running].include?(@session.status.state)
        extension.schedule_load_skill(name)
        submit(rest)
      else
        submit(rest, system: [Pikuri::Skill::Renderer.format_skill(@skill_catalog.get(name), by_user: true)])
      end
    end

    # Enter on the prompt: start a turn, or join the running one. A model known
    # to refuse the images gets nothing, and the line comes back for a fix.
    #
    # @param text [String] the line, +@path+ tokens split out.
    # @param attachments [Array<Pikuri::Attachment>] the images it named.
    # @param system [Array<String>] reference blocks — a skill the user loaded —
    #   delivered ahead of +text+.
    # @return [void]
    def submit(text, attachments: [], system: [])
      @session.submit(text, attachments: attachments, system: system)
    rescue Pikuri::Agent::UnsupportedAttachmentError => e
      @input.refuse_attachment(e.message)
    end

    # Why the next turn's model can't see +attachments+, asked before anything
    # is sent; +nil+ when they may go out, unknown modalities included.
    #
    #   attachment_refusal([png])   # => "shot.png (image/png): model m takes no vision input"
    #
    # @param attachments [Array<Pikuri::Attachment>]
    # @return [String, nil] the reason, worded as +run_loop+'s own refusal.
    def attachment_refusal(attachments)
      image = attachments.find { |a| a.mime.start_with?('image/') }
      transport = @session.status.next_model
      return nil unless image && transport.modalities&.[](:vision) == false

      Pikuri::Agent::UnsupportedAttachmentError.new(image, "model #{transport.model} takes no vision input").message
    end

    # @return [String] the +/trifecta+ answer: the report, or a note while the
    #   agent it describes is still being built.
    def trifecta_report
      report = @session.trifecta
      return 'The agent is still starting — ask again in a moment.' if report.nil?

      Shared::TrifectaRenderer.render(report, theme: @screen.theme)
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
    # - +Ctrl+K+ opens the {Shared::LeaderMenu} command popup. +over_modal: false+
    #   (the default), so it can't stack over an open popup. The {Shared::Log::UI} owns
    #   this binding because its hint also carries the unread-error tally —
    #   the only always-visible status-bar surface.
    # - +Ctrl+C+ runs {#interrupt}. The one direct accelerator kept: it is the
    #   urgent mid-turn interrupt, not a command we want behind a chord. Also
    #   +over_modal: false+: a popup means the user isn't interacting with
    #   the LLM, so Ctrl+C is the popup's business, not ours. The trade-off
    #   is that you can't cancel a running turn while a popup happens to be
    #   open — close it (ESC/q) first.
    #
    # @return [void]
    def register_shortcuts
      @screen.register_global_shortcut(Tuile::Keys::CTRL_C) { interrupt }
      @log_ui.install_shortcut { @leader_menu.open }
    end

    # +Ctrl+C+, three states in priority order: a running turn (or boot) is
    # cancelled; else a focused pane drops focus, as ESC does; else the event
    # loop stops, which quits. A parked confirmation means a turn is running, so
    # the step taken is then always the cancel, which ends the question too.
    #
    # @return [void]
    def interrupt
      return if @session.cancel == :cancelled

      if @screen.focused
        @screen.focused = nil
      else
        @screen.event_queue.stop
      end
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
      menu.add('u', 'UI toggles') { @ui_toggles.open }
      menu.add('m', 'switch model') { @model_picker.open(session: @session) } if @model_picker.multiple?
      menu.add('c', 'clear conversation + context') { clear_conversation }
      menu.add('q', 'quit') { quit }
      menu
    end

    # The coding shell's built-in slash commands — the {Shared::LeaderMenu}
    # actions reachable by name: +/logs+, +/diff+ (the git-diff popup), +/plan+
    # (toggle), +/model+ (only with more than one connection, like the menu's
    # +m+), +/clear+, and +/exit+ = +/quit+ — plus +/trifecta+, which has no
    # menu counterpart: a report to read when you wonder, not an action worth a
    # leader key. Its private leg is whatever the bin's startup question
    # recorded ({PrivacyStore}), carried in on +filesystem+. +/image <path>+ has
    # none either: it fills the prompt ({Shared::InputPane#attach}) rather than
    # acting.
    #
    # These lead the palette and reserve their names; {SkillActivationListener}
    # appends the +/<skill-name>+ half and re-lists it as the path gate opens.
    #
    # Callbacks are lazy (they resolve +@log_ui+ / +@sidebar+ / +@plan_mode+ /
    # +@session+ / +quit+ at run time), so this is safe to build before the
    # conversation/sidebar; only the +/model+ *presence* is decided now,
    # from {Shared::Model::Picker#multiple?}.
    #
    # @return [Array<Shared::SlashCommand>]
    def build_slash_commands
      quit_action = ->(_rest) { quit; nil }
      commands = [
        Shared::SlashCommand.new('/logs', 'open the diagnostic log',
                                 ->(_rest) { @log_ui.open; 'Opened the diagnostic log.' }),
        Shared::SlashCommand.new('/trifecta', 'lethal-trifecta report for this agent',
                                 ->(_rest) { trifecta_report }),
        Shared::SlashCommand.new('/diff', 'show the git diff',
                                 ->(_rest) { @sidebar.open_diff; 'Opened the git diff.' }),
        Shared::SlashCommand.new('/sidebar', 'sidebar full / narrow / off (blank cycles)',
                                 ->(rest) { select_sidebar(rest) }),
        Shared::SlashCommand.new('/plan', 'toggle plan mode',
                                 ->(_rest) { toggle_plan_mode; "Plan mode #{@plan_mode.active? ? 'on' : 'off'}." }),
        Shared::SlashCommand.new('/thinking', 'show / hide reasoning (blank toggles)',
                                 ->(rest) { @conversation.select_thinking(rest) }),
        Shared::SlashCommand.new('/tools', 'tool lines short / verbose (blank toggles)',
                                 ->(rest) { @conversation.select_tool_detail(rest) }),
        Shared::SlashCommand.new('/image', 'attach an image: /image <path>',
                                 ->(rest) { @input.attach(rest); nil })
      ]
      if @model_picker.multiple?
        commands << Shared::SlashCommand.new('/model', 'switch model',
                                             ->(_rest) { @model_picker.open(session: @session); nil })
      end
      commands.push(
        Shared::SlashCommand.new('/clear', 'clear conversation + context', ->(_rest) { clear_conversation; nil }),
        Shared::SlashCommand.new('/exit', 'quits the app', quit_action),
        Shared::SlashCommand.new('/quit', 'quits the app', quit_action)
      )
    end

    # Start over on a fresh agent — the transcript and the task pane wipe as
    # it boots, and its new skill extension re-hides every +paths:+-gated
    # skill's palette entry. Refused while a turn runs, which is what Ctrl+C is
    # for.
    #
    # @return [void]
    def clear_conversation
      LOG.warn('clear conversation ignored: a turn is in progress') if @session.clear == :busy
    end

    # Stop the event loop, unwinding {#run} into {#close} — which cancels a
    # parked question and the turn — and back to the bin's +ensure+ (which
    # calls +Screen#close+). The leader menu's +q+ action — a hard quit,
    # distinct from {#interrupt}'s escalation (no unfocus step). Runs on the
    # event-loop thread (deferred by {Shared::LeaderMenu}), so +stop+ is safe to
    # call.
    #
    # @return [void]
    def quit
      @screen.event_queue.stop
    end

    # Flip the shared {Pikuri::Code::PlanMode} flag — enter if off, exit if
    # on. The status-rule badge updates through {PlanModeListener} off the
    # +PlanModeChanged+ event the flip emits, so the model-flip path renders
    # the same way.
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
    def select_sidebar(rest)
      argument = rest.strip.downcase
      return "Sidebar: #{@layout.cycle_sidebar_mode}." if argument.empty?

      mode = SIDEBAR_ARGUMENTS[argument]
      return "No sidebar mode #{argument.inspect} — try #{SIDEBAR_ARGUMENTS.keys.join(' / ')}." unless mode

      @layout.sidebar_mode = mode
      "Sidebar: #{mode}."
    end

    # @param event [Tuile::EventQueue::ErrorEvent] the uncaught exception, in
    #   the event the empty-means-re-raise slot hands its listeners.
    # @return [void]
    def on_screen_error(event)
      exception = event.error
      LOG.error(
        "#{exception.class}: #{exception.message}\n#{(exception.backtrace || []).join("\n")}"
      )
    end
  end
end
