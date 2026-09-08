# frozen_string_literal: true

# Installs each +[[server]] max_concurrent_requests+ into pikuri's
# process-wide request throttle, and logs what it sized:
#
#   Shared::RequestPermits.install(config.servers)
#   # permits: grok at most 4 concurrent request(s) → https://api.x.ai/v1
#
# A server that states no ceiling is left alone, so pikuri's +/props+ probe
# sizes it from the box's own +total_slots+. There is deliberately no spelling
# for "explicitly unlimited": +ServerPermits.limit(url, nil)+ exists upstream
# and would suppress that probe, but the only server it could usefully be
# typed against is a cloud endpoint, where the probe costs one tolerated 404
# per process and answers correctly anyway.
#
# == Implementation details
#
# Two contracts a reader would otherwise re-derive from pikuri's source:
#
# - **+.limit+ wins by decision, not by ordering.** +ServerPermits+ marks an
#   explicit size and refuses to let the probe's +.default+ overwrite it, so
#   this may run before or after the agent is built.
# - **The scope is one process, not the machine.** Three shells open against
#   one llama.cpp each get the full allowance, so the ceiling this installs is
#   on *this* shell's fan-out. llama.cpp queues rather than failing, so
#   overshooting costs latency, not errors.
#
# And what the key buys *here*, honestly: nothing yet. One pikuri-tui process
# never has two requests in flight — ruby_llm's +tool_concurrency+ is off (see
# +Pikuri::Tool+'s "Sharing"), so a tool batch is sequential; +SubAgentTool+
# runs its child's whole loop inline on the tool thread; and
# {Shared::AgentSession} runs one turn at a time. So the semaphore never
# waits, and the one observable effect is that a sized server counts as known
# (+ServerPermits.sized?+) and skips the boot +/props+ probe — pikuri's
# +D_probe_when_unknown+. It is installed regardless because the schema is
# shared with pikuri-web, which serves concurrent conversations today, and
# because the day pikuri gains concurrency this is the wiring that already
# holds the ceiling.
module Shared::RequestPermits
  LOG = Pikuri.logger_for('permits')
  private_constant :LOG

  module_function

  # Size every server that asked to be sized; ignore the rest.
  #
  # An unreferenced +[[server]]+ is installed too — rationing a server nobody
  # dials is a no-op, and cheaper than filtering by what the +[[llm]]+ list
  # happens to name.
  #
  # @param servers [Array<Shared::Config::Server>] the config's +[[server]]+
  #   definitions.
  # @return [void]
  def install(servers)
    servers.each do |server|
      permits = server.max_concurrent_requests
      next if permits.nil?

      Pikuri::Agent::ServerPermits.limit(server.url, permits)
      LOG.info("#{server.id} at most #{permits} concurrent request(s) → #{server.url}")
    end
    nil
  end
end
