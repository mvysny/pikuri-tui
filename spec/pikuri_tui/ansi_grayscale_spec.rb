# frozen_string_literal: true

RSpec.describe PikuriTui::AnsiGrayscale do
  describe '.recolor' do
    def parse(ansi)
      Tuile::StyledString.parse(ansi)
    end

    it 'wraps plain text in the gray fg' do
      out = described_class.recolor('hello')
      ss = parse(out)
      assert_equal 'hello', ss.to_s
      assert_equal [[85, 85, 85]], ss.spans.map { |s| s.style.fg }.uniq
    end

    it 'replaces an existing fg color with gray' do
      out = described_class.recolor("\e[31mred\e[0m")
      ss = parse(out)
      assert_equal 'red', ss.to_s
      assert_equal [85, 85, 85], ss.spans.first.style.fg
    end

    it 'preserves bold while recoloring' do
      out = described_class.recolor("\e[1mbold\e[0m")
      span = parse(out).spans.first
      assert span.style.bold
      assert_equal [85, 85, 85], span.style.fg
    end

    it 'preserves italic while recoloring' do
      out = described_class.recolor("\e[3mitalic\e[0m")
      span = parse(out).spans.first
      assert span.style.italic
      assert_equal [85, 85, 85], span.style.fg
    end

    it 'preserves underline while recoloring' do
      out = described_class.recolor("\e[4munderline\e[0m")
      span = parse(out).spans.first
      assert span.style.underline
      assert_equal [85, 85, 85], span.style.fg
    end

    it 'preserves combined attributes' do
      out = described_class.recolor("\e[1;3;4;31mall the things\e[0m")
      span = parse(out).spans.first
      assert span.style.bold
      assert span.style.italic
      assert span.style.underline
      assert_equal [85, 85, 85], span.style.fg
    end

    it 'clears background colors so the gray reads as a single tone' do
      out = described_class.recolor("\e[41mred-bg\e[0m")
      span = parse(out).spans.first
      assert_nil span.style.bg
      assert_equal [85, 85, 85], span.style.fg
    end

    it 'leaves an empty string untouched (no SGR injected)' do
      assert_equal '', described_class.recolor('')
    end

    it 'logs and returns the input unchanged when StyledString cannot parse the SGR' do
      captured = StringIO.new
      Tuile.logger = Logger.new(captured)
      # SGR code 2 (dim) is not modeled by Tuile::StyledString → ParseError.
      input = "\e[2mdim\e[0m"
      out = described_class.recolor(input)
      assert_equal input, out
      assert_includes captured.string, 'AnsiGrayscale'
    end

    it 'handles multi-span input by recoloring every span' do
      out = described_class.recolor("\e[31mred\e[0m plain \e[1mbold\e[0m")
      ss = parse(out)
      assert_equal 'red plain bold', ss.to_s
      assert_equal [[85, 85, 85]], ss.spans.map { |s| s.style.fg }.uniq
      assert ss.spans.find { |s| s.text.include?('bold') }.style.bold
    end
  end
end
