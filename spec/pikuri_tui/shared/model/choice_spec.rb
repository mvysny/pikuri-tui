# frozen_string_literal: true

require 'spec_helper'

# Specs for the wiring-layer factory that turns a Pikuri-free Config::Llm
# connection into a name + ChatTransport pairing. This is the one place the
# seam between Config's value objects and Pikuri's transport is crossed.
describe Shared::Model::Choice do
  # Build a Config::Llm with sensible defaults, overridable per example.
  def llm(name: 'Local', server: 'http://localhost:8080', model: 'qwen', api_key: nil, context_window: nil)
    Shared::Config::Llm.new(name: name, server: server, model: model, api_key: api_key,
                               context_window: context_window)
  end

  describe '.from_llm' do
    it 'carries the connection name and model onto the transport' do
      choice = described_class.from_llm(llm(name: 'Local Qwen', model: 'qwen3'))
      assert_equal 'Local Qwen', choice.name
      assert_equal 'qwen3', choice.transport.model
      assert_equal :openai, choice.transport.provider
      assert choice.transport.assume_model_exists
    end

    it 'normalizes the server into a single /v1 base' do
      assert_equal 'http://localhost:8080/v1', described_class.from_llm(llm(server: 'http://localhost:8080')).transport.api_base
      assert_equal 'https://api.x.ai/v1', described_class.from_llm(llm(server: 'https://api.x.ai/v1')).transport.api_base
      assert_equal 'https://api.x.ai/v1', described_class.from_llm(llm(server: 'https://api.x.ai/v1/')).transport.api_base
    end

    it 'passes a configured key through verbatim' do
      assert_equal 'sk-123', described_class.from_llm(llm(api_key: 'sk-123')).transport.api_key
    end

    it 'falls back to "not-needed" when the key is nil or blank' do
      assert_equal 'not-needed', described_class.from_llm(llm(api_key: nil)).transport.api_key
      assert_equal 'not-needed', described_class.from_llm(llm(api_key: '  ')).transport.api_key
    end

    it 'carries an explicit context_window onto the transport' do
      assert_equal 2_000_000, described_class.from_llm(llm(context_window: 2_000_000)).transport.context_window
    end

    it 'leaves context_window nil so pikuri auto-detects' do
      assert_nil described_class.from_llm(llm(context_window: nil)).transport.context_window
    end
  end

  describe '.key / #key' do
    it 'keys on [model, api_base], so same-model-different-server connections differ' do
      local  = described_class.from_llm(llm(model: 'qwen3', server: 'http://localhost:8080'))
      remote = described_class.from_llm(llm(model: 'qwen3', server: 'http://mavi-fw:8080'))

      assert_equal ['qwen3', 'http://localhost:8080/v1'], local.key
      assert_equal ['qwen3', 'http://mavi-fw:8080/v1'], remote.key
      refute_equal local.key, remote.key
    end

    it 'derives the same key from a bare transport as from a choice' do
      choice = described_class.from_llm(llm(model: 'qwen3', server: 'http://localhost:8080'))
      assert_equal choice.key, described_class.key(choice.transport)
    end
  end
end
