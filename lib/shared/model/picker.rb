# frozen_string_literal: true

require 'tuile'

# The leader-menu model picker, shared by all three shells: the
# configured-connection catalog, the pending-switch slot, and the
# +Tuile::Component::PickerWindow+ popup that switches model mid-session.
#
#   picker = Shared::Model::Picker.new(models: choices)
#   picker.multiple?                       # gate the leader-menu "m" entry
#   picker.open(current: agent.transport)  # popup; a pick becomes pending
#   picker.take_pending                    # App#start_turn drains it into run_loop
#
# == What it owns (and what it deliberately doesn't)
#
# It owns the {Shared::Model::Choice} list, the {Shared::Model::Choice.key} → display-name map,
# and the *pending* transport (a pick not yet applied). It does NOT own the
# *current* model — that authority stays with pikuri
# (+Pikuri::Agent#transport+) and the footer (moved on-land by
# {Shared::StatusFooterUpdater::ModelListener}), so a failed switch never advertises a model it never
# reached. The picker only records the user's request; +App#start_turn+
# drains it via {#take_pending} and hands it to the next +run_loop+, and the
# footer moves only once the switch lands. This is why {#open} takes the
# current transport as an argument rather than holding an +Pikuri::Agent+
# reference: the picker is a catalog + a request slot, not a source of
# truth.
#
# UI-thread-confined.
class Shared::Model::Picker
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

  # @return [Hash{Array(String, String) => String}] the {Shared::Model::Choice.key}
  #   ([model, api_base]) → display-name map, for wiring into
  #   {Shared::StatusFooterUpdater::ModelListener}'s +names:+ so a landed
  #   {Pikuri::Agent::Event::ModelSwitched} resolves to a friendly name.
  attr_reader :names

  # @return [Boolean] true when there is more than one connection to pick
  #   between — the gate the shells use to decide whether to register the
  #   leader-menu +m+ entry (so the menu never offers a no-op pick).
  def multiple? = @models.size > 1

  # Resolve a transport to its friendly connection name, falling back to
  # the raw model id when the +[model, api_base]+ pair isn't in the
  # catalog. Used to seed the footer with the boot model's name at
  # construction (the {Shared::StatusFooterUpdater::ModelListener} takes over on every later switch).
  #
  # @param transport [Pikuri::Agent::ChatTransport] the transport to name
  #   (typically the agent's boot transport).
  # @return [String]
  def display_name(transport)
    @names.fetch(Shared::Model::Choice.key(transport), transport.model)
  end

  # Open the picker popup: one entry per configured connection, the active
  # one (matched by {Shared::Model::Choice.key} — [model, api_base], so two
  # connections sharing a model id on different servers don't both flag)
  # marked with a +●+. Picking stashes that connection's transport as the
  # pending switch, applied at the top of the next +run_loop+ (see
  # {#take_pending}); the footer moves only once the switch lands. ESC /
  # +q+ dismiss without changing anything.
  #
  # Hotkeys cover the first nine entries (+PickerWindow+ keys are single
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
    Tuile::Component::PickerWindow.open(CAPTION, options) do |key|
      choice = @models[key.to_i - 1]
      @pending = choice.transport if choice
    end
  end

  # Return the pending switched-to transport and clear it, so a pick is
  # applied at most once. Called by +App#start_turn+ on the UI thread
  # before spawning the agent worker.
  #
  # @return [Pikuri::Agent::ChatTransport, nil] the pending transport, or
  #   +nil+ when no switch is pending.
  def take_pending
    pending = @pending
    @pending = nil
    pending
  end
end
