# frozen_string_literal: true

require 'logger'
require 'pikuri-core'
require 'tuile'

module Chat
  # The Tuile shell behind +bin/pikuri-tui-chat+: builds the framed conversation
  # pane, the framed input pane, the eager diagnostic +LogWindow+
  # (popup-visible via the {Shared::LeaderMenu}'s +l+ entry), the +Ctrl+K+ menu /
  # +Ctrl+C+ cancel global-shortcut hints
  # in the screen-wide status bar, and wires the agent's loop onto a worker
  # thread so the UI thread stays free for repaints.
  #
  # == Construction order
  #
  # The agent needs the conversation-pane listeners in its +ListenerList+,
  # and those listeners need the conversation +TextView+ — which can't
  # exist until the screen is initialized. Resolving that cycle is why the
  # constructor takes a block: App builds the components (the
  # {Shared::ConversationWindow} builds and owns the {Shared::ConversationWindow::Listener}
  # and {Shared::StatusFooterUpdater}), then yields them to the block; the block
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
    LOG = Pikuri.logger_for('chat')
    private_constant :LOG

    # @return [Tuile::Screen] the (already-installed) screen this app
    #   runs on.
    attr_reader :screen

    # @return [Pikuri::Agent] the agent the build block returned. Exposed
    #   so callers (and tests) can inspect tools/listeners/transport
    #   after wiring.
    attr_reader :agent

    # @return [Shared::AgentSession] the turn-lifecycle engine this shell
    #   composes; Enter / Ctrl+C / leader +c+ delegate into it. Exposed for
    #   tests.
    attr_reader :session

    # @return [Tuile::Component::TextView] the conversation transcript
    #   pane. Exposed primarily for tests; production code should reach
    #   it through the {Shared::ConversationWindow::Listener}.
    def conversation_view = @conversation_window.view

    # @return [Tuile::Component::LogWindow] the eager-constructed
    #   diagnostic window (owned by the {Shared::Log::UI}). Exposed for tests and for
    #   callers that want to install additional logger sinks.
    def log_window = @log_ui.log_window

    # @return [Pikuri::Agent::Listener::TokenLog] the main agent's
    #   token log, fed into the conversation-window {Shared::StatusFooterUpdater}.
    #   The host's build block must include this instance (or one
    #   the host supplied via the +token_log:+ ctor arg) in the
    #   agent's +ListenerList+ so it actually receives +Tokens+
    #   events; the App doesn't register listeners itself.
    attr_reader :token_log

    # @return [Shared::StatusFooterUpdater] the footer, which doubles as the
    #   model-name listener, yielded to the build block. The host must include
    #   it in the agent's +ListenerList+ so +ModelSwitched+ events reach it.
    def status_footer_updater = @conversation_window.status_footer_updater

    # @param token_log [Pikuri::Agent::Listener::TokenLog] the
    #   per-conversation token log whose +status_line+ feeds the
    #   conversation-window footer. The host is responsible for
    #   wiring the same instance into the agent's +ListenerList+
    #   (so it actually receives +Tokens+ events). Defaults to a
    #   fresh instance — tests that don't exercise the footer can
    #   ignore this knob.
    # @param markdown [Boolean] forwarded to {Shared::ConversationWindow}'s
    #   +markdown:+ flag (default +true+). When +false+, the
    #   conversation pane skips +TTY::Markdown+ and the streaming path
    #   uses {Shared::Markdown::PassthroughBuffer} — appropriate for back-ends whose
    #   content is already in display form.
    # @param models [Array<Shared::Model::Choice>] the connections the leader menu's
    #   +m+ model picker offers, in display order. The +m+ menu entry is
    #   registered only when more than one is given (nothing to switch
    #   between otherwise); the map of model id → name still drives the
    #   footer's model segment regardless. Defaults to empty — tests and
    #   single-connection hosts can ignore it.
    # @yield [listener, status_footer_updater] one-shot factory invoked exactly
    #   once during construction. The block receives the {Shared::ConversationWindow::Listener}
    #   bound to this app's conversation pane and the {Shared::StatusFooterUpdater}
    #   that keeps the footer's model name current, and must return a
    #   constructed +Pikuri::Agent+ whose +ListenerList+ includes both
    #   (plus the +token_log+ exposed at {#token_log}).
    # @yieldparam listener [Shared::ConversationWindow::Listener] the conversation-pane
    #   listener; include it in the agent's +ListenerList+.
    # @yieldparam status_footer_updater [Shared::StatusFooterUpdater] the footer,
    #   which doubles as the model-name listener; include it in the agent's +ListenerList+.
    # @yieldreturn [Pikuri::Agent] the wired agent.
    # @raise [LocalJumpError] if no block is given (no agent → no app).
    def initialize(token_log: Pikuri::Agent::Listener::TokenLog.new, markdown: true, models: [], &build_agent)
      raise LocalJumpError, 'Chat::App requires a block that builds the Pikuri::Agent' unless block_given?

      @screen = Tuile::Screen.instance
      @token_log = token_log
      @markdown = markdown
      @model_picker = Shared::Model::Picker.new(models: models)

      build_components
      @log_ui.wire!
      @agent = build_agent.call(@conversation_window.listener, @conversation_window.status_footer_updater)
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
      @screen.run_event_loop
    ensure
      @screen.close
    end

    private

    # @return [void]
    def build_components
      @log_ui = Shared::Log::UI.new(screen: @screen)

      @conversation_window = Shared::ConversationWindow.new(
        token_log: @token_log, markdown: @markdown, model_names: @model_picker.names
      )

      @session = Shared::AgentSession.new(
        screen: @screen, conversation_window: @conversation_window,
        model_picker: @model_picker, logger: LOG
      )

      @input_window = Shared::InputWindow.new(on_submit: @session.method(:submit))

      @layout = Layout.new(
        conversation: @conversation_window,
        input: @input_window
      )
    end

    # Wire app-level keyboard shortcuts on the screen. Both bypass the
    # cursor-owner suppression that would otherwise let the focused
    # {Shared::InputWindow} swallow them, and both surface a hint in the screen's
    # status bar (which is why Ctrl+K is registered via
    # {Shared::Log::UI#install_shortcut} — its hint mutates as errors accrue).
    #
    # All app actions are reached through one of two keys; every other
    # binding lives behind the {Shared::LeaderMenu}:
    #
    # - +Ctrl+K+ opens the {Shared::LeaderMenu} command popup (logs / switch model
    #   / quit). +over_popups: false+ (the default), so it can't stack over
    #   an open popup. The {Shared::Log::UI} owns this binding because its hint also
    #   carries the unread-error tally — the only always-visible status-bar
    #   surface.
    # - +Ctrl+C+ runs the {Shared::AgentSession#interrupt} escalation (cancel turn →
    #   unfocus → quit). The one direct accelerator kept: it is the urgent
    #   mid-turn interrupt, not a command we want behind a chord. Also
    #   +over_popups: false+: a popup means the user isn't interacting with
    #   the LLM, so Ctrl+C is the popup's business, not ours. The trade-off
    #   is that you can't cancel a running turn while a popup happens to be
    #   open — close it (ESC/q) first.
    #
    # @return [void]
    def register_shortcuts
      @screen.register_global_shortcut(
        Tuile::Keys::CTRL_C,
        hint: "^C #{@screen.theme.error('cancel')}"
      ) { @session.interrupt }
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

    # @param exception [StandardError]
    # @return [void]
    def on_screen_error(exception)
      LOG.error(
        "#{exception.class}: #{exception.message}\n#{(exception.backtrace || []).join("\n")}"
      )
    end
  end
end
