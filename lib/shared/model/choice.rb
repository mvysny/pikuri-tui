# frozen_string_literal: true

# One selectable entry in the model-switch picker: a human-readable {#name}
# paired with the {Pikuri::Agent::ChatTransport} that selecting it hands to
# +Pikuri::Agent#run_loop+'s +transport:+.
#
#   choice = Shared::Model::Choice.from_llm(config_llm)  # one per [[llm]]
#   choice.name       # → "Local Qwen 3.6", shown in the picker and status rule
#   choice.transport  # → the transport a switch to this entry uses
#
# The transport is opaque to the UI — the App stashes it as the "pending"
# transport on selection and forwards it verbatim to the next turn — so
# this value object carries no behavior, only the pairing.
#
# @!attribute [r] name
#   @return [String] the connection's display name (e.g. +"Local Qwen 3.6"+),
#     shown in the picker and (after a switch lands) in the status rule.
# @!attribute [r] transport
#   @return [Pikuri::Agent::ChatTransport] the transport selecting this
#     entry switches to.
Shared::Model::Choice = Data.define(:name, :transport) do
  # The identity key that distinguishes one connection from another,
  # derived from a {Pikuri::Agent::ChatTransport}. Used by the shells' model
  # picker (its active-entry marker) and status rule (id → display-name
  # resolution), off both our own {#transport} and the +to:+ transport a
  # landed {Pikuri::Agent::Event::ModelSwitched} carries.
  #
  # +name+ is the truly-unique key ({Config} enforces it), but it is not
  # recoverable from a transport (the switch event carries no name), so this
  # triple is the identity the transport-only paths can actually match. Each
  # third of it earns its place from a pair of +[[llm]]+ entries that differ
  # in nothing else:
  #
  #   model      # "Local Qwen 3.6" / "mavi-fw Qwen 3.6" — one model, two boxes
  #   api_base   # a second account on one provider
  #   params     # the titler recipe: one model on one box, reasoning off
  #
  # Drop any one and both entries of that pair collapse onto one key — the
  # picker flags them both active, and the name map keeps whichever was
  # declared last.
  #
  # @param transport [Pikuri::Agent::ChatTransport] the transport to key.
  # @return [Array(String, String, Hash)] the
  #   +[model, api_base, params]+ triple.
  def self.key(transport) = [transport.model, transport.api_base, transport.params]

  # @return [Array(String, String, Hash)] this choice's identity key
  #   (see {.key}).
  def key = self.class.key(transport)

  # Build a choice from one {Config::Llm} connection. The connection
  # (api_base / api_key) rides the {Pikuri::Agent::ChatTransport}'s own
  # per-chat +RubyLLM::Context+ — pikuri needs no process-global
  # +RubyLLM.configure+ — and +from_openai_server+ normalizes the
  # trailing +/v1+. A connection that omits its key falls back to
  # +"not-needed"+ (fine for a local llama.cpp). The key is read straight
  # from the config file, never the environment, which pikuri would
  # inherit into every subprocess it spawns (sandboxed bash, stdio MCP).
  #
  # This is the wiring-layer translation of a +Pikuri::*+-free
  # {Config::Llm} value object into a transport — {Config} itself stays
  # free of every +Pikuri::*+ reference (see its "Pikuri seam" note), so
  # the seam crossing lives here, in the Pikuri-aware adapter.
  #
  # The connection's {Config::Llm#context_window} (an explicit cap for a
  # server pikuri's +/props+ probe can't reach) rides the transport too,
  # so it is honored per-model across a model switch; +nil+ defers to
  # pikuri's auto-detection. So do its {Config::Llm#params}, which pikuri
  # deep-merges into every chat completion on this connection — handed over
  # with the file's own string keys, since +ChatTransport+ symbolizes them
  # itself.
  #
  # @param llm [Config::Llm] one +[[llm]]+ connection from {Config#llms}.
  # @return [Shared::Model::Choice] the display-name / transport pairing.
  def self.from_llm(llm)
    key = llm.api_key
    key = 'not-needed' if key.nil? || key.strip.empty?
    new(
      name: llm.name,
      transport: Pikuri::Agent::ChatTransport.from_openai_server(
        server: llm.server,
        model: llm.model,
        api_key: key,
        context_window: llm.context_window,
        params: llm.params
      )
    )
  end
end
