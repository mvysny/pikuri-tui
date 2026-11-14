# frozen_string_literal: true

require 'logger'
require 'pikuri-core'
require 'pikuri-conversations'
require 'pikuri-web'
require 'tuile'

module Computer
  # The Tuile shell behind +bin/pikuri-tui-computer+: the borderless
  # conversation pane, the status rule, the tinted prompt, the eager diagnostic {Shared::Log::Dialog}
  # (popup-visible via the {Shared::LeaderMenu}'s +l+ entry), the +Ctrl+K+
  # menu / +Ctrl+C+ cancel status-bar hints, and the agent on one
  # +Pikuri::Conversations+ conversation.
  #
  # Laid out like {Chat::App} — one conversation pane over an input strip,
  # NO sidebar — but it carries the coding shell's safety machinery because
  # the agent's file/bash tools mutate the real host: a
  # {Code::TranscriptConfirmer} gates +write+ / +bash+, plan mode surfaces as a status-rule badge
  # ({Code::PlanModeListener} + a leader-menu +p+ toggle), and +edit+ / +write+
  # render as diffs. It reuses the +Code::*+ adapters directly rather than
  # re-copying them (see {Computer} for the duplicate-only-the-shell
  # rationale).
  #
  # == Construction: App owns the conversation
  #
  # App opens its own conversation from the {Shared::Config} handed to it —
  # the OS-assistant prompt (with a network-posture block keyed to
  # +internet_enabled+), the boot connection (+config.llms+'s first entry), a
  # whole-host {Pikuri::Os::Extension} (five file tools + a network-severed
  # sandboxed bash), local mail + calendar via
  # {Pikuri::Thunderbird::Extension}, and — unless +internet_enabled+ is false
  # — a quarantined web RESEARCHER sub-agent (see {#configure_agent}). The
  # bin only parses CLI + config, probes the Thunderbird profile, and mounts
  # the screen.
  #
  # The optional +transport:+ is a **test seam**, not production ceremony: a
  # spec passes a +Pikuri::Testing.fake_transport+ so App builds its *real*
  # agent — the real {#configure_agent} tool/extension wiring and listeners —
  # on a scripted-HTTP backend instead of a live server. The host probes the
  # extensions make are steered through +profile_dir:+ and +config.sandbox+,
  # which production sets anyway.
  #
  # == The bwrap probe runs here, on the production path
  #
  # The constructor builds the +FullFsNoNet+ sandbox, whose constructor
  # probes +bwrap+ + user/net namespaces and raises if they're unavailable —
  # here rather than with the agent, which boots on a thread of its own and
  # would turn the raise into a line in the transcript. That raise happens
  # during +App.new+ — but +Tuile::Screen.new+ has not yet
  # entered raw mode / the alternate buffer (that is +run_event_loop+'s job),
  # so the backtrace still reaches a normal terminal. The bin wraps
  # +App.new+/+run+ in +begin/ensure Tuile::Screen.close+ to tear the screen
  # down on any escape — which is why {#run} does NOT close the screen itself.
  # Tests never hit the probe: they boot with +config.sandbox+ false.
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
  # {#clear_conversation}. The {Code::TranscriptConfirmer} bridges the
  # other way: a tool on the turn thread calls +ask+, which submits the
  # question to the UI thread and parks the worker until the user answers (see
  # its docs).
  #
  # UI-thread-confined.
  class App
    # @return [Logger]
    LOG = Pikuri.logger_for('computer')
    private_constant :LOG

    # Seconds {#close} waits for the agent to unwind a cancelled turn.
    #
    # @return [Integer]
    CLOSE_TIMEOUT_S = 5
    private_constant :CLOSE_TIMEOUT_S

    # @return [Tuile::Screen] the (already-installed) screen this app
    #   runs on.
    attr_reader :screen

    # The shell's pane layout — not the screen's content component, which is
    # the {Shared::RootLayout} stacking this over {#status_bar}.
    #
    # @return [Computer::Layout]
    attr_reader :layout

    # @return [Shared::StatusBar] the bottom row.
    attr_reader :status_bar

    # @return [Shared::Config] the resolved configuration the bin loaded;
    #   drives the model list, the boot connection, the sandbox/confirm
    #   posture, and the web-search provider keys {#configure_agent} reads.
    attr_reader :config

    # @return [Pikuri::Conversations::Conversation] the one conversation this
    #   shell runs; Enter, Ctrl+C, the model picker and leader +c+ drive it.
    attr_reader :session

    # @return [Tuile::Component::TextView] the conversation transcript
    #   pane. Exposed primarily for tests; production code should reach
    #   it through the {Shared::ConversationTextView::Listener}.
    attr_reader :conversation

    # @return [Pathname] the whole-host workspace anchor — the filesystem's
    #   normalized project root (relative-path base + bash chdir target). The
    #   single source of truth for where this shell is rooted; the bin logs it
    #   as "Working from …" rather than re-deriving +Dir.pwd+.
    def project_root = @filesystem.project_root

    # @return [Shared::Log::Dialog] the eager-constructed
    #   diagnostic log (owned by the {Shared::Log::UI}).
    def log_dialog = @log_ui.log_dialog

    # @return [Shared::StatusRuleLabel] the status rule; it follows the
    #   conversation as a listener.
    attr_reader :status_rule

    # @return [Code::PlanModeListener] the status rule's plan-mode-badge listener,
    #   in the conversation's listener so +Pikuri::Code::PlanModeChanged+
    #   events reach the status rule. Dormant until a plan-mode transition fires
    #   (via {#toggle_plan_mode} or the model's enter/exit tools).
    attr_reader :plan_mode_listener

    # @return [Code::TranscriptConfirmer] the in-transcript confirmer wired into the
    #   +write+ / +bash+ tools; exposed for tests and for callers that want to
    #   inspect how those tools were gated.
    attr_reader :confirmer

    # @return [Pikuri::Command::Registry] the on-disk slash commands this shell
    #   scanned, refused ones included.
    attr_reader :command_registry

    # @param config [Shared::Config] the resolved configuration; App derives
    #   the model list (one {Shared::Model::Choice} per +config.llms+ entry,
    #   the first the boot connection), reads the sandbox/confirm posture, and
    #   reads the web-search provider keys when building an agent.
    # @param internet_enabled [Boolean] whether to wire the quarantined web
    #   RESEARCHER sub-agent (the +--no-internet+ flag forces +false+). Also
    #   selects the online/offline network-posture prompt block. Mail +
    #   calendar work regardless. Default +true+.
    # @param profile_dir [String, nil] the Thunderbird profile directory
    #   forwarded to {Pikuri::Thunderbird::Extension} (the bin has already
    #   probed it); +nil+ auto-discovers. Default +nil+.
    # @param project_root [Pathname, String] the whole-host workspace anchor
    #   (relative-path base + bash chdir target), shown in the conversation
    #   window title. Default +Dir.pwd+ (the launch dir; the computer shell
    #   never chdirs).
    # @param markdown [Boolean] forwarded to {Shared::ConversationTextView}'s
    #   +markdown:+ flag (default +true+).
    # @param command_registry [Pikuri::Command::Registry] the on-disk slash
    #   commands, one palette entry each. Defaults to a scan of the launch dir
    #   and +$HOME+ — this shell has no containment to reason from, so neither
    #   base is vouched for and +/trifecta+ grades them accordingly. A spec
    #   passes an empty registry to keep the palette off the host's real
    #   +~/.claude/commands+.
    # @param transport [Pikuri::Agent::ChatTransport, nil] test seam: the
    #   backend to build the real agent on. Omit in production (boots on the
    #   config's first connection); a spec passes a
    #   +Pikuri::Testing.fake_transport+ to run real turns against scripted
    #   HTTP. See the class header.
    def initialize(config:, internet_enabled: true, profile_dir: nil, project_root: Dir.pwd, markdown: true,
                   command_registry: Pikuri::Command::Registry.new(search_bases: [Dir.pwd, Dir.home]),
                   transport: nil)
      @screen = Tuile::Screen.instance
      @config = config
      @internet_enabled = internet_enabled
      @profile_dir = profile_dir
      @project_root = project_root
      @markdown = markdown
      @command_registry = command_registry
      # The shared plan-mode (read-only) flag: the leader menu's +p+ toggle
      # and the model's enter/exit tools flip this one instance (threaded into
      # every agent's Pikuri::Os::Extension by configure_agent). The
      # message: is the plan-mode-specific refusal wording Edit/Write splice
      # into their "cannot write …" observation.
      @plan_mode = Pikuri::Workspace::ReadOnly.new(
        message: Pikuri::Code::Extension::PLAN_MODE_READONLY_MESSAGE
      )
      @models = config.llms.map { |llm| Shared::Model::Choice.from_llm(llm) }
      Shared::RequestPermits.install(config.servers)
      Pikuri::Extractors::PDF.register
      @model_picker = Shared::Model::Picker.new(models: @models)

      build_components
      @sandbox = build_sandbox
      @log_ui.wire!
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
    # Does NOT close the screen: the bin owns teardown via +begin/ensure
    # Tuile::Screen.close+ around both +App.new+ and this call, so the screen is
    # torn down whether the failure is in construction (the +FullFsNoNet+ bwrap
    # probe) or in the loop. See the "bwrap probe" note in the class docs.
    #
    # @return [void]
    def run
      @screen.run_event_loop
    ensure
      close
    end

    # Close the conversation, cancelling a running turn — a question parked on
    # the human included: every way out of the event loop ends here, so a tool
    # blocked on an answer is unwound rather than abandoned mid-operation — then
    # wait a moment for its agent to be released. Idempotent.
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

      # The whole host is in scope (that's the point). denylist: [] drops the
      # credential floor for the file tools too, so Read/Write/Edit see exactly
      # what bash already sees under FullFsNoNet — a half-denylist bash bypasses
      # via an auto-approved `cat` would be security theater. Safe because
      # egress is human-gated, not open (bash is kernel-severed, each research
      # task is approved, every mail/event is a Send/confirm in Thunderbird).
      @filesystem = Pikuri::Workspace::Filesystem::AllowAll.new(project_root: @project_root, denylist: [])

      # Per-tool diff formatters for the conversation pane: edit / write render
      # as a before/after diff (write reads the existing file through the same
      # filesystem the Write tool uses) instead of an argument dump. Reused
      # verbatim from the coding shell.
      @tool_formatters = {
        'edit'  => Code::EditFormatter.new,
        'write' => Code::WriteFormatter.new(filesystem: @filesystem)
      }

      @conversation = Shared::ConversationTextView.new(
        markdown: @markdown, show_thinking: @config.show_thinking,
        tool_detail: @config.tool_lines, tool_formatters: @tool_formatters
      )
      # The filesystem root was the conversation window's border caption before
      # the frames went away; the rule's leading segment reads it just as well.
      @status_rule = Shared::StatusRuleLabel.new(
        names: @model_picker.names, context: "Computer — #{@filesystem.project_root}"
      )

      # Precedence: built-in > file command. Match built-ins first or a command
      # file shipped anywhere under $HOME captures the /plan that flips a
      # safety gate.
      built_ins = build_slash_commands
      @slash_menu = Shared::SlashMenuPopup.new(
        screen: @screen, conversation: @conversation,
        commands: built_ins + Shared::FileCommands.build(
          registry: @command_registry, reserved: built_ins.map(&:name),
          screen: @screen, logger: LOG,
          on_expand: ->(text) { submit(text) }
        )
      )
      @input = Shared::InputPane.new(
        on_submit: method(:submit), slash_menu: @slash_menu,
        conversation: @conversation, attachment_refusal: method(:attachment_refusal)
      )

      @confirmer = Code::TranscriptConfirmer.new(
        screen: @screen, conversation: @conversation,
        status_rule: @status_rule, input: @input
      )
      # ESC on the transcript (where the user answers a confirmation) hands the
      # caret back rather than falling through to the loop's unhandled-key quit.
      @ui_toggles = Shared::UIToggleMenu.new(screen: @screen, conversation: @conversation)
      @conversation.on_escape { @input.focus }
      @plan_mode_listener = Code::PlanModeListener.new(status_rule: @status_rule, screen: @screen)

      @layout = Layout.new(
        conversation: @conversation,
        status_rule: @status_rule,
        input: @input
      )
    end

    # The bash sandbox every agent shares: +FullFsNoNet+, or +NONE+ under
    # +--no-sandbox+ / +--yolo+ (+config.sandbox+ false), which re-opens the
    # network. Built here, not per agent: the bwrap probe in its constructor
    # raises (no silent fallback), and see the class docs for why that raise
    # belongs in +App.new+.
    #
    # @return [Pikuri::Code::Bash::Sandbox]
    # @raise [RuntimeError] if bwrap or a user/net namespace is unavailable.
    def build_sandbox
      return Pikuri::Code::Bash::Sandbox::NONE unless @config.sandbox

      Pikuri::Code::Bash::Sandbox::FullFsNoNet.new(filesystem: @filesystem)
    end

    # Open the shell's one conversation on +transport+, which boots its agent
    # on a thread of its own: the OS-assistant prompt (plus the online
    # network-posture block when +internet_enabled+ — offline adds nothing), the
    # desktop tool surface {#configure_agent} adds, and the panes' listeners —
    # the transcript rate-limited to 15 fps (see {Chat::App} for why), the
    # status rule and the plan-mode badge.
    #
    # @param transport [Pikuri::Agent::ChatTransport] the model it starts on.
    # @return [Pikuri::Conversations::Conversation]
    def open_session(transport)
      prompt_names = [:'os-assistant']
      prompt_names << :'os-network-online' if @internet_enabled
      prompt_names << :'agent-loop'
      system_prompt = Pikuri.prompts(*prompt_names)
      system_prompt += "\n\nCurrent date: #{Time.now.strftime('%Y-%m-%d')}"
      @conversations = Pikuri::Conversations.new(system_prompt: system_prompt, configure: method(:configure_agent))
      transcript = Pikuri::Conversations::RateLimitedListener.new(@conversation.listener, fps: 15)
      listener = Pikuri::Agent::ListenerList.new([transcript, @status_rule, @plan_mode_listener])
      @conversations.open(id: 'computer', transport: transport, listener: listener)
    end

    # The computer agent's desktop tool surface, built fresh for each agent —
    # at boot and after every clear — on the boot thread. Composes two pikuri
    # surfaces onto one agent: {Pikuri::Os::Extension} (the five file tools + a
    # network-severed sandboxed bash + the machine facts / MACHINE.md prompt
    # sections) and {Pikuri::Thunderbird::Extension} (mail + calendar
    # search/read + two human-gated outbound hand-offs). Web research, on unless
    # +internet_enabled+ is false, is quarantined: the web tools go on
    # sub-agent-only, so the main agent holds no direct egress and delegates to
    # an isolated RESEARCHER (web tools, no filesystem) gated by the confirmer.
    #
    # @param configurator [Pikuri::Agent::Configurator]
    # @param _conversation [Pikuri::Conversations::Conversation]
    # @return [void]
    def configure_agent(configurator, _conversation)
      # The in-transcript confirmer for writes + bash, unless confirmations are
      # disabled (--no-confirm / --yolo), in which case approve everything.
      # Pikuri::Os::Extension pairs this human confirmer with a
      # PassiveCommandDetector (allow_git: true) internally, so provably
      # passive bash + read-only git skip the popup while every mutation
      # still reaches it.
      confirmer = @config.confirm ? @confirmer : Pikuri::Workspace::Confirmer::AUTO_APPROVE

      configurator.add_tool Pikuri::Tool::CALCULATOR
      configurator.add_extension Pikuri::Os::Extension.new(
        filesystem: @filesystem,
        confirmer: confirmer,
        sandbox: @sandbox,
        # Threaded into both sub-extensions (Workspace gates Edit/Write, Code
        # wires the plan-mode tools + the PlanModeChanged event the status rule
        # badge tracks), the same flag the leader-menu 'p' toggle flips.
        read_only: @plan_mode
      )
      # No confirmer wired — the gate is Thunderbird's own compose window /
      # import wizard, where the user reviews and Sends/confirms.
      configurator.add_extension Pikuri::Thunderbird::Extension.new(
        profile_dir: @profile_dir,
        allow_compose_mail: true,
        allow_create_calendar_event: true
      )
      # Declaration only — commands register no tool and render no prompt, so
      # without this /trifecta would miss their untrusted leg entirely.
      configurator.add_extension Pikuri::Command::Extension.new(registry: @command_registry)
      return unless @internet_enabled

      # The confirmer gates each delegation's task prompt, so the human
      # approves what leaves this machine. The add_sub_agent_tool calls must
      # precede the SubAgent extension, whose configure validates the persona's
      # tool_names.
      configurator.add_sub_agent_tool Pikuri::Web::Search.build(**@config.search.to_h)
      configurator.add_sub_agent_tool Pikuri::Web::SCRAPE
      configurator.add_sub_agent_tool Pikuri::Web::FETCH
      configurator.add_extension Pikuri::SubAgent::Extension.new(
        personas: [Pikuri::SubAgent::RESEARCHER],
        confirmer: confirmer
      )
    end

    # Enter on the prompt: start a turn, or join the running one. A model known
    # to refuse the images gets nothing, and the line comes back for a fix.
    #
    # @param text [String] the line, +@path+ tokens split out.
    # @param attachments [Array<Pikuri::Attachment>] the images it named.
    # @return [void]
    def submit(text, attachments: [])
      @session.submit(text, attachments: attachments)
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
    # {Shared::InputPane} swallow them, and both surface a hint in the status
    # bar (which is why Ctrl+K is registered via {Shared::Log::UI#install_shortcut} —
    # its hint mutates as errors accrue).
    #
    # All app actions are reached through one of two keys; every other binding
    # (logs / plan mode / switch model) lives behind the {Shared::LeaderMenu}:
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

    # Start over on a fresh agent — the transcript wipes as it boots. Refused
    # while a turn runs, which is what Ctrl+C is for.
    #
    # @return [void]
    def clear_conversation
      LOG.warn('clear conversation ignored: a turn is in progress') if @session.clear == :busy
    end

    # Build the {Shared::LeaderMenu} for the computer shell: logs, plan mode, switch
    # model (only when there's more than one connection), and a hard quit.
    # The model entry is registered only when there's something to switch
    # to, so the menu never offers a no-op pick. (Like {Chat::App}'s set
    # plus +p+ plan mode, but without the coding shell's +d+ git diff —
    # the computer shell has no git window.)
    #
    # @return [Shared::LeaderMenu]
    def build_leader_menu
      menu = Shared::LeaderMenu.new(screen: @screen)
      menu.add('l', 'logs') { @log_ui.open }
      menu.add('p', 'plan mode') { toggle_plan_mode }
      menu.add('u', 'UI toggles') { @ui_toggles.open }
      menu.add('m', 'switch model') { @model_picker.open(session: @session) } if @model_picker.multiple?
      menu.add('c', 'clear conversation + context') { clear_conversation }
      menu.add('q', 'quit') { quit }
      menu
    end

    # The computer shell's slash commands — the {Shared::LeaderMenu} actions
    # reachable by name: +/logs+, +/plan+ (toggle), +/model+ (only with more
    # than one connection, like the menu's +m+), +/clear+, and +/exit+ =
    # +/quit+. No +/diff+ — the computer shell has no git window. Plus
    # +/trifecta+, which has no menu counterpart: a report to read when you
    # wonder, not an action worth a leader key — and the shell whose premise is
    # the reassembled trifecta is the one where it is worth reading.
    # +/image <path>+ has none either: it fills the prompt
    # ({Shared::InputPane#attach}) rather than acting. Callbacks
    # are lazy (they resolve +@log_ui+ / +@plan_mode+ / +@session+ /
    # +quit+ at run time), so this is safe to build before the conversation; only the
    # +/model+ *presence* is decided now, from {Shared::Model::Picker#multiple?}.
    #
    # @return [Array<Shared::SlashCommand>]
    def build_slash_commands
      quit_action = ->(_rest) { quit; nil }
      commands = [
        Shared::SlashCommand.new('/logs', 'open the diagnostic log',
                                 ->(_rest) { @log_ui.open; 'Opened the diagnostic log.' }),
        Shared::SlashCommand.new('/trifecta', 'lethal-trifecta report for this agent',
                                 ->(_rest) { trifecta_report }),
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
        Shared::SlashCommand.new('/clear', 'clear conversation + context',
                                 ->(_rest) { clear_conversation; nil }),
        Shared::SlashCommand.new('/exit', 'quits the app', quit_action),
        Shared::SlashCommand.new('/quit', 'quits the app', quit_action)
      )
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

    # Flip the shared {Pikuri::Workspace::ReadOnly} plan-mode flag —
    # enter if off, exit if on. Runs on the UI thread (global-shortcut
    # dispatch); the flag is thread-safe, and the status-rule badge updates
    # through {Code::PlanModeListener} off the +PlanModeChanged+ event the
    # flip emits, so this stays a one-liner and the model-flip path
    # renders the same way. Idempotent transitions
    # ({Pikuri::Workspace::ReadOnly#activate!}/{#deactivate!}) make a
    # double-press harmless.
    #
    # @return [void]
    def toggle_plan_mode
      @plan_mode.active? ? @plan_mode.deactivate! : @plan_mode.activate!
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
