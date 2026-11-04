# frozen_string_literal: true

require 'tuile'

# The leader-menu model picker, shared by all three shells: the
# configured-connection catalog, the pending-switch slot, and the
# +Tuile::Component::PickerDialog+ that switches model mid-session.
#
#   picker = Shared::Model::Picker.new(models: choices)
#   picker.multiple?                       # gate the leader-menu "m" entry
#   picker.open(current: agent.transport)  # popup; a pick becomes pending
#   picker.take_pending                    # the session drains it into run_loop
#
# == What it owns (and what it deliberately doesn't)
#
# It owns the {Shared::Model::Choice} list, the {Shared::Model::Choice.key} → display-name map,
# and the *pending* transport (a pick not yet applied). It does NOT own the
# *current* model — that authority stays with pikuri
# (+Pikuri::Agent#transport+) and the status rule (moved on-land by
# {Shared::StatusRuleLabel}), so a failed switch never advertises a model it never
# reached. The picker only records the user's request; the
# {Shared::AgentSession} that owns the turn drains it via {#take_pending} at
# the top of each turn and hands it to the next +run_loop+, and the
# status rule moves only once the switch lands. This is why {#open} takes the
# current transport as an argument rather than holding an +Pikuri::Agent+
# reference: the picker is a catalog + a request slot, not a source of
# truth.
#
# == Implementation details
#
# A pick asks the server which input kinds the model takes
# (+ChatTransport#with_detected_modalities+), on a worker. When the answer
# comes back, the detected transport replaces the pending one, so the image
# check ({Shared::AgentSession#attachment_refusal}) can answer for the model
# about to run. A turn that starts before the answer takes the undetected
# transport, and that turn's own probe fills in the modalities. Picking the
# model already running clears the pending switch. Its transport may differ
# from the agent's only in detected +modalities+, and pikuri counts that as a
# switch.
#
# UI-thread-confined.
class Shared::Model::Picker
  # @return [Logger]
  LOG = Pikuri.logger_for('models')
  private_constant :LOG

  # @return [String] caption shown at the top of the picker popup.
  CAPTION = 'Switch model'

  # @param models [Array<Shared::Model::Choice>] the configured connections, in
  #   display order (the first is the boot connection). May be empty
  #   (single-connection or test hosts) — {#multiple?} then reports +false+
  #   and the shells omit the leader-menu +m+ entry.
  def initialize(models:)
    @models = models
    @names = models.to_h { |choice| [choice.key, choice.name] }
    @pending = nil
  end

  # @return [Hash{Array(String, String, Hash) => String}] the
  #   {Shared::Model::Choice.key} → display-name map, for wiring into
  #   {Shared::StatusRuleLabel}'s +names:+ so a transport it's handed
  #   (the boot model, or a landed {Pikuri::Agent::Event::ModelSwitched})
  #   resolves to a friendly name.
  attr_reader :names

  # @return [Pikuri::Agent::ChatTransport, nil] the pick the next turn will
  #   switch to, without taking it; its +modalities+ are filled in once the
  #   server answers.
  attr_reader :pending

  # @return [Boolean] true when there is more than one connection to pick
  #   between — the gate the shells use to decide whether to register the
  #   leader-menu +m+ entry (so the menu never offers a no-op pick).
  def multiple? = @models.size > 1

  # Open the picker popup: one entry per configured connection, the active
  # one (matched by {Shared::Model::Choice.key}, so near-identical connections
  # don't both flag)
  # marked with a +●+. Picking stashes that connection's transport as the
  # pending switch, applied at the top of the next +run_loop+ (see
  # {#take_pending}); the status rule moves only once the switch lands.
  # Picking the active entry cancels a pending switch. ESC / +q+ dismiss
  # without changing anything.
  #
  # Hotkeys cover the first nine entries (+PickerDialog+ keys are single
  # characters); arrow-keys + Enter select any entry.
  #
  # @param current [Pikuri::Agent::ChatTransport] the agent's live
  #   transport, used to flag the active entry. Passed in (not held) so the
  #   picker owns no agent reference — see the class header.
  # @return [void]
  def open(current:)
    current_key = Shared::Model::Choice.key(current)
    options = @models.each_with_index.map do |choice, i|
      marker = choice.key == current_key ? '● ' : '  '
      [(i + 1).to_s, "#{marker}#{choice.name}"]
    end
    Tuile::Component::PickerDialog.new(CAPTION, options) do |key|
      choice = @models[key.to_i - 1]
      pick(choice, current_key) if choice
    end.open
  end

  # Return the pending switched-to transport and clear it, so a pick is
  # applied at most once. Called by {Shared::AgentSession} on the UI thread
  # before spawning the agent worker.
  #
  # @return [Pikuri::Agent::ChatTransport, nil] the pending transport, or
  #   +nil+ when no switch is pending.
  def take_pending
    pending = @pending
    @pending = nil
    pending
  end

  private

  # @param choice [Shared::Model::Choice] the picked entry.
  # @param current_key [Array(String, String, Hash)] the running model's
  #   {Shared::Model::Choice.key}.
  # @return [void]
  def pick(choice, current_key)
    if choice.key == current_key
      @pending = nil
      return
    end

    @pending = choice.transport
    detect_modalities(choice.transport) unless choice.transport.modalities
  end

  # Look up +transport+'s modalities on a worker, and make the detected copy
  # the pending switch if +transport+ is still the one pending.
  #
  # @param transport [Pikuri::Agent::ChatTransport]
  # @return [void]
  def detect_modalities(transport)
    queue = Tuile::Screen.instance.event_queue
    Thread.new do
      detected = transport.with_detected_modalities
      queue.submit { @pending = detected if @pending.equal?(transport) }
    rescue StandardError => e
      LOG.warn("modalities lookup for #{transport.model} failed: #{e.class}: #{e.message}")
    end
  end
end
