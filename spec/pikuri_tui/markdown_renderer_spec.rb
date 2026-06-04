# frozen_string_literal: true

RSpec.describe PikuriTui::MarkdownRenderer do
  let(:width) { 80 }

  # NO_COLOR is set for the whole suite (see spec_helper.rb), so the
  # rendered output here is structure only — no SGR escapes. Styling
  # is covered by ansi_converter_spec.rb, which re-enables color.
  def render(src)
    described_class.render(src, width: width).split("\n")
  end

  context 'loose bulleted lists' do
    it 'inserts a blank line between blank-separated bullet items' do
      assert_equal ['● foo', '', '● bar'], render("* foo\n\n* bar")
    end

    it 'separates every pair in a 3-item loose list' do
      assert_equal ['● foo', '', '● bar', '', '● baz'], render("* foo\n\n* bar\n\n* baz")
    end

    it 'handles + and - markers as well as *' do
      assert_equal ['● foo', '', '● bar'], render("- foo\n\n- bar")
      assert_equal ['● foo', '', '● bar'], render("+ foo\n\n+ bar")
    end

    it 'leaves tight bullet lists alone' do
      assert_equal ['● foo', '● bar'], render("* foo\n* bar")
    end

    it 'renders a mixed loose/tight list uniformly loose (CommonMark list-level rule)' do
      # One blank anywhere between items makes the whole list loose.
      # (The retired tty-markdown-era pre-pass could only split at the
      # blank-separated pair, leaving "foo"/"bar" tight — the parse-tree
      # renderer applies the spec rule instead.)
      assert_equal ['● foo', '', '● bar', '', '● baz'], render("* foo\n* bar\n\n* baz")
    end

    it 'keeps a multi-paragraph item aligned under its marker' do
      assert_equal ['● first para', '', '  second para', '', '● next item'],
                   render("* first para\n\n  second para\n\n* next item")
    end
  end

  context 'numbered (ordered) lists' do
    it 'renders blank-separated numbered items loose, numbering intact' do
      # The tty-markdown-era renderer had to leave these tight because
      # its split-the-list workaround reset numbering. Rendering the
      # list from the parse tree keeps both the blank line and the
      # numbers.
      assert_equal ['1. one', '', '2. two'], render("1. one\n\n2. two")
    end

    it 'leaves tight numbered lists alone' do
      assert_equal ['1. one', '2. two'], render("1. one\n2. two")
    end
  end

  context 'nested lists' do
    it 'indents nested items under the parent item text' do
      assert_equal ['● a', '  ● a1', '  ● a2', '● b'], render("* a\n  * a1\n  * a2\n* b")
    end
  end

  context 'block structure' do
    it 'separates paragraphs with one blank line' do
      assert_equal ['para one.', '', 'para two.'], render("para one.\n\npara two.")
    end

    it 'renders a top-level heading flush left with its body unindented' do
      assert_equal ['heading', '', 'paragraph.'], render("# heading\n\nparagraph.")
    end

    it 'indents content under an H2 by one step' do
      assert_equal ['  heading', '', '  paragraph.'], render("## heading\n\nparagraph.")
    end

    it 'renders fenced code blocks verbatim' do
      assert_equal ['def hi', '  :hi', 'end'], render("```ruby\ndef hi\n  :hi\nend\n```")
    end

    it 'prefixes blockquote lines with the quote bar' do
      assert_equal ['┃  quoted more'], render("> quoted\n> more")
    end

    it 'wraps paragraphs at the requested width' do
      lines = described_class.render("#{'word ' * 30}end", width: 40).split("\n")
      assert lines.size > 1, 'expected the paragraph to wrap'
      lines.each do |line|
        assert line.length <= 40, "line over width: #{line.inspect}"
      end
    end
  end

  context 'malformed table separators (em-dash / en-dash)' do
    # The bug: LLMs often emit "—-" (em-dash + hyphen) where they meant
    # "---". kramdown's separator detector rejects non-ASCII chars and
    # the whole table falls back to prose with literal pipes. We rewrite
    # the dashes to ASCII before parsing so the table renders.

    def well_formed_table
      render("| a | b |\n|---|---|\n| 1 | 2 |")
    end

    it 'renders a properly-formed separator row as a boxed table' do
      assert_equal ['┌───┬───┐', '│ a │ b │', '├───┼───┤', '│ 1 │ 2 │', '└───┴───┘'],
                   well_formed_table
    end

    it 'rewrites em-dash separator rows so the table renders' do
      assert_equal well_formed_table, render("| a | b |\n|—-|—-|\n| 1 | 2 |")
    end

    it 'rewrites en-dash separator rows so the table renders' do
      assert_equal well_formed_table, render("| a | b |\n|–-|–-|\n| 1 | 2 |")
    end

    it 'rewrites a separator row made entirely of em-dashes' do
      assert_equal well_formed_table, render("| a | b |\n|———|———|\n| 1 | 2 |")
    end

    it 'rewrites single-em-dash cells in a separator row' do
      # Bare "|—|—|—|" — one em-dash per cell, no hyphens at all.
      good = render("| a | b | c |\n|-|-|-|\n| 1 | 2 | 3 |")
      assert_equal good, render("| a | b | c |\n|—|—|—|\n| 1 | 2 | 3 |")
    end

    it 'leaves prose containing em-dashes alone' do
      # The interior-pipe requirement protects prose: "foo — bar" has
      # no pipes, so the pattern doesn't match.
      assert_equal ['foo — bar', '', 'baz — quux'], render("foo — bar\n\nbaz — quux")
    end

    it 'leaves a run of em-dashes without pipes alone (not a separator row)' do
      # "———" alone has no pipe, so we don't rewrite it into "---"
      # (which kramdown would then render as a horizontal rule).
      assert_equal ['before', '', '———', '', 'after'], render("before\n\n———\n\nafter")
    end
  end

  context 'diagnostics' do
    it 'forwards converter warnings to Tuile.logger, not the output' do
      captured = StringIO.new
      original = Tuile.logger
      Tuile.logger = Logger.new(captured)
      begin
        out = described_class.render('before <marquee>zip</marquee> after', width: width)
      ensure
        Tuile.logger = original
      end
      assert_includes captured.string, 'marquee'
      assert_includes out, 'zip'
      refute_includes out, 'marquee'
    end
  end
end
