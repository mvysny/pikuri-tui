# frozen_string_literal: true

RSpec.describe PikuriTui::StreamingMarkdownBuffer do
  # Temporarily replace +TTY::Markdown.parse+ with the given lambda for
  # the duration of the block. Used by the render-failure specs to
  # simulate +TTY::Markdown+ raising mid-stream.
  def with_markdown_parse(stub_proc)
    original = TTY::Markdown.method(:parse)
    TTY::Markdown.define_singleton_method(:parse) do |*args, **kwargs|
      stub_proc.call(*args, **kwargs)
    end
    yield
  ensure
    TTY::Markdown.define_singleton_method(:parse, original)
  end
  # Recording sink — captures every (remove_n, lines_to_add) tuple the
  # buffer emits, plus exposes a #replay helper that rebuilds the final
  # TextView-equivalent line array by applying the events in order.
  # That replay is the easiest cross-check for "the buffer emits a
  # correct in-place diff" without having to assert exact intermediate
  # diffs (which are sensitive to TTY::Markdown's exact line breaks).
  class RecordingSink
    attr_reader :events

    def initialize
      @events = []
    end

    def to_proc
      method(:record).to_proc
    end

    def record(remove_n, lines_to_add)
      @events << [remove_n, lines_to_add.dup]
    end

    # Apply the recorded events to an empty line array; what remains is
    # what the TextView would show for the streaming region.
    def replay
      lines = []
      @events.each do |remove_n, to_add|
        remove_n.times { lines.pop }
        lines.concat(to_add)
      end
      lines
    end
  end

  let(:sink) { RecordingSink.new }
  let(:width) { 80 }

  def build(width: 80)
    sink_obj = sink
    described_class.new(width: width) { |n, lines| sink_obj.record(n, lines) }
  end

  context 'construction' do
    it 'raises without a block sink' do
      assert_raises(ArgumentError) { described_class.new(width: 80) }
    end

    it 'is not finalized at construction' do
      buf = build
      refute buf.finalized?
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

    it 'emits a (0, all_lines) event on the first non-empty chunk' do
      buf = build
      buf.append('hello world')
      assert_equal 1, sink.events.size
      remove_n, _lines = sink.events.first
      assert_equal 0, remove_n
    end

    it "replay matches a single-shot render of the same source" do
      buf = build
      'hello world'.each_char { |c| buf.append(c) }
      expected = TTY::Markdown.parse('hello world', width: width).split("\n")
      assert_equal expected, sink.replay
    end

    it 'replay matches a multi-paragraph source after token-by-token feeding' do
      buf = build
      source = "First paragraph.\n\nSecond paragraph here.\n\nThird."
      source.chars.each_slice(3) { |chunk| buf.append(chunk.join) }
      expected = TTY::Markdown.parse(source, width: width).split("\n")
      assert_equal expected, sink.replay
    end

    it 'replay matches a streamed code fence' do
      buf = build
      source = "Here's some code:\n\n```ruby\ndef hi\n  puts :hi\nend\n```\n\ndone."
      source.chars.each_slice(2) { |chunk| buf.append(chunk.join) }
      expected = TTY::Markdown.parse(source, width: width).split("\n")
      assert_equal expected, sink.replay
    end

    it 'replay matches a streamed table (the reformat-earlier-lines case)' do
      buf = build
      source = "| a | b |\n|---|---|\n| 1 | very long cell |\n| 2 | 3 |"
      source.chars.each_slice(4) { |chunk| buf.append(chunk.join) }
      expected = TTY::Markdown.parse(source, width: width).split("\n")
      assert_equal expected, sink.replay
    end

    it 'emits no event when content extends the source without changing the render' do
      # Some leading whitespace can be a no-op for the rendered output.
      buf = build
      buf.append('hello')
      sink.events.clear
      buf.append('')
      assert_empty sink.events
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
      expected = TTY::Markdown.parse('hello there', width: width).split("\n")
      assert_equal expected, sink.replay
    end

    it 'works on a buffer that never received an append' do
      buf = build
      buf.finalize('just the final')
      expected = TTY::Markdown.parse('just the final', width: width).split("\n")
      assert_equal expected, sink.replay
    end

    it 'handles authoritative content that is empty' do
      buf = build
      buf.append('partial preview')
      buf.finalize('')
      assert_empty sink.replay
    end
  end

  context 'render failure handling' do
    it 'catches TTY::Markdown exceptions, logs, and skips the emission' do
      old_logger = Tuile.logger
      log_io = StringIO.new
      Tuile.logger = Logger.new(log_io)

      buf = build
      buf.append('hello')
      sink.events.clear

      raised = false
      with_markdown_parse(->(*_a, **_kw) { raised = true; raise StandardError, 'synthetic render boom' }) do
        buf.append(' world')
      end

      assert raised, 'expected the stub to be invoked'
      assert_empty sink.events
      assert_includes log_io.string, 'TTY::Markdown render failed'
      assert_includes log_io.string, 'synthetic render boom'
    ensure
      Tuile.logger = old_logger
    end

    it 'recovers cleanly on the next successful render' do
      buf = build
      buf.append('hello')
      sink.events.clear

      with_markdown_parse(->(*_a, **_k) { raise 'boom' }) do
        buf.append(' boom')
      end
      assert_empty sink.events

      buf.append(' world')
      expected = TTY::Markdown.parse('hello boom world', width: width).split("\n")
      assert_equal expected, sink.replay
    end
  end
end
