# frozen_string_literal: true

require 'logger'
require 'pikuri-core'
require 'pikuri-conversations'
require 'pikuri-web'
require 'tuile'

module Chat
  # The Tuile shell behind +bin/pikuri-tui-chat+: builds the borderless
  # conversation pane, the status rule, the tinted prompt, the eager diagnostic {Shared::Log::Dialog}
  # (popup-visible via the {Shared::LeaderMenu}'s +l+ entry), the +Ctrl+K+ menu /
  # +Ctrl+C+ cancel global-shortcut hints
  # in the screen-wide status bar, and runs the agent on one
  # +Pikuri::Conversations+ conversation, whose threads keep the UI thread free
  # for repaints.
  #
  # == Construction: App owns the conversation
  #
  # App opens its own conversation from the {Shared::Config} handed to it —
  # the chat system prompt, the boot connection ({#config}'s first +llm+), and
  # the web/calc tool set (see {#configure}). The bin only parses CLI +
  # config and mounts the screen; the agent, its tools, and its listeners are
  # the shell's identity and live here.
  #
  # Construction is linear, not cyclic: App builds the components, *then*
  # opens the conversation with their listeners, which boots the agent on a
  # thread of its own — the UI is up before the agent is.
  #
  # The optional +transport:+ is a **test seam**, not production ceremony: a
  # spec passes a +Pikuri::Testing.fake_transport+ so App builds its *real*
  # agent — the real {#configure} tool wiring and listeners — on a
  # scripted-HTTP backend instead of a live server.
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
  # caller's thread (the main thread for the bin script); the conversation
  # ({#session}) builds the agent and runs each turn on threads of its own,
  # and every call into it returns at once. What happens there reaches the
  # panes as events, each listener marshaling onto the UI thread. Enter routes
  # to +session.submit+ (a message typed mid-turn joins the running turn),
  # Ctrl+C to {#interrupt}, leader +c+ to {#clear_conversation}.
  #
  # UI-thread-confined.
  class App
    include Pikuri::Conversations::AgentInitializer

    # @return [Logger]
    LOG = Pikuri.logger_for('chat')
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
    # @return [Chat::Layout]
    attr_reader :layout

    # @return [Shared::StatusBar] the bottom row.
    attr_reader :status_bar

    # @return [Shared::Config] the resolved configuration the bin loaded;
    #   drives the model list, the boot connection, and the web-search
    #   provider keys {#configure} reads.
    attr_reader :config

    # @return [Pikuri::Conversations::Conversation] the one conversation this
    #   shell runs; Enter, Ctrl+C, the model picker and leader +c+ drive it.
    attr_reader :session

    # @return [Shared::ConversationTextView] the conversation transcript
    #   pane. Exposed primarily for tests; production code should reach
    #   it through the {Shared::ConversationTextView::Listener}.
    attr_reader :conversation

    # @return [Shared::Log::Dialog] the eager-constructed
    #   diagnostic log (owned by the {Shared::Log::UI}). Exposed for tests and for
    #   callers that want to install additional logger sinks.
    def log_dialog = @log_ui.log_dialog

    # @return [Shared::StatusRuleLabel] the status rule between the
    #   conversation and the prompt; it follows the conversation as a listener.
    attr_reader :status_rule

    # @param config [Shared::Config] the resolved configuration; App derives
    #   the model list (one {Shared::Model::Choice} per +config.llms+ entry,
    #   the first the boot connection) and reads the web-search provider keys
    #   from it when building an agent.
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
      @models = config.llms.map { |llm| Shared::Model::Choice.from_llm(llm) }
      Shared::RequestPermits.install(config.servers)
      Pikuri::Extractors::PDF.register
      @model_picker = Shared::Model::Picker.new(models: @models)

      build_components
      @log_ui.wire!
      @session = open_session(transport || @models.first.transport)
      # Shared::StatusRuleLabel#on_event takes over on every later switch.
      @status_rule.current_model = @session.status.model

      @leader_menu = build_leader_menu
      @screen.on_error << method(:on_screen_error)
      @screen.content = Shared::RootLayout.new(@layout, @status_bar)
      # The prompt is the shell's only focus target; Shared::InputPane#focus
      # forwards onto its private editable area.
      @input.focus
      register_shortcuts
    end

    # Runs the Tuile event loop, blocking the calling thread until the user
    # quits ({Tuile::Keys::ESC} or +q+) or the loop is otherwise stopped, then
    # {#close}s the conversation. Does NOT close the screen: the bin owns
    # teardown via +begin/ensure Tuile::Screen.close+ around both +App.new+ and
    # this call. +run_event_loop+ only restores stdin / cursor / mouse;
    # +Screen#close+ clears the frame and unsets the singleton.
    #
    # @return [void]
    def run
      @screen.run_event_loop
    ensure
      close
    end

    # Close the conversation, cancelling a running turn, and wait a moment for
    # its agent to be released. Idempotent.
    #
    # @return [void]
    def close
      @conversations.shutdown(timeout: CLOSE_TIMEOUT_S)
      nil
    end

    # The +pikuri-chat+ system prompt, dated. Built once per agent, so the
    # date is a clear's, not the launch's.
    #
    # @param _conversation [Pikuri::Conversations::Conversation]
    # @return [String]
    def system_prompt(_conversation)
      "#{Pikuri.prompts(:'pikuri-chat', :'agent-loop')}\n\nCurrent date: #{Time.now.strftime('%Y-%m-%d')}"
    end

    # The chat agent's tools: web search / scrape / fetch and the calculator.
    # Runs once per agent — at boot and after every clear — on the boot thread.
    #
    # @param configurator [Pikuri::Agent::Configurator]
    # @param _conversation [Pikuri::Conversations::Conversation]
    # @return [void]
    def configure(configurator, _conversation)
      configurator.add_tool Pikuri::Web::Search.build(**@config.search.to_h)
      configurator.add_tool Pikuri::Tool::CALCULATOR
      configurator.add_tool Pikuri::Web::SCRAPE
      configurator.add_tool Pikuri::Web::FETCH
    end

    private

    # @return [void]
    def build_components
      @status_bar = Shared::StatusBar.new
      @log_ui = Shared::Log::UI.new(screen: @screen, status_bar: @status_bar)

      @conversation = Shared::ConversationTextView.new(
        markdown: @markdown, show_thinking: @config.show_thinking, tool_detail: @config.tool_lines
      )
      @status_rule = Shared::StatusRuleLabel.new(names: @model_picker.names)

      @slash_menu = Shared::SlashMenuPopup.new(
        screen: @screen, commands: build_slash_commands, conversation: @conversation
      )
      @input = Shared::InputPane.new(
        on_submit: method(:submit), slash_menu: @slash_menu,
        conversation: @conversation, attachment_refusal: method(:attachment_refusal)
      )
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
    # +@session+ / +quit+ at run time), so this is safe to build before the
    # conversation; only the +/model+ *presence* is decided now, from
    # {Shared::Model::Picker#multiple?}.
    #
    # @return [Array<Shared::SlashCommand>]
    def build_slash_commands
      quit_action = ->(_rest) { quit; nil }
      commands = [
        Shared::SlashCommand.new('/logs', 'open the diagnostic log',
                                 ->(_rest) { @log_ui.open; 'Opened the diagnostic log.' }),
        Shared::SlashCommand.new('/trifecta', 'lethal-trifecta report for this agent',
                                 ->(_rest) { trifecta_report }),
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

    # Open the shell's one conversation on +transport+, which boots its agent
    # on a thread of its own: {#system_prompt}, the tools {#configure} adds,
    # and the panes' listeners — the transcript
    # rate-limited to 15 fps (a fast llama.cpp emits dozens of deltas a second,
    # and re-rendering Markdown on each is wasted work), and the status rule.
    #
    # @param transport [Pikuri::Agent::ChatTransport] the model it starts on.
    # @return [Pikuri::Conversations::Conversation]
    def open_session(transport)
      @conversations = Pikuri::Conversations.new
      transcript = Pikuri::Conversations::RateLimitedListener.new(@conversation.listener, fps: 15)
      listener = Pikuri::Agent::ListenerList.new([transcript, @status_rule])
      @conversations.open(id: 'chat', transport: transport, listener: listener, initializer: self)
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
    # - +Ctrl+C+ runs the {#interrupt} escalation (cancel turn → unfocus →
    #   quit). The one direct accelerator kept: it is the urgent
    #   mid-turn interrupt, not a command we want behind a chord. Also
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

    # The +Ctrl+C+ escalation, three states in priority order: a running turn
    # (or boot) is cancelled; else a focused pane drops focus, as ESC does; else
    # the event loop stops, which quits. Registered +over_modal: false+, so it
    # never runs while a popup is open.
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
      menu.add('m', 'switch model') { @model_picker.open(session: @session) } if @model_picker.multiple?
      menu.add('c', 'clear conversation + context') { clear_conversation }
      menu.add('q', 'quit') { quit }
      menu
    end

    # Stop the event loop, unwinding {#run} into +Screen#close+. The leader
    # menu's +q+ action — a hard quit, distinct from {#interrupt}'s escalation
    # (no turn-cancel / unfocus steps). Runs on the event-loop
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
