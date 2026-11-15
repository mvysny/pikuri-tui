# frozen_string_literal: true

require 'pikuri-core'
require 'pikuri-code'

module Code
  # Keeps the status rule's plan-mode badge in step with
  # the agent's shared {Pikuri::Code::PlanMode} flag. A
  # {Pikuri::Agent::Listener::Base} subclass that consumes the
  # {Pikuri::Code::PlanModeChanged} event +Pikuri::Code::Extension+
  # re-emits on every real transition, and pushes the new posture onto
  # the status rule ({Shared::StatusRuleLabel#plan_active=}).
  #
  # The companion to {Shared::StatusRuleLabel} /
  # {TaskListPane::Listener}: same worker-thread-to-UI-thread marshaling, one event
  # class. It lives in +Code+ rather than {Shared} because plan mode is a
  # +:code+-group concern — the event is a +:code+-group constant the chat
  # shell never loads (which is also why the chat shell's badge stays
  # hidden: it never wires this listener).
  #
  # == Why the event, not the control
  #
  # The badge is driven off the *event* rather than the host reading the
  # {Pikuri::Code::PlanMode} flag directly, so a
  # **model**-initiated entry (the +enter_plan_mode+ tool) lights up the
  # status rule exactly like the leader menu's +p+ toggle does — both flips fire the
  # flag's +on_change+, which +Code::Extension+ bridges onto this
  # event stream. The status rule therefore reflects the authoritative flag,
  # never an inference about who toggled it.
  #
  # {#on_event} fires on whatever thread flipped the flag — the agent's
  # worker thread for a model flip, the UI thread for a +p+ menu toggle — so
  # it marshals the status-rule mutation onto the event-loop thread via
  # +screen.event_queue.submit+ (a +submit+ from the UI thread simply
  # enqueues, so the host-flip path is safe too).
  class PlanModeListener < Pikuri::Agent::Listener::Base
    # @param status_rule [#plan_active=] the status rule to
    #   update (a {Shared::StatusRuleLabel}). Lifetime is owned by the host +App+.
    # @param screen [Tuile::Screen] the screen whose +event_queue+
    #   marshals the update back onto the event-loop thread. Passed
    #   explicitly (not the singleton) so tests can inject a
    #   {Tuile::FakeScreen}.
    def initialize(status_rule:, screen:)
      super()
      @status_rule = status_rule
      @screen = screen
    end

    # Pushes the new plan-mode posture onto the status rule; ignores every
    # other event. Called from the flipping thread — the status-rule mutation
    # is marshaled onto the event-loop thread.
    #
    # @param event [Data] any agent event; only
    #   {Pikuri::Code::PlanModeChanged} is acted on.
    # @return [void]
    def on_event(event)
      return unless event.is_a?(Pikuri::Code::PlanModeChanged)

      active = event.active
      @screen.event_queue.submit { @status_rule.plan_active = active }
    end

    # @return [String] short label used by +Pikuri::Agent#to_s+ when this
    #   listener is in its +ListenerList+.
    def to_s = 'PlanModeListener'
  end
end
