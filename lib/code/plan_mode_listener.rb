# frozen_string_literal: true

require 'pikuri-core'
require 'pikuri-code'

module Code
  # Keeps the conversation-window footer's plan-mode badge in step with
  # the agent's shared {Pikuri::Workspace::ReadOnly} flag. A
  # {Pikuri::Agent::Listener::Base} subclass that consumes the
  # {Pikuri::Code::PlanModeChanged} event +Pikuri::Code::Extension+
  # re-emits on every real transition, and pushes the new posture onto
  # the footer ({Shared::StatusFooterUpdater#plan_active=}).
  #
  # The companion to {Shared::Model::Listener} / {TaskListener}: same
  # worker-thread-to-UI-thread marshaling, the smallest possible slice of
  # the event stream (one event class). Coding/OS-shell-only — it lives in
  # +Code+ (not in the {Shared} namespace like
  # {Shared::Model::Listener}) because plan mode is a +:code+-group concern: the
  # event is a +:code+-group constant the chat shell never loads. The
  # shared {Shared::StatusFooterUpdater} exposes +plan_active=+ for every shell, but only
  # the coding and OS shells wire this listener to drive it; the chat
  # shell never sets it, so its badge stays hidden.
  #
  # == Why the event, not the control
  #
  # The badge is driven off the *event* rather than the host reading the
  # {Pikuri::Workspace::ReadOnly} flag directly, so a
  # **model**-initiated entry (the +enter_plan_mode+ tool) lights up the
  # footer exactly like the leader menu's +p+ toggle does — both flips fire the
  # flag's +on_change+, which +Code::Extension+ bridges onto this
  # event stream. The footer therefore reflects the authoritative flag,
  # never an inference about who toggled it.
  #
  # == Threading
  #
  # {#on_event} fires on whatever thread flipped the flag — the agent's
  # worker thread for a model flip, the UI thread for a +p+ menu toggle —
  # so it marshals the footer mutation onto the event-loop thread via
  # +screen.event_queue.submit+, the same rule {TaskListener} follows.
  # (+submit+ from the UI thread simply enqueues, so the host-flip path is
  # safe too.)
  class PlanModeListener < Pikuri::Agent::Listener::Base
    # @param footer [#plan_active=] the conversation-window footer to
    #   update (a {Shared::StatusFooterUpdater}). Lifetime is owned by the host +App+.
    # @param screen [Tuile::Screen] the screen whose +event_queue+
    #   marshals the update back onto the event-loop thread. Passed
    #   explicitly (not the singleton) so tests can inject a
    #   {Tuile::FakeScreen}.
    def initialize(footer:, screen:)
      super()
      @footer = footer
      @screen = screen
    end

    # Pushes the new plan-mode posture onto the footer; ignores every
    # other event. Called from the flipping thread — the footer mutation
    # is marshaled onto the event-loop thread.
    #
    # @param event [Pikuri::Agent::Event::Base] any agent event; only
    #   {Pikuri::Code::PlanModeChanged} is acted on.
    # @return [void]
    def on_event(event)
      return unless event.is_a?(Pikuri::Code::PlanModeChanged)

      active = event.active
      @screen.event_queue.submit { @footer.plan_active = active }
    end

    # @return [String] short label used by +Pikuri::Agent#to_s+ when this
    #   listener is in its +ListenerList+.
    def to_s = 'PlanModeListener'
  end
end
