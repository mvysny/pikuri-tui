# frozen_string_literal: true

# The invariant "no second HTTP or LLM client in lib/ or bin/" as a test, which
# is where a rule about this project's own code belongs — the design/ tripwire
# checks the doc layer and nothing else. Require lines are the whole check: a
# client nobody requires is a client nobody calls.
RSpec.describe 'the HTTP and LLM transport' do
  it "is pikuri's alone — lib/ and bin/ require no client of their own" do
    # ruby_llm itself, the HTTP clients it and its neighbours are built on, and
    # the two vendor SDKs.
    clients = %w[ruby_llm faraday net/http httparty excon typhoeus rest-client openai anthropic]
    pattern = /^\s*require\s+['"](#{Regexp.union(clients)})/
    root = File.expand_path('..', __dir__)

    offenders = Dir.glob(%w[lib/**/*.rb bin/*], base: root).filter_map do |path|
      full = File.join(root, path)
      next unless File.file?(full)

      hits = File.readlines(full).grep(pattern)
      "#{path}: #{hits.map(&:strip).join(', ')}" unless hits.empty?
    end

    assert_empty offenders,
                 'pikuri owns the LLM transport; a retry, a timeout or a rescue added on this ' \
                 "side drifts from the one it already implements:\n  #{offenders.join("\n  ")}"
  end
end
