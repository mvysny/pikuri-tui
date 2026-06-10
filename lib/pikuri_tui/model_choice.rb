# frozen_string_literal: true

module PikuriTui
  # One selectable entry in the model-switch picker: a human-readable
  # {#name} paired with the {Pikuri::Agent::ChatTransport} that selecting
  # it hands to +Pikuri::Agent#run_loop+'s +transport:+. Built by the bins
  # from {Config#llms} (one per +[[llm]]+ connection) and handed to the
  # shell's +App+ as its +models:+ list.
  #
  # The transport is opaque to the UI — the App stashes it as the
  # "pending" transport on selection and forwards it verbatim to the next
  # turn — so this value object carries no behavior, only the pairing.
  #
  # @!attribute [r] name
  #   @return [String] the connection's display name (e.g. +"Local Qwen 3.6"+),
  #     shown in the picker and (after a switch lands) in the footer.
  # @!attribute [r] transport
  #   @return [Pikuri::Agent::ChatTransport] the transport selecting this
  #     entry switches to.
  ModelChoice = Data.define(:name, :transport)
end
