# frozen_string_literal: true

require 'pikuri-core'

# Keeps the conversation-window footer's model name in step with the
# agent's actual model. A {Pikuri::Agent::Listener::Base} subclass that
# consumes the {Pikuri::Agent::Event::ModelSwitched} the agent emits from
# the top of +run_loop+ when a +transport:+ switch lands, and pushes the
# new model's display name onto the footer.
#
# The companion to {Shared::ConversationTextView::Listener} / {Code::TaskListener}: same
# worker-thread-to-UI-thread marshaling, the smallest possible slice of
# the event stream (one event class). Shared by all three shells (the
# footer model name is a +current_model=+ setter {Shared::StatusLabel} exposes),
# so it lives in the {Shared} namespace rather than in any shell's
# namespace.
#
# == Footer-only, by decision
#
# The switch is surfaced *only* in the footer — never echoed into the
# conversation transcript — so this listener owns the whole UI reaction
# to a switch and {Shared::ConversationTextView::Listener} ignores +ModelSwitched+ entirely. The
# footer reflects the model the agent is actually on (it updates when the
# switch *lands*, not when the user picks), so it can never advertise a
# model a failed switch never reached.
#
# == Names
#
# {Pikuri::Agent::Event::ModelSwitched} carries the raw
# {Pikuri::Agent::ChatTransport} (model *id*, which is often long and
# ugly — +"unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M"+). The +names+ map
# ({Shared::Model::Choice.key} → {Shared::Model::Choice#name}, built by the App from its
# +models:+ list) resolves it to the friendly connection name; a
# transport with no entry (e.g. a model reached some other way) falls
# back to the model id itself. The map is keyed on the +[model, api_base]+
# pair, not the model id alone: two connections can run the same model on
# different servers, so the id alone can't tell +"Local Qwen 3.6"+ from
# +"mavi-fw Qwen 3.6"+ (see {Shared::Model::Choice.key}).
#
# == Threading
#
# {#on_event} fires on the agent's worker thread; it marshals the footer
# mutation onto the event-loop thread via +screen.event_queue.submit+,
# the same rule {Code::TaskListener} follows.
class Shared::Model::Listener < Pikuri::Agent::Listener::Base
  # @param footer [#current_model=] the conversation-window footer to
  #   update (a {Shared::StatusLabel}). Lifetime is owned by the host +App+.
  # @param screen [Tuile::Screen] the screen whose +event_queue+ marshals
  #   the update back from the worker thread. Passed explicitly (not the
  #   singleton) so tests can inject a {Tuile::FakeScreen}.
  # @param names [Hash{Array(String, String) => String}] {Shared::Model::Choice.key}
  #   ([model, api_base]) → display name; transports absent from the map
  #   render as their raw model id.
  def initialize(footer:, screen:, names: {})
    super()
    @footer = footer
    @screen = screen
    @names = names
  end

  # Pushes the switched-to model's display name onto the footer; ignores
  # every other event. Called from the agent's worker thread — the footer
  # mutation is marshaled onto the event-loop thread.
  #
  # @param event [Pikuri::Agent::Event::Base] any agent event; only
  #   {Pikuri::Agent::Event::ModelSwitched} is acted on.
  # @return [void]
  def on_event(event)
    return unless event.is_a?(Pikuri::Agent::Event::ModelSwitched)

    name = display_name(event.to)
    @screen.event_queue.submit { @footer.current_model = name }
  end

  # @return [String] short label used by +Pikuri::Agent#to_s+ when this
  #   listener is in its +ListenerList+.
  def to_s = 'Shared::Model::Listener'

  # Resolve a transport to its friendly connection name, falling back to
  # the raw model id when the +[model, api_base]+ pair isn't in the map.
  #
  # @param transport [Pikuri::Agent::ChatTransport] the landed transport
  #   (typically a {Pikuri::Agent::Event::ModelSwitched}'s +to:+).
  # @return [String]
  def display_name(transport)
    @names.fetch(Shared::Model::Choice.key(transport), transport.model)
  end
end
