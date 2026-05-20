# frozen_string_literal: true

RSpec.describe PikuriTui::PassthroughBuffer do
  # Recording sink mirrored from the StreamingMarkdownBuffer spec — same
  # +#replay+ trick: apply each (remove_n, lines_to_add) tuple in order
  # and the resulting array is what the TextView would show. Lets us
  # assert "after streaming, the visible region equals the input" without
  # caring about which chunk boundary produced which emission.
  class PassthroughRecordingSink
    attr_reader :events

    def initialize
      @events = []
    end

    def record(remove_n, lines_to_add)
      @events << [remove_n, lines_to_add.dup]
    end

    def replay
      lines = []
      @events.each do |remove_n, to_add|
        remove_n.times { lines.pop }
        lines.concat(to_add)
      end
      lines
    end
  end

  let(:sink) { PassthroughRecordingSink.new }

  def build
    sink_obj = sink
    described_class.new { |n, lines| sink_obj.record(n, lines) }
  end

  context 'construction' do
    it 'raises without a block sink' do
      assert_raises(ArgumentError) { described_class.new }
    end

    it 'is not finalized at construction' do
      buf = build
      refute buf.finalized?
    end

    it 'starts with an empty source' do
      buf = build
      assert_equal '', buf.source
    end
  end

  context '#append' do
    it 'is a no-op on nil content' do
      buf = build
      buf.append(nil)
      assert_empty sink.events
    end

    it 'is a no-op on empty content' do
      buf = build
      buf.append('')
      assert_empty sink.events
    end

    it 'passes the input through unchanged (no Markdown conversion)' do
      buf = build
      buf.append("# heading\n\n**bold** _italic_")
      assert_equal ['# heading', '', '**bold** _italic_'], sink.replay
    end

    it 'emits (0, all_lines) on the first non-empty chunk' do
      buf = build
      buf.append('hello world')
      assert_equal 1, sink.events.size
      remove_n, lines = sink.events.first
      assert_equal 0, remove_n
      assert_equal ['hello world'], lines
    end

    it 'replay matches the raw source after token-by-token feeding' do
      buf = build
      source = "first line\nsecond line\nthird line"
      source.chars.each { |c| buf.append(c) }
      assert_equal source.split("\n"), sink.replay
    end

    it 'replay matches multi-paragraph source after chunked feeding' do
      buf = build
      source = "First paragraph.\n\nSecond paragraph.\n\nThird."
      source.chars.each_slice(3) { |chunk| buf.append(chunk.join) }
      assert_equal source.split("\n"), sink.replay
    end

    it 'extends the trailing line when no newline arrives' do
      buf = build
      buf.append('hel')
      buf.append('lo')
      # Two emissions, but the replay collapses to the single final line.
      assert_equal ['hello'], sink.replay
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
      assert_equal ['hello there'], sink.replay
    end

    it 'works on a buffer that never received an append' do
      buf = build
      buf.finalize('just the final')
      assert_equal ['just the final'], sink.replay
    end

    it 'handles authoritative content that is empty' do
      buf = build
      buf.append('partial preview')
      buf.finalize('')
      assert_empty sink.replay
    end

    it 'fast-paths when authoritative equals current source (no extra events)' do
      buf = build
      buf.append('keep this')
      events_before = sink.events.size
      buf.finalize(buf.source)
      assert_equal events_before, sink.events.size
      assert buf.finalized?
    end
  end
end
