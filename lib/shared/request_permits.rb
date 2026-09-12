# frozen_string_literal: true

# Installs each +[[server]] max_concurrent_requests+ into pikuri's
# process-wide request throttle, logging a line per server it sized:
#
#   Shared::RequestPermits.install(config.servers)
#   # permits: grok at most 4 concurrent request(s) → https://api.x.ai/v1
#
# A server naming no ceiling is left alone, so pikuri's +/props+ probe sizes it
# from the box's own +total_slots+. Don't add a spelling for "explicitly
# unlimited": it suppresses that probe, and the only server worth typing it
# against is a cloud endpoint the probe already answers for.
#
# == Implementation details
#
# +.limit+ wins by *decision*, not by ordering: +ServerPermits+ marks an
# explicit size and refuses to let the probe's +.default+ overwrite it, so this
# may run before or after the agent is built. Its scope is one process, not the
# machine — three shells against one llama.cpp each get the full allowance.
#
# The ceiling rations nothing in a pikuri-tui process, and this is still not
# dead wiring. Nothing here puts two requests in flight (+tool_concurrency+ is
# off, +SubAgentTool+ runs its child's loop inline, {Shared::AgentSession}
# takes one turn at a time), so the live effect is narrower: a sized server
# counts as *known* and skips the boot +/props+ probe (pikuri's
# +design/decisions.md+, the +probe_when_unknown+ entry). The ceiling itself
# is installed for the schema's other consumer, pikuri-web, which does serve
# concurrent conversations — and for the day this one does.
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
