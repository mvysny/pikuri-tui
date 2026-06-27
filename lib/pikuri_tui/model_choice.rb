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
  ModelChoice = Data.define(:name, :transport) do
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
    # pikuri's auto-detection.
    #
    # @param llm [Config::Llm] one +[[llm]]+ connection from {Config#llms}.
    # @return [ModelChoice] the display-name / transport pairing.
    def self.from_llm(llm)
      key = llm.api_key
      key = 'not-needed' if key.nil? || key.strip.empty?
      new(
        name: llm.name,
        transport: Pikuri::Agent::ChatTransport.from_openai_server(
          server: llm.server,
          model: llm.model,
          api_key: key,
          context_window: llm.context_window
        )
      )
    end
  end
end
