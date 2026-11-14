# frozen_string_literal: true

require 'spec_helper'

# Specs for the [[server]] max_concurrent_requests → Pikuri::Conversations::Throttle wiring.
# The registry is process-global; spec_helper resets it after every example.
describe Shared::RequestPermits do
  def server(id, url, max)
    Shared::Config::Server.new(id: id, url: url, api_key: nil, max_concurrent_requests: max)
  end

  it 'sizes a server that states a ceiling' do
    described_class.install([server('local', 'http://localhost:8080', 2)])
    assert_equal 2, Pikuri::Conversations::Throttle.for('http://localhost:8080').permits
  end

  # Omitted means "let the /props probe decide", so the server must stay
  # *unknown* — recording it would suppress the probe that sizes it.
  it 'leaves a server that states none unsized' do
    described_class.install([server('local', 'http://localhost:8080', nil)])
    refute Pikuri::Conversations::Throttle.sized?('http://localhost:8080')
  end

  # The [[llm]] server is the [[server]] url after resolution, and pikuri
  # normalizes both the transport's base and the registry key the same way —
  # so a /v1 spelling difference cannot leave the throttle keyed elsewhere.
  it 'keys a /v1 url the same server the transport dials' do
    described_class.install([server('grok', 'https://api.x.ai/v1', 4)])
    assert_equal 4, Pikuri::Conversations::Throttle.for('https://api.x.ai').permits
  end

  it 'logs each server it sized' do
    out = capture_log { described_class.install([server('grok', 'https://api.x.ai/v1', 4)]) }
    assert_includes out, 'grok at most 4 concurrent request(s) → https://api.x.ai/v1'
  end

  it 'says nothing about a server it left to the probe' do
    out = capture_log { described_class.install([server('local', 'http://x', nil)]) }
    refute_includes out, 'http://x'
  end
end
