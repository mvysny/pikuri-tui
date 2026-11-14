# frozen_string_literal: true

# One selectable entry in the model-switch picker: a human-readable {#name}
# paired with the {Pikuri::Agent::ChatTransport} that selecting it hands to
# +Pikuri::Agent#run_loop+'s +transport:+.
#
#   choice = Shared::Model::Choice.from_llm(config_llm)  # one per [[llm]]
#   choice.name       # → "Local Qwen 3.6", shown in the picker and status rule
#   choice.transport  # → the transport a switch to this entry uses
#
# The transport is opaque to the UI — a pick hands it verbatim to the
# conversation's model switch — so this value object carries no behavior, only
# the pairing.
#
# @!attribute [r] name
#   @return [String] the connection's display name (e.g. +"Local Qwen 3.6"+),
#     shown in the picker and (after a switch lands) in the status rule.
# @!attribute [r] transport
#   @return [Pikuri::Agent::ChatTransport] the transport selecting this
#     entry switches to.
Shared::Model::Choice = Data.define(:name, :transport) do
  # The identity key that distinguishes one connection from another, derived
  # from a bare {Pikuri::Agent::ChatTransport} — our own {#transport}, or the
  # +to:+ one a landed {Pikuri::Agent::Event::ModelSwitched} carries.
  #
  # +name+ is the truly-unique key ({Config} enforces it), but it is not
  # recoverable from a transport (the switch event carries no name), so this
  # triple is the identity the transport-only paths can actually match. Each
  # third answers a pair of +[[llm]]+ entries that differ in nothing else:
  #
  #   model      # "Local Qwen 3.6" / "mavi-fw Qwen 3.6" — one model, two boxes
  #   api_base   # a second account on one provider
  #   params     # the titler recipe: one model on one box, reasoning off
  #
  # Drop one and that pair collapses onto a single key, which reads as a
  # duplicate connection: two active markers in the picker, one name for both.
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
  # server the conversation's +/props+ probe can't reach) rides the transport
  # too, so it is honored per-model across a model switch; +nil+ defers to that
  # probe. So do its {Config::Llm#params} — handed over
  # with the file's own string keys, because +ChatTransport+ symbolizes them
  # itself, and a table symbolized twice is no better than once.
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
