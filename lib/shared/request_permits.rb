# frozen_string_literal: true

# Installs each +[[server]] max_concurrent_requests+ into the process-wide
# request throttle every conversation's requests pass through
# (+Pikuri::Conversations::Throttle+), logging a line per server it sized:
#
#   Shared::RequestPermits.install(config.servers)
#   # permits: grok at most 4 concurrent request(s) → https://api.x.ai/v1
#
# A server naming no ceiling is left alone, so the conversation's +/props+
# probe sizes it from the box's own +total_slots+. Don't add a spelling for
# "explicitly unlimited": it suppresses that probe, and the only server worth
# typing it against is a cloud endpoint the probe already answers for.
#
# == Implementation details
#
# +.limit+ wins by *decision*, not by ordering: the throttle marks an explicit
# size and refuses to let the probe's +.default+ overwrite it, so this may run
# before or after the conversation boots. Its scope is one process, not the
# machine — three shells against one llama.cpp each get the full allowance.
#
# The ceiling rations little in a pikuri-tui process — one conversation, one
# turn at a time, a sub-agent's loop inline — so the live effect is mostly
# narrower: a sized server whose model states its cap and modalities skips the
# per-turn +/props+ probe. The ceiling is installed for the schema's other
# consumer, pikuri-webui, which serves concurrent conversations, and for the
# day this one does.
module Shared::RequestPermits
  # @return [Logger]
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

      Pikuri::Conversations::Throttle.limit(server.url, permits)
      LOG.info("#{server.id} at most #{permits} concurrent request(s) → #{server.url}")
    end
    nil
  end
end
