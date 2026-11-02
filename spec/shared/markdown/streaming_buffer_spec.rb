# frozen_string_literal: true

RSpec.describe Shared::Markdown::StreamingBuffer do
  let(:width) { 80 }
  # Render function used by the buffer in tests: the production
  # +Shared::Markdown::Renderer+ with width baked in. Assertions below compare
  # +region.text.to_s+ against the same renderer's single-shot output,
  # so the buffer and the expected value are always tested against the
  # same Markdown → ANSI transform.
  let(:render) { ->(md) { Shared::Markdown::Renderer.render(md, width: width) } }
  let(:view) { Tuile::Component::TextView.new }
  let(:region) { view.create_region }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  def build(render: self.render, region: self.region)
    described_class.new(render: render, region: region)
  end

  context 'construction' do
    it 'is not finalized at construction' do
      buf = build
      refute buf.finalized?
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

    it 'writes the rendered content into the region' do
      buf = build
      buf.append('hello world')
      assert_equal render.call('hello world').strip, region.text.to_s.strip
    end

    it 'token-by-token feeding ends in the same render as a single-shot' do
      buf = build
      'hello world'.each_char { |c| buf.append(c) }
      assert_equal render.call('hello world').strip, region.text.to_s.strip
    end

    it 'multi-paragraph source converges to the single-shot render' do
      buf = build
      source = "First paragraph.\n\nSecond paragraph here.\n\nThird."
      source.chars.each_slice(3) { |chunk| buf.append(chunk.join) }
      assert_equal render.call(source).strip, region.text.to_s.strip
    end

    it 'streamed code fence converges to the single-shot render' do
      buf = build
      source = "Here's some code:\n\n```ruby\ndef hi\n  puts :hi\nend\n```\n\ndone."
      source.chars.each_slice(2) { |chunk| buf.append(chunk.join) }
      # Rouge and Tuile's StyledString emit semantically equivalent but
      # byte-different SGR (e.g. `\e[38;5;221;01m` vs `\e[1;38;5;221m`, and
      # Rouge wraps whitespace in empty styled spans that StyledString
      # normalizes away). Round-trip both sides through the parser so the
      # comparison is structural, not byte-wise.
      expected = Tuile::StyledString.parse(render.call(source).strip)
      assert_equal expected, Tuile::StyledString.parse(region.text.to_ansi.strip)
    end

    it 'streamed table (the reformat-earlier-lines case) converges' do
      buf = build
      source = "| a | b |\n|---|---|\n| 1 | very long cell |\n| 2 | 3 |"
      source.chars.each_slice(4) { |chunk| buf.append(chunk.join) }
      assert_equal render.call(source).strip, region.text.to_s.strip
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
      buf.append('hello tehre') # typo
      buf.finalize('hello there')
      assert_equal render.call('hello there').strip, region.text.to_s.strip
    end

    it 'works on a buffer that never received an append' do
      buf = build
      buf.finalize('just the final')
      assert_equal render.call('just the final').strip, region.text.to_s.strip
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

        Shared::Markdown::Renderer.render(md, width: @width)
      end
    end

    it 'catches render exceptions, logs, and keeps prior region content' do
      flaky = FlakyRenderer.new(width: width)
      buf = build(render: flaky)
      buf.append('hello')
      content_before = region.text.to_s

      flaky.explode = true
      log = capture_log { buf.append(' world') }

      assert_equal content_before, region.text.to_s
      assert_includes log, 'render failed'
      assert_includes log, 'synthetic render boom'
    end

    it 'recovers cleanly on the next successful render' do
      flaky = FlakyRenderer.new(width: width)
      buf = build(render: flaky)
      buf.append('hello')

      flaky.explode = true
      buf.append(' boom')

      flaky.explode = false
      buf.append(' world')
      expected = Shared::Markdown::Renderer.render('hello boom world', width: width)
      assert_equal expected.strip, region.text.to_s.strip
    end
  end
end
