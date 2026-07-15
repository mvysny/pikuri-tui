# frozen_string_literal: true

require 'tuile'

# A {Tuile::Component::Window} showing a +Pikuri::Agent+ conversation: it
# frames a {Shared::ConversationTextView} transcript pane and a
# {Shared::StatusFooterUpdater} footer. Both duck-type as agent listeners
# (the transcript via {#listener}, the footer via {#status_footer_updater});
# the host folds them into the agent, then feeds the two values that only
# exist once the agent is built:
#
#   win = Shared::ConversationWindow.new(token_log: token_log)
#   config.add_listener(win.listener)                # transcript + model name, both
#   config.add_listener(win.status_footer_updater)   #   into the ListenerList (plus token_log)
#   win.interloper = agent.interloper                # mid-turn "N queued" segment
#   win.current_model = 'Local Qwen 3.6'
#
# The plan-mode badge is not wired here: the footer exposes +plan_active=+
# via {#status_footer_updater}, but the +Code::PlanModeListener+ feeding it
# is a +:code+-group concern, so the coding / computer shells bind it themselves.
#
# UI-thread-confined, with exceptions.
class Shared::ConversationWindow < Tuile::Component::Window
  # @param token_log [Pikuri::Agent::Listener::TokenLog] the agent's token
  #   log, fed into the footer. The host must wire the *same* instance into
  #   the agent's +ListenerList+.
  # @param title [String] the window's border caption.
  # @param markdown [Boolean] forwarded to {Shared::ConversationTextView}.
  # @param tool_formatters [Hash{String => Object}] per-tool diff formatters,
  #   forwarded to {Shared::ConversationTextView}.
  # @param model_names [Hash{Array(String, String) => String}]
  #   {Shared::Model::Choice.key} → display name, forwarded to the
  #   {Shared::StatusFooterUpdater} so a transport passed to {#current_model=}
  #   resolves to a friendly name.
  def initialize(token_log:, title: 'Conversation', markdown: true, tool_formatters: {}, model_names: {})
    super(title)
    @view = Shared::ConversationTextView.new(markdown: markdown, tool_formatters: tool_formatters)
    self.content = @view
    self.scrollbar = true
    # The footer chrome and the leaf listeners this window builds directly
    # aren't components, so they take the screen explicitly — this window
    # hands them its own inherited +#screen+ property (the {Tuile::Screen}
    # singleton, fake-able via +Tuile::Screen.fake+ for tests). Its
    # +event_queue+ marshals {#render_turn_error} and drives the spinner.
    # Border chrome, not a widget slot: the Shared::StatusFooterUpdater embeds the
    # agent status into this window's bottom border (window: self).
    @status_footer_updater = Shared::StatusFooterUpdater.new(screen: screen, window: self, token_log: token_log, names: model_names)
    @listener = @view.listener
  end

  # @return [Shared::ConversationTextView] the transcript pane; exposed for
  #   tests, production reaches it through {#listener}.
  attr_reader :view

  # The footer-chrome updater, which also duck-types as an agent listener
  # ({Shared::StatusFooterUpdater#on_event}) to re-point its model name on a
  # switch — fold it into the agent's +ListenerList+ alongside {#listener}.
  # The coding / computer shells also bind their {Code::PlanModeListener} to it.
  #
  # @return [Shared::StatusFooterUpdater]
  attr_reader :status_footer_updater

  # @return [Shared::ConversationTextView::Listener] the transcript listener.
  attr_reader :listener

  # Hand the footer the agent's mid-turn input queue so it can render the
  # "N queued" segment.
  #
  # @param interloper [Pikuri::Agent::Control::Interloper, nil]
  # @return [void]
  def interloper=(interloper)
    @status_footer_updater.interloper = interloper
  end

  # Seed the footer's model-name segment with the boot model (a display name
  # or a transport to resolve — see {Shared::StatusFooterUpdater#current_model=});
  # the footer's own {Shared::StatusFooterUpdater#on_event} takes over on
  # later switches once it's in the +ListenerList+.
  #
  # @param model [String, Pikuri::Agent::ChatTransport, nil]
  # @return [void]
  def current_model=(model)
    @status_footer_updater.current_model = model
  end

  # Start the footer's mid-turn spinner.
  #
  # @return [void]
  def start_animation = @status_footer_updater.start_animation

  # Stop the footer's mid-turn spinner, settling it to idle.
  #
  # @return [void]
  def stop_animation = @status_footer_updater.stop_animation

  # Append a one-line, error-themed turn-failure notice to the transcript.
  # Safe to call from the agent worker thread; marshals its own append onto
  # the event-loop thread.
  #
  # @param exception [StandardError] the caught library exception.
  # @return [void]
  def render_turn_error(exception)
    screen.event_queue.submit do
      @view.add_line(screen.theme.error("! #{exception.class}: #{exception.message}"))
    end
  end
end
