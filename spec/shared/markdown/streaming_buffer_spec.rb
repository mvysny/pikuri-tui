# frozen_string_literal: true

RSpec.describe Shared::Markdown::StreamingBuffer do
  let(:width) { 80 }
  # The production block render; each streamed result is compared with the
  # same text rendered whole, which is the buffer's whole promise.
  let(:render) { ->(root, section) { Shared::Markdown::Renderer.convert(root, width: width, section_indent: section) } }
  let(:view) { Tuile::Component::TextView.new }
  let(:region) { view.create_region }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  def build(render: self.render, region: self.region, indent: 0)
    described_class.new(render: render, region: region, indent: indent)
  end

  def whole(source) = Shared::Markdown::Renderer.render(source, width: width)

  # Rouge and Tuile's StyledString emit equivalent but byte-different SGR, so
  # compare structurally.
  def assert_renders_as(source, region)
    assert_equal Tuile::StyledString.parse(whole(source).strip), Tuile::StyledString.parse(region.text.to_ansi.strip)
  end

  def stream(buf, source, slice) = source.chars.each_slice(slice) { |chunk| buf.append(chunk.join) }

  context 'construction' do
    it 'is not finalized and does not touch the region' do
      refute build.finalized?
      assert region.empty?
    end
  end

  context '#append' do
    it 'is a no-op on nil or empty content' do
      buf = build
      buf.append(nil)
      buf.append('')
      assert region.empty?
    end

    it 'char-by-char feeding ends in the whole-text render' do
      buf = build
      'hello world'.each_char { |c| buf.append(c) }
      assert_renders_as 'hello world', region
    end

    {
      'paragraphs' => "First paragraph.\n\nSecond paragraph here.\n\nThird.",
      'a code fence' => "Here's some code:\n\n```ruby\ndef hi\n  puts :hi\nend\n```\n\ndone.",
      'a fence then a paragraph with no blank line' => "```\ncode\n```\nAfter fence.\n",
      'a table' => "| a | b |\n|---|---|\n| 1 | very long cell |\n| 2 | 3 |",
      'a loose ordered list' => "1. a\n\n2. b\n\n3. c\n",
      'header sections' => "# Title\n\nIntro.\n\n## Section\n\nBody.\n\n- a\n- b\n\n### Deeper\n\nMore.\n"
    }.each do |name, source|
      it "streams #{name} into the whole-text render" do
        [1, 3, 7].each do |slice|
          target = view.create_region
          buf = build(region: target)
          stream(buf, source, slice)
          assert_renders_as source, target
          buf.finalize(source)
          assert_renders_as source, target
        end
      end
    end

    it 'numbers a loose ordered list on, mid-stream too' do
      buf = build
      "1. a\n\n2. b\n\n3. c".each_char { |c| buf.append(c) }
      assert_includes region.text.to_s, '3. c'
    end

    it 'keeps a header section indent across finished blocks' do
      buf = build
      stream(buf, "## Section\n\nBody.\n\nMore.\n\n", 1)
      assert_equal '  More.', region.text.to_s.lines(chomp: true).last
    end

    it 'pads the region first line by indent' do
      buf = build(indent: 2)
      stream(buf, "One.\n\nTwo.\n\n", 1)
      assert_equal ['  One.', '', 'Two.'], region.text.to_s.lines(chomp: true)
    end

    it 'raises if called after finalize' do
      buf = build
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
    it 'raises on double-finalize' do
      buf = build
      buf.finalize('done')
      assert buf.finalized?
      assert_raises(RuntimeError) { buf.finalize('done') }
    end

    it 'replaces the preview with differing authoritative content' do
      buf = build
      stream(buf, "hello tehre\n\nsecond\n\n", 2)
      buf.finalize("hello there\n\nsecond\n")
      assert_renders_as "hello there\n\nsecond\n", region
    end

    it 'works on a buffer that never received an append' do
      buf = build
      buf.finalize('just the final')
      assert_renders_as 'just the final', region
    end

    it 'empties the region for empty authoritative content' do
      buf = build
      buf.append('partial preview')
      buf.finalize('')
      assert region.empty?
    end

    it 'keeps the preview when finalized with its own source' do
      buf = build
      buf.append('keep this')
      content_before = region.text.to_s
      buf.finalize(buf.source)
      assert_equal content_before, region.text.to_s
    end

    # Streamed, a reference a block away from its definition stays literal;
    # the final render resolves it.
    it 'resolves a reference link whose definition came blocks later' do
      source = "See [the docs][1] for more.\n\nSecond para.\n\n[1]: https://example.com\n"
      buf = build
      stream(buf, source, 1)
      assert_includes region.text.to_s, '[the docs][1]'
      buf.finalize(buf.source)
      refute_includes region.text.to_s, '[the docs][1]'
      assert_renders_as source, region
    end
  end

  context 'render failure handling' do
    # Wraps the production render; flip +explode+ to make the next renders raise.
    let(:flaky) do
      real = render
      Class.new do
        attr_accessor :explode

        define_method(:call) do |root, section|
          raise StandardError, 'synthetic render boom' if explode

          real.call(root, section)
        end
      end.new
    end

    it 'logs and keeps the previous render of the open tail' do
      buf = build(render: flaky)
      buf.append('hello')
      content_before = region.text.to_s

      flaky.explode = true
      log = capture_log { buf.append(' world') }

      assert_equal content_before, region.text.to_s
      assert_includes log, 'synthetic render boom'
    end

    it 'recovers on the next successful render' do
      buf = build(render: flaky)
      buf.append('hello')
      flaky.explode = true
      buf.append(' boom')
      flaky.explode = false
      buf.append(' world')
      assert_renders_as 'hello boom world', region
    end

    it 'shows a finished block whose render failed as its Markdown source' do
      buf = build(render: flaky)
      buf.append("**bold** text\n\n")
      flaky.explode = true
      capture_log { buf.append("Next\n") } # a complete line begins a block, finishing the first
      flaky.explode = false
      buf.append('More')
      assert_includes region.text.to_s, '**bold** text'
      assert_includes region.text.to_s, 'Next More'
    end
  end
end
