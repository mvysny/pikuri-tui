# frozen_string_literal: true

require 'tuile'

module Chat
  # The conversation transcript as one cohesive component: a
  # {Tuile::Component::Window} that owns its scrolling
  # {Tuile::Component::TextView}, its {Shared::StatusLabel} footer chrome,
  # and the two listeners that keep both current off the agent's event
  # stream — the {Shared::TuileListener} (renders the transcript) and the
  # {Shared::Model::Listener} (keeps the footer's model name in step with a
  # landed +run_loop+ switch).
  #
  # This is a "domain component" in the sense of AGENTS.md's "Design with
  # components (COP)" rule: its whole responsibility *is* showing a
  # +Pikuri::Agent+ conversation and keeping itself current, so it owns its
  # +Pikuri::*+ wiring (builds its own listeners) rather than having {App}
  # hand-assemble a bare +Window+, a loose +TextView+, and two dangling
  # listeners around it. Folding that cluster in here is what collapses the
  # otherwise-triplicated conversation-pane wiring across the three shells;
  # this Chat-scoped copy is the proof of shape, to be promoted to
  # +Shared::+ and reused by the coding / OS shells once it settles.
  #
  # == The listener seam
  #
  # The window builds its listeners at construction — before the agent
  # exists — and exposes them ({#listener} / {#model_listener}) for the host
  # to fold into the agent's +ListenerList+. The host owns that final
  # composition because the agent needs several listeners (the +TokenLog+,
  # and in the other shells a task / plan-mode listener), not just these
  # two. The two footer values the host can only supply once the agent is
  # built — the mid-turn {Pikuri::Agent::Control::Interloper} and the boot
  # model's display name — are forwarded through {#interloper=} /
  # {#current_model=}.
  #
  # == Threading
  #
  # The listeners self-marshal their UI mutations onto the event-loop
  # thread (see {Shared::TuileListener} / {Shared::Model::Listener}).
  # {#start_animation} / {#stop_animation} forward to {Shared::StatusLabel}
  # and so must be called on the UI thread. {#render_turn_error} is the one
  # method called from the agent worker thread; it marshals its own append
  # via the screen's event queue.
  class ConversationWindow < Tuile::Component::Window
    # @param screen [Tuile::Screen] the screen this window paints on; its
    #   +event_queue+ marshals {#render_turn_error}'s append and drives the
    #   footer spinner. Passed to the footer and both listeners.
    # @param token_log [Pikuri::Agent::Listener::TokenLog] the main agent's
    #   token log, fed into the {Shared::StatusLabel} footer. The host must
    #   wire the *same* instance into the agent's +ListenerList+.
    # @param title [String] the window's border title. Defaults to
    #   +'Conversation'+ (the coding shell passes its project root).
    # @param markdown [Boolean] forwarded to {Shared::TuileListener}'s
    #   +markdown:+ flag (default +true+).
    # @param tool_formatters [Hash{String => Object}] forwarded to
    #   {Shared::TuileListener}'s +tool_formatters:+ (the per-tool diff
    #   formatters the coding / OS shells wire for +edit+ / +write+).
    #   Defaults to +{}+ — the chat shell registers none.
    # @param model_names [Hash{Array(String, String) => String}]
    #   {Shared::Model::Choice.key} → display name, forwarded to
    #   {Shared::Model::Listener}'s +names:+. Defaults to +{}+.
    def initialize(screen:, token_log:, title: 'Conversation', markdown: true, tool_formatters: {}, model_names: {})
      super(title)
      @screen = screen
      @view = Tuile::Component::TextView.new
      @view.auto_scroll = true
      self.content = @view
      self.scrollbar = true
      # Border chrome, not a widget slot: the Shared::StatusLabel embeds the
      # agent status into this window's bottom border (window: self).
      @status_label = Shared::StatusLabel.new(screen: screen, window: self, token_log: token_log)
      @listener = Shared::TuileListener.new(
        text_view: @view, screen: screen, markdown: markdown, tool_formatters: tool_formatters
      )
      @model_listener = Shared::Model::Listener.new(footer: @status_label, screen: screen, names: model_names)
    end

    # @return [Tuile::Component::TextView] the conversation transcript pane.
    #   Exposed primarily for tests; production code reaches it through the
    #   {#listener}.
    attr_reader :view

    # @return [Shared::StatusLabel] the footer chrome. Named +status_label+
    #   rather than +footer+ so it doesn't shadow
    #   {Tuile::Component::Window#footer} (which stays +nil+ — the status is
    #   border chrome via +footer_text+, not a footer-slot component).
    attr_reader :status_label

    # @return [Shared::TuileListener] the transcript listener; the host
    #   includes it in the agent's +ListenerList+.
    attr_reader :listener

    # @return [Shared::Model::Listener] the footer model-name listener; the
    #   host includes it in the agent's +ListenerList+.
    attr_reader :model_listener

    # Hand the footer the agent's mid-turn input queue so it can render the
    # "N queued" segment. Set once by the host after the agent is built.
    #
    # @param interloper [Pikuri::Agent::Control::Interloper, nil]
    # @return [void]
    def interloper=(interloper)
      @status_label.interloper = interloper
    end

    # Seed / update the footer's model-name segment. The host sets the boot
    # model once after the agent is built; {Shared::Model::Listener} takes
    # over on every later switch.
    #
    # @param name [String, nil]
    # @return [void]
    def current_model=(name)
      @status_label.current_model = name
    end

    # Start the footer's mid-turn spinner. Must be called on the UI thread.
    #
    # @return [void]
    def start_animation = @status_label.start_animation

    # Stop the footer's mid-turn spinner, settling it back to idle. Must be
    # called on the UI thread.
    #
    # @return [void]
    def stop_animation = @status_label.stop_animation

    # Append a one-line, error-themed turn-failure notice to the transcript
    # so the user sees a turn ended in failure without opening the log
    # popup. Called from the agent worker thread ({App#start_turn}'s
    # rescue), so it marshals the append onto the event-loop thread itself.
    #
    # @param exception [StandardError] the caught library exception.
    # @return [void]
    def render_turn_error(exception)
      @screen.event_queue.submit do
        @view.add_line(@screen.theme.error("! #{exception.class}: #{exception.message}"))
      end
    end
  end
end
