# frozen_string_literal: true

RSpec.describe Shared::Markdown::CollectingBuffer do
  let(:buf) { described_class.new }

  context 'construction' do
    it 'is not finalized at construction' do
      refute buf.finalized?
    end

    it 'starts with an empty source' do
      assert_equal '', buf.source
    end
  end

  context '#append' do
    it 'accumulates into #source' do
      buf.append("one\n")
      buf.append('two')
      assert_equal "one\ntwo", buf.source
    end

    it 'collects the raw source, with no Markdown conversion' do
      buf.append("# heading\n\n**bold**")
      assert_equal "# heading\n\n**bold**", buf.source
    end

    it 'is a no-op on nil or empty content' do
      buf.append(nil)
      buf.append('')
      assert_equal '', buf.source
    end

    it 'raises if called after finalize' do
      buf.append('hello')
      buf.finalize('hello')
      assert_raises(RuntimeError) { buf.append(' world') }
    end

    it 'hands out a copy of the source, so a caller cannot grow it' do
      buf.append('collected')
      buf.source << ' and appended to'
      assert_equal 'collected', buf.source
    end
  end

  context '#finalize' do
    it 'sets finalized? to true' do
      buf.finalize('done')
      assert buf.finalized?
    end

    it 'raises on double-finalize' do
      buf.finalize('done')
      assert_raises(RuntimeError) { buf.finalize('done') }
    end

    it 'replaces the collected preview with the authoritative content' do
      buf.append('hello tehre') # typo
      buf.finalize('hello there')
      assert_equal 'hello there', buf.source
    end

    it 'works on a buffer that never received an append' do
      buf.finalize('just the final')
      assert_equal 'just the final', buf.source
    end
  end
end
