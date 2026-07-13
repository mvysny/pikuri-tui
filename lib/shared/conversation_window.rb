# frozen_string_literal: true

require 'tuile'

# The conversation transcript as one cohesive component, shared by all
# three shells: a {Tuile::Component::Window} that frames a
# {Shared::ConversationTextView} (the scrolling transcript pane, which owns
# its own {Shared::ConversationTextView::Listener}), carries a
# {Shared::StatusFooterUpdater} footer, and builds the {Shared::StatusFooterUpdater::ModelListener} that
# keeps the footer's model name in step with a landed +run_loop+ switch.
#
# This is a "domain component" in the sense of AGENTS.md's "Design with
# components (COP)" rule: its whole responsibility *is* showing a
# +Pikuri::Agent+ conversation and keeping itself current, so it owns its
# +Pikuri::*+ wiring (its pane's transcript listener + the footer's model
# listener) rather than having each +App+ hand-assemble a bare +Window+, a
# loose +TextView+, and two dangling listeners around it. Folding that
# cluster in here is what collapses the conversation-pane wiring that was
# otherwise triplicated across {Chat::App}, {Code::App}, and {Os::App}.
#
# == The listener seam
#
# The transcript pane builds its {Shared::ConversationTextView::Listener} and
# this window builds the {Shared::StatusFooterUpdater::ModelListener}, both at construction —
# before the agent exists — and both are exposed ({#listener} /
# {#model_listener}) for the host to fold into the agent's +ListenerList+.
# The host owns that final composition because the agent needs more
# listeners than these two (the +TokenLog+, and in the coding / OS shells a
# {Code::TaskListener} / {Code::PlanModeListener}). The plan-mode badge in
# particular is driven by a listener the *shell* builds against this window's
# {#status_footer_updater} — the footer exposes +plan_active=+, but the
# +Code::PlanModeListener+ that feeds it is a +:code+-group concern the chat
# shell never loads, so it stays out of this shared component. The two footer
# values the host can only supply once the agent is built — the mid-turn
# {Pikuri::Agent::Control::Interloper} and the boot model's display name —
# are forwarded through {#interloper=} / {#current_model=}.
#
# == Threading
#
# The listeners self-marshal their UI mutations onto the event-loop thread
# (see {Shared::ConversationTextView::Listener} / {Shared::StatusFooterUpdater::ModelListener}).
# {#start_animation} / {#stop_animation} forward to {Shared::StatusFooterUpdater} and
# so must be called on the UI thread. {#render_turn_error} is the one method
# called from the agent worker thread; it marshals its own append via the
# screen's event queue.
class Shared::ConversationWindow < Tuile::Component::Window
  # @param token_log [Pikuri::Agent::Listener::TokenLog] the main agent's
  #   token log, fed into the {Shared::StatusFooterUpdater} footer. The host must
  #   wire the *same* instance into the agent's +ListenerList+.
  # @param title [String] the window's border caption. Defaults to
  #   +'Conversation'+ (the coding shell passes its project root, the OS
  #   shell its host label).
  # @param markdown [Boolean] forwarded to {Shared::ConversationTextView}'s
  #   +markdown:+ flag (default +true+).
  # @param tool_formatters [Hash{String => Object}] forwarded to
  #   {Shared::ConversationTextView}'s +tool_formatters:+ (the per-tool diff
  #   formatters the coding / OS shells wire for +edit+ / +write+).
  #   Defaults to +{}+ — the chat shell registers none.
  # @param model_names [Hash{Array(String, String) => String}]
  #   {Shared::Model::Choice.key} → display name, forwarded to
  #   {Shared::StatusFooterUpdater::ModelListener}'s +names:+. Defaults to +{}+.
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
    @status_footer_updater = Shared::StatusFooterUpdater.new(screen: screen, window: self, token_log: token_log)
    @listener = @view.listener
    @model_listener = Shared::StatusFooterUpdater::ModelListener.new(footer: @status_footer_updater, screen: screen, names: model_names)
  end

  # @return [Shared::ConversationTextView] the conversation transcript pane.
  #   Exposed primarily for tests; production code reaches it through the
  #   {#listener}.
  attr_reader :view

  # @return [Shared::StatusFooterUpdater] the footer-chrome updater. Named
  #   +status_footer_updater+ rather than +footer+ so it doesn't shadow
  #   {Tuile::Component::Window#footer} (which stays +nil+ — the status is
  #   border chrome via +footer_text+, not a footer-slot component). The
  #   coding / OS shells bind their {Code::PlanModeListener} to this.
  attr_reader :status_footer_updater

  # @return [Shared::ConversationTextView::Listener] the transcript listener;
  #   the host includes it in the agent's +ListenerList+.
  attr_reader :listener

  # @return [Shared::StatusFooterUpdater::ModelListener] the footer model-name listener; the
  #   host includes it in the agent's +ListenerList+.
  attr_reader :model_listener

  # Hand the footer the agent's mid-turn input queue so it can render the
  # "N queued" segment. Set once by the host after the agent is built.
  #
  # @param interloper [Pikuri::Agent::Control::Interloper, nil]
  # @return [void]
  def interloper=(interloper)
    @status_footer_updater.interloper = interloper
  end

  # Seed / update the footer's model-name segment. The host sets the boot
  # model once after the agent is built; {Shared::StatusFooterUpdater::ModelListener} takes
  # over on every later switch.
  #
  # @param name [String, nil]
  # @return [void]
  def current_model=(name)
    @status_footer_updater.current_model = name
  end

  # Start the footer's mid-turn spinner. Must be called on the UI thread.
  #
  # @return [void]
  def start_animation = @status_footer_updater.start_animation

  # Stop the footer's mid-turn spinner, settling it back to idle. Must be
  # called on the UI thread.
  #
  # @return [void]
  def stop_animation = @status_footer_updater.stop_animation

  # Append a one-line, error-themed turn-failure notice to the transcript
  # so the user sees a turn ended in failure without opening the log
  # popup. Called from the agent worker thread ({App#start_turn}'s
  # rescue), so it marshals the append onto the event-loop thread itself.
  #
  # @param exception [StandardError] the caught library exception.
  # @return [void]
  def render_turn_error(exception)
    screen.event_queue.submit do
      @view.add_line(screen.theme.error("! #{exception.class}: #{exception.message}"))
    end
  end
end
