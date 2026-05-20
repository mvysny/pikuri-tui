# frozen_string_literal: true

RSpec.describe PikuriTui::PassthroughBuffer do
  let(:view) { Tuile::Component::TextView.new }
  let(:region) { view.create_region }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  def build(region: self.region)
    described_class.new(region: region)
  end

  context 'construction' do
    it 'is not finalized at construction' do
      buf = build
      refute buf.finalized?
    end

    it 'starts with an empty source' do
      buf = build
      assert_equal '', buf.source
    end

    it 'does not touch the region' do
      build
      assert region.empty?
    end
  end

  context '#append' do
    it 'is a no-op on nil content' do
      buf = build
      buf.append(nil)
      assert region.empty?
    end

    it 'is a no-op on empty content' do
      buf = build
      buf.append('')
      assert region.empty?
    end

    it 'passes the input through unchanged (no Markdown conversion)' do
      buf = build
      buf.append("# heading\n\n**bold** _italic_")
      assert_equal "# heading\n\n**bold** _italic_", region.text.to_s
    end

    it 'token-by-token feeding ends with the raw source in the region' do
      buf = build
      source = "first line\nsecond line\nthird line"
      source.chars.each { |c| buf.append(c) }
      assert_equal source, region.text.to_s
    end

    it 'multi-paragraph source after chunked feeding lands as-is' do
      buf = build
      source = "First paragraph.\n\nSecond paragraph.\n\nThird."
      source.chars.each_slice(3) { |chunk| buf.append(chunk.join) }
      assert_equal source, region.text.to_s
    end

    it 'extends the trailing line when no newline arrives' do
      buf = build
      buf.append('hel')
      buf.append('lo')
      assert_equal 'hello', region.text.to_s
    end

    it 'accumulates into #source' do
      buf = build
      buf.append("one\n")
      buf.append('two')
      assert_equal "one\ntwo", buf.source
    end

    it 'raises if called after finalize' do
      buf = build
      buf.append('hello')
      buf.finalize('hello')
      assert_raises(RuntimeError) { buf.append(' world') }
    end

    it 'leaves earlier regions untouched' do
      before_region = view.create_region
      before_region << 'untouched prefix'
      target = view.create_region
      build(region: target).append('streamed body')
      assert_equal 'untouched prefix', before_region.text.to_s
    end
  end

  context '#finalize' do
    it 'sets finalized? to true' do
      buf = build
      buf.finalize('done')
      assert buf.finalized?
    end

    it 'raises on double-finalize' do
      buf = build
      buf.finalize('done')
      assert_raises(RuntimeError) { buf.finalize('done') }
    end

    it 'replaces the preview with the authoritative content' do
      buf = build
      buf.append('hello tehre')  # typo
      buf.finalize('hello there')
      assert_equal 'hello there', region.text.to_s
    end

    it 'works on a buffer that never received an append' do
      buf = build
      buf.finalize('just the final')
      assert_equal 'just the final', region.text.to_s
    end

    it 'handles authoritative content that is empty' do
      buf = build
      buf.append('partial preview')
      buf.finalize('')
      assert region.empty?
    end

    it 'fast-paths when authoritative equals current source (region keeps its content)' do
      buf = build
      buf.append('keep this')
      content_before = region.text.to_s
      buf.finalize(buf.source)
      assert buf.finalized?
      assert_equal content_before, region.text.to_s
    end
  end
end
