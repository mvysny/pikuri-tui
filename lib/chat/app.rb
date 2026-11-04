# frozen_string_literal: true

require 'logger'
require 'pikuri-core'
require 'tuile'

module Chat
  # The Tuile shell behind +bin/pikuri-tui-chat+: builds the borderless
  # conversation pane, the status rule, the tinted prompt, the eager diagnostic {Shared::Log::Dialog}
  # (popup-visible via the {Shared::LeaderMenu}'s +l+ entry), the +Ctrl+K+ menu /
  # +Ctrl+C+ cancel global-shortcut hints
  # in the screen-wide status bar, and wires the agent's loop onto a worker
  # thread so the UI thread stays free for repaints.
  #
  # == Construction: App owns the agent
  #
  # App builds its own +Pikuri::Agent+ from the {Shared::Config} handed to
  # it — the chat system prompt, the boot connection ({#config}'s first
  # +llm+), and the web/calc tool set (see {#default_build_agent}). The bin
  # only parses CLI + config and mounts the screen; the agent, its tools,
  # and its listeners are the shell's identity and live here.
  #
  # Construction is linear, not cyclic: App builds the components (the
  # {Shared::ConversationTextView} owns the {Shared::ConversationTextView::Listener}
  # and {Shared::StatusRuleLabel}), *then* builds the agent against those
  # listeners.
  #
  # The optional +transport:+ is a **test seam**, not production ceremony: a
  # spec passes a +Pikuri::Testing.fake_transport+ so App builds its *real*
  # agent — the real {#default_build_agent} listener/tool wiring — on a
  # scripted-HTTP backend instead of a live server. Production omits it and
  # boots on the config's first connection ({#config}'s first +llm+). Only the
  # transport is injectable because the agent's collaborators (the conversation
  # listener, the status rule, the tools) are App's own objects — swapping the
  # backend is all a test needs to exercise the wiring without the network.
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
  # Per AGENTS.md's threading invariant, Tuile is single-threaded and the agent loop must not
  # run on the UI thread. App runs {Tuile::Screen#run_event_loop} on the
  # caller's thread (the main thread for the bin script) and delegates the
  # off-thread turn lifecycle — worker thread, mid-turn injection,
  # concurrency guard, spinner, Ctrl+C escalation — to a composed
  # {Shared::AgentSession} (see its threading contract). Enter routes to
  # +session.submit+, Ctrl+C to +session.interrupt+, leader +c+ to
  # +session.clear_conversation+.
  #
  # UI-thread-confined.
  class App
    # @return [Logger]
    LOG = Pikuri.logger_for('chat')
    private_constant :LOG

    # @return [Tuile::Screen] the (already-installed) screen this app
    #   runs on.
    attr_reader :screen

    # The shell's pane layout — not the screen's content component, which is
    # the {Shared::RootLayout} stacking this over {#status_bar}.
    #
    # @return [Chat::Layout]
    attr_reader :layout

    # @return [Shared::StatusBar] the bottom row.
    attr_reader :status_bar

    # @return [Shared::Config] the resolved configuration the bin loaded;
    #   drives the model list, the boot connection, and the web-search
    #   provider keys {#default_build_agent} reads.
    attr_reader :config

    # @return [Pikuri::Agent] the agent {#default_build_agent} built. Exposed
    #   so callers (and tests) can inspect tools/listeners/transport after
    #   wiring.
    attr_reader :agent

    # @return [Shared::AgentSession] the turn-lifecycle engine this shell
    #   composes; Enter / Ctrl+C / leader +c+ delegate into it. Exposed for
    #   tests.
    attr_reader :session

    # @return [Shared::ConversationTextView] the conversation transcript
    #   pane. Exposed primarily for tests; production code should reach
    #   it through the {Shared::ConversationTextView::Listener}.
    attr_reader :conversation

    # @return [Shared::Log::Dialog] the eager-constructed
    #   diagnostic log (owned by the {Shared::Log::UI}). Exposed for tests and for
    #   callers that want to install additional logger sinks.
    def log_dialog = @log_ui.log_dialog

    # @return [Pikuri::Agent::Listener::TokenLog] the main agent's token
    #   log, App-owned and fed into the {Shared::StatusRuleLabel}.
    #   {#default_build_agent} registers this same instance in the agent's
    #   +ListenerList+ so it receives +Tokens+ events.
    attr_reader :token_log

    # @return [Shared::StatusRuleLabel] the status rule between the
    #   conversation and the prompt, which doubles as the model-name listener.
    #   {#default_build_agent} registers it in the agent's +ListenerList+ so
    #   +ModelSwitched+ events reach it.
    attr_reader :status_rule

    # @param config [Shared::Config] the resolved configuration; App derives
    #   the model list (one {Shared::Model::Choice} per +config.llms+ entry,
    #   the first the boot connection) and reads the web-search provider keys
    #   from it when building the agent.
    # @param markdown [Boolean] forwarded to {Shared::ConversationTextView}'s
    #   +markdown:+ flag (default +true+). When +false+, the
    #   conversation pane skips +TTY::Markdown+ and the streaming path
    #   uses {Shared::Markdown::PassthroughBuffer} — appropriate for back-ends whose
    #   content is already in display form.
    # @param transport [Pikuri::Agent::ChatTransport, nil] test seam: the
    #   backend to build the real agent on. Omit in production (boots on the
    #   config's first connection); a spec passes a
    #   +Pikuri::Testing.fake_transport+ to run real turns against scripted
    #   HTTP. See the class header.
    def initialize(config:, markdown: true, transport: nil)
      @screen = Tuile::Screen.instance
      @config = config
      @markdown = markdown
      @token_log = Pikuri::Agent::Listener::TokenLog.new
      @models = config.llms.map { |llm| Shared::Model::Choice.from_llm(llm) }
      Shared::RequestPermits.install(config.servers)
      @model_picker = Shared::Model::Picker.new(models: @models)
      # Test seam: the backend the agent boots on. Production uses the config's
      # first connection; a spec injects a fake_transport (see class header).
      @boot_transport = transport || @models.first.transport

      build_components
      @log_ui.wire!
      @agent = default_build_agent
      @session.agent = @agent
      @status_rule.interloper = @agent.interloper
      # Seed the rule with the boot model (resolved from its transport);
      # Shared::StatusRuleLabel#on_event takes over on every later switch.
      @status_rule.current_model = @agent.transport

      @leader_menu = build_leader_menu
      @screen.on_error << method(:on_screen_error)
      @screen.content = Shared::RootLayout.new(@layout, @status_bar)
      # The prompt is the shell's only focus target; Shared::InputPane#focus
      # forwards onto its private editable area.
      @input.focus
      register_shortcuts
    end

    # Runs the Tuile event loop, blocking the calling thread until the user
    # quits ({Tuile::Keys::ESC} or +q+) or the loop is otherwise stopped. Does
    # NOT close the screen: the bin owns teardown via +begin/ensure
    # Tuile::Screen.close+ around both +App.new+ and this call, so the screen
    # is torn down whether the failure is in construction (a boot-time
    # transport probe) or in the loop. +run_event_loop+ only restores stdin /
    # cursor / mouse; +Screen#close+ clears the frame and unsets the singleton.
    #
    # @return [void]
    def run
      @screen.run_event_loop
    end

    private

    # @return [void]
    def build_components
      @status_bar = Shared::StatusBar.new
      @log_ui = Shared::Log::UI.new(screen: @screen, status_bar: @status_bar)

      @conversation = Shared::ConversationTextView.new(
        markdown: @markdown, show_thinking: @config.show_thinking, tool_detail: @config.tool_lines
      )
      @status_rule = Shared::StatusRuleLabel.new(token_log: @token_log, names: @model_picker.names)

      @session = Shared::AgentSession.new(
        screen: @screen, conversation: @conversation, status_rule: @status_rule,
        model_picker: @model_picker, logger: LOG
      )

      @slash_menu = Shared::SlashMenuPopup.new(
        screen: @screen, commands: build_slash_commands, conversation: @conversation
      )
      @input = Shared::InputPane.new(
        on_submit: @session.method(:submit), slash_menu: @slash_menu,
        conversation: @conversation
      )
      @session.on_attachment_refused { |reason| @input.refuse_attachment(reason) }
      # ESC (or q) on the transcript hands the caret back rather than falling
      # through to the loop's unhandled-key quit. This shell asks no
      # confirmations, but Tab still reaches the pane.
      @ui_toggles = Shared::UIToggleMenu.new(screen: @screen, conversation: @conversation)
      @conversation.on_escape { @input.focus }

      @layout = Layout.new(
        conversation: @conversation,
        status_rule: @status_rule,
        input: @input
      )
    end

    # The chat shell's slash commands — the {Shared::LeaderMenu} actions
    # reachable by name: +/logs+, +/model+ (only with more than one connection,
    # like the menu's +m+), +/clear+, and +/exit+ = +/quit+ — plus +/trifecta+,
    # which has no menu counterpart: a report to read when you wonder, not an
    # action worth a leader key. +/image <path>+ has none either: it fills the
    # prompt ({Shared::InputPane#attach}) rather than acting. Callbacks are lazy (they resolve +@log_ui+ /
    # +@session+ / +@agent+ / +quit+ at run time), so this is safe to build
    # before the agent; only the +/model+ *presence* is decided now, from
    # {Shared::Model::Picker#multiple?}.
    #
    # @return [Array<Shared::SlashCommand>]
    def build_slash_commands
      quit_action = ->(_rest) { quit; nil }
      commands = [
        Shared::SlashCommand.new('/logs', 'open the diagnostic log',
                                 ->(_rest) { @log_ui.open; 'Opened the diagnostic log.' }),
        Shared::SlashCommand.new('/trifecta', 'lethal-trifecta report for this agent',
                                 ->(_rest) { Shared::TrifectaRenderer.render(@agent.trifecta, theme: @screen.theme) }),
        Shared::SlashCommand.new('/thinking', 'show / hide reasoning (blank toggles)',
                                 ->(rest) { @conversation.select_thinking(rest) }),
        Shared::SlashCommand.new('/tools', 'tool lines short / verbose (blank toggles)',
                                 ->(rest) { @conversation.select_tool_detail(rest) }),
        Shared::SlashCommand.new('/image', 'attach an image: /image <path>',
                                 ->(rest) { @input.attach(rest); nil })
      ]
      if @model_picker.multiple?
        commands << Shared::SlashCommand.new('/model', 'switch model',
                                             ->(_rest) { @model_picker.open(current: @agent.transport); nil })
      end
      commands.push(
        Shared::SlashCommand.new('/clear', 'clear conversation + context',
                                 ->(_rest) { @session.clear_conversation; nil }),
        Shared::SlashCommand.new('/exit', 'quits the app', quit_action),
        Shared::SlashCommand.new('/quit', 'quits the app', quit_action)
      )
    end

    # Build the chat shell's +Pikuri::Agent+: a streaming agent on the boot
    # connection (+@boot_transport+, the config's first connection unless a
    # test injected a fake), the +pikuri-chat+ system prompt (dated), and the
    # web-search / calculator / scrape / fetch tool set. Registers the
    # conversation listener (rate-limited to 15 fps), {#token_log}, and the
    # {#status_rule} into the agent's +ListenerList+ — all reached
    # through the {Shared::ConversationTextView} this App owns, so nothing has to
    # be passed in.
    #
    # @return [Pikuri::Agent] the wired agent.
    def default_build_agent
      listener = @conversation.listener

      Pikuri::Extractors::PDF.register

      system_prompt = Pikuri.prompts(:'pikuri-chat', :'agent-loop')
      system_prompt += "\n\nCurrent date: #{Time.now.strftime('%Y-%m-%d')}"

      # Coalesce streaming delta chunks at 15 fps before they reach the
      # Markdown-rendering Shared::ConversationTextView: a fast llama.cpp can
      # emit dozens of deltas per second and re-rendering Markdown on every
      # one is wasted work the user can't perceive. flush_pending_on_non_delta:
      # false because the Assistant / Thinking bookend events re-render the
      # authoritative final content (the listener finalizes the open streamed
      # block, replacing the preview), so emitting the trailing 0–66 ms of
      # buffered deltas right before the redraw is pure CPU waste.
      rate_limited_listener = Pikuri::Agent::Listener::RateLimited.new(
        listener, fps: 15, flush_pending_on_non_delta: false
      )

      Pikuri::Agent.new(
        transport: @boot_transport,
        system_prompt: system_prompt,
        cancellable: Pikuri::Agent::Control::Cancellable.new,
        interloper: Pikuri::Agent::Control::Interloper.new,
        streaming: true
      ) do |c|
        c.add_listener rate_limited_listener
        c.add_listener @token_log
        c.add_listener @status_rule
        c.add_tool Pikuri::Tool::WebSearch.build(**@config.search.to_h)
        c.add_tool Pikuri::Tool::CALCULATOR
        c.add_tool Pikuri::Tool::WEB_SCRAPE
        c.add_tool Pikuri::Tool::FETCH
      end
    end

    # Wire app-level keyboard shortcuts on the screen. Both bypass the
    # cursor-owner suppression that would otherwise let the focused
    # {Shared::InputPane} swallow them, and both surface a hint in the screen's
    # status bar (which is why Ctrl+K is registered via
    # {Shared::Log::UI#install_shortcut} — its hint mutates as errors accrue).
    #
    # All app actions are reached through one of two keys; every other
    # binding lives behind the {Shared::LeaderMenu}:
    #
    # - +Ctrl+K+ opens the {Shared::LeaderMenu} command popup (logs / switch model
    #   / quit). +over_modal: false+ (the default), so it can't stack over
    #   an open popup. The {Shared::Log::UI} owns this binding because its hint also
    #   carries the unread-error tally — the only always-visible status-bar
    #   surface.
    # - +Ctrl+C+ runs the {Shared::AgentSession#interrupt} escalation (cancel turn →
    #   unfocus → quit). The one direct accelerator kept: it is the urgent
    #   mid-turn interrupt, not a command we want behind a chord. Also
    #   +over_modal: false+: a popup means the user isn't interacting with
    #   the LLM, so Ctrl+C is the popup's business, not ours. The trade-off
    #   is that you can't cancel a running turn while a popup happens to be
    #   open — close it (ESC/q) first.
    #
    # @return [void]
    def register_shortcuts
      @screen.register_global_shortcut(Tuile::Keys::CTRL_C) { @session.interrupt }
      @log_ui.install_shortcut { @leader_menu.open }
    end

    # Build the {Shared::LeaderMenu} for the chat shell: logs, switch model (only
    # when there's more than one connection to pick between), and a hard
    # quit. The model entry is registered only when there's something to
    # switch to, so the menu never offers a no-op pick.
    #
    # @return [Shared::LeaderMenu]
    def build_leader_menu
      menu = Shared::LeaderMenu.new(screen: @screen)
      menu.add('l', 'logs') { @log_ui.open }
      menu.add('u', 'UI toggles') { @ui_toggles.open }
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
