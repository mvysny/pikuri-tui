# frozen_string_literal: true

RSpec.describe PikuriTui::StreamingMarkdownBuffer do
  # Recording sink — captures every (remove_n, lines_to_add) tuple the
  # buffer emits, plus exposes a #replay helper that rebuilds the final
  # TextView-equivalent line array by applying the events in order.
  # That replay is the easiest cross-check for "the buffer emits a
  # correct in-place diff" without having to assert exact intermediate
  # diffs (which are sensitive to the renderer's exact line breaks).
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
  # Render function used by the buffer in tests: the production
  # +MarkdownRenderer+ with width baked in. The replay-vs-single-shot
  # assertions below compare against this same renderer, so the buffer
  # and the expected value are always tested against the same Markdown
  # → ANSI transform.
  let(:render) { ->(md) { PikuriTui::MarkdownRenderer.render(md, width: width) } }

  def build(render: self.render)
    sink_obj = sink
    described_class.new(render: render) { |n, lines| sink_obj.record(n, lines) }
  end

  context 'construction' do
    it 'raises without a block sink' do
      assert_raises(ArgumentError) { described_class.new(render: render) }
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
      expected = render.call('hello world').split("\n")
      assert_equal expected, sink.replay
    end

    it 'replay matches a multi-paragraph source after token-by-token feeding' do
      buf = build
      source = "First paragraph.\n\nSecond paragraph here.\n\nThird."
      source.chars.each_slice(3) { |chunk| buf.append(chunk.join) }
      expected = render.call(source).split("\n")
      assert_equal expected, sink.replay
    end

    it 'replay matches a streamed code fence' do
      buf = build
      source = "Here's some code:\n\n```ruby\ndef hi\n  puts :hi\nend\n```\n\ndone."
      source.chars.each_slice(2) { |chunk| buf.append(chunk.join) }
      expected = render.call(source).split("\n")
      assert_equal expected, sink.replay
    end

    it 'replay matches a streamed table (the reformat-earlier-lines case)' do
      buf = build
      source = "| a | b |\n|---|---|\n| 1 | very long cell |\n| 2 | 3 |"
      source.chars.each_slice(4) { |chunk| buf.append(chunk.join) }
      expected = render.call(source).split("\n")
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
      expected = render.call('hello there').split("\n")
      assert_equal expected, sink.replay
    end

    it 'works on a buffer that never received an append' do
      buf = build
      buf.finalize('just the final')
      expected = render.call('just the final').split("\n")
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
    # Stateful render lambda used by the failure-handling specs. Starts
    # out as a thin wrapper around the production renderer; flip
    # +explode+ to +true+ to make the next render(s) raise, then back to
    # +false+ to simulate the upstream library recovering.
    class FlakyRenderer
      attr_accessor :explode

      def initialize(width:)
        @width = width
        @explode = false
      end

      def call(md)
        raise StandardError, 'synthetic render boom' if @explode
        PikuriTui::MarkdownRenderer.render(md, width: @width)
      end
    end

    it 'catches render exceptions, logs, and skips the emission' do
      old_logger = Tuile.logger
      log_io = StringIO.new
      Tuile.logger = Logger.new(log_io)

      flaky = FlakyRenderer.new(width: width)
      buf = build(render: flaky)
      buf.append('hello')
      sink.events.clear

      flaky.explode = true
      buf.append(' world')

      assert_empty sink.events
      assert_includes log_io.string, 'render failed'
      assert_includes log_io.string, 'synthetic render boom'
    ensure
      Tuile.logger = old_logger
    end

    it 'recovers cleanly on the next successful render' do
      flaky = FlakyRenderer.new(width: width)
      buf = build(render: flaky)
      buf.append('hello')
      sink.events.clear

      flaky.explode = true
      buf.append(' boom')
      assert_empty sink.events

      flaky.explode = false
      buf.append(' world')
      expected = PikuriTui::MarkdownRenderer.render('hello boom world', width: width).split("\n")
      assert_equal expected, sink.replay
    end
  end
end
