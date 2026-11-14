# frozen_string_literal: true

require 'tuile'
require 'pikuri-conversations'

# The leader-menu model picker, shared by all three shells: the
# configured-connection catalog and the +Tuile::Component::PickerDialog+ that
# switches a conversation's model mid-session.
#
#   picker = Shared::Model::Picker.new(models: choices)
#   picker.multiple?              # gate the leader-menu "m" entry
#   picker.open(session: session) # popup; a pick is the next turn's model
#
# The pick goes to +Pikuri::Conversations::Conversation#switch_model+, which
# holds it until the next turn starts; picking the model the conversation
# runs on undoes it. The status rule moves only once the switch lands
# (+ModelSwitched+), so a failed switch never advertises a model it never
# reached.
#
# == Implementation details
#
# A pick also asks the server, on a worker, which inputs the model takes
# (+Pikuri::Conversations::Probe.modalities+, which never loads a model), so an
# image is refused at submit for the model about to run, not by its turn.
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
  end

  # @return [Hash{Array(String, String, Hash) => String}] the
  #   {Shared::Model::Choice.key} → display-name map, for wiring into
  #   {Shared::StatusRuleLabel}'s +names:+ so a transport it's handed
  #   (the boot model, or a landed {Pikuri::Agent::Event::ModelSwitched})
  #   resolves to a friendly name.
  attr_reader :names

  # @return [Boolean] true when there is more than one connection to pick
  #   between — the gate the shells use to decide whether to register the
  #   leader-menu +m+ entry (so the menu never offers a no-op pick).
  def multiple? = @models.size > 1

  # Open the picker popup: one entry per configured connection, the one the
  # next turn will run on (matched by {Shared::Model::Choice.key}, so
  # near-identical connections don't both flag) marked with a +●+. ESC / +q+
  # dismiss without changing anything.
  #
  # Hotkeys cover the first nine entries (+PickerDialog+ keys are single
  # characters); arrow-keys + Enter select any entry.
  #
  # @param session [Pikuri::Conversations::Conversation] the conversation whose
  #   model the pick switches.
  # @return [void]
  def open(session:)
    next_key = Shared::Model::Choice.key(session.status.next_model)
    options = @models.each_with_index.map do |choice, i|
      marker = choice.key == next_key ? '● ' : '  '
      [(i + 1).to_s, "#{marker}#{choice.name}"]
    end
    Tuile::Component::PickerDialog.new(CAPTION, options) do |key|
      choice = @models[key.to_i - 1]
      pick(choice, session) if choice
    end.open
  end

  private

  # @param choice [Shared::Model::Choice] the picked entry.
  # @param session [Pikuri::Conversations::Conversation]
  # @return [void]
  def pick(choice, session)
    session.switch_model(choice.transport)
    learn_modalities(choice.transport) unless choice.transport.modalities
  end

  # Warm the probe's cache for +transport+ off the UI thread.
  #
  # @param transport [Pikuri::Agent::ChatTransport]
  # @return [void]
  def learn_modalities(transport)
    Thread.new do
      Pikuri::Conversations::Probe.modalities(transport)
    rescue StandardError => e
      LOG.warn("modalities lookup for #{transport.model} failed: #{e.class}: #{e.message}")
    end
  end
end
