# frozen_string_literal: true

RSpec.describe PikuriTui::MarkdownRenderer do
  let(:width) { 80 }

  def render(src)
    described_class.render(src, width: width).split("\n")
  end

  # Same source rendered directly through TTY::Markdown — the "before"
  # baseline for asserting where the patched renderer diverges and
  # where it matches.
  def raw(src)
    TTY::Markdown.parse(src, width: width).split("\n")
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

    it 'preserves a tight pair inside a mixed loose/tight list' do
      # * foo (tight) * bar (loose) * baz
      assert_equal ['● foo', '● bar', '', '● baz'], render("* foo\n* bar\n\n* baz")
    end
  end

  context 'numbered (ordered) lists' do
    it 'does NOT split blank-separated numbered items — preserves numbering' do
      # Splitting would renumber both items to "1.", so we leave ordered
      # lists tight. Acceptable trade-off (numbered loose lists are rare
      # in LLM output; broken numbering would be a worse regression).
      assert_equal ['1. one', '2. two'], render("1. one\n\n2. two")
    end

    it 'leaves tight numbered lists alone' do
      assert_equal ['1. one', '2. two'], render("1. one\n2. two")
    end
  end

  context 'non-list content is unchanged' do
    it 'paragraphs render identically to TTY::Markdown directly' do
      src = "para one.\n\npara two."
      assert_equal raw(src), render(src)
    end

    it 'fenced code blocks are unchanged' do
      src = "```ruby\ndef hi\n  :hi\nend\n```"
      assert_equal raw(src), render(src)
    end

    it 'tables are unchanged' do
      src = "| a | b |\n|---|---|\n| 1 | 2 |"
      assert_equal raw(src), render(src)
    end

    it 'headings are unchanged' do
      src = "# heading\n\nparagraph."
      assert_equal raw(src), render(src)
    end

    it 'paragraph-then-list is unchanged (no false-positive injection)' do
      # The boundary regex requires a list-marker line on BOTH sides;
      # a paragraph ending into a list must not trigger an injection.
      src = "intro.\n\n* foo\n* bar"
      assert_equal raw(src), render(src)
    end

    it 'list-then-paragraph is unchanged' do
      src = "* foo\n* bar\n\nafter."
      assert_equal raw(src), render(src)
    end
  end

  context 'malformed table separators (em-dash / en-dash)' do
    # The bug: LLMs often emit "—-" (em-dash + hyphen) where they meant
    # "---". kramdown's separator detector rejects non-ASCII chars and
    # the whole table falls back to prose with literal pipes. We rewrite
    # the dashes to ASCII before parsing so the table renders.

    it 'rewrites em-dash separator rows so the table renders' do
      bad  = "| a | b |\n|—-|—-|\n| 1 | 2 |"
      good = "| a | b |\n|---|---|\n| 1 | 2 |"
      assert_equal raw(good), render(bad)
    end

    it 'rewrites en-dash separator rows so the table renders' do
      bad  = "| a | b |\n|–-|–-|\n| 1 | 2 |"
      good = "| a | b |\n|---|---|\n| 1 | 2 |"
      assert_equal raw(good), render(bad)
    end

    it 'rewrites a separator row made entirely of em-dashes' do
      bad  = "| a | b |\n|———|———|\n| 1 | 2 |"
      good = "| a | b |\n|---|---|\n| 1 | 2 |"
      assert_equal raw(good), render(bad)
    end

    it 'rewrites single-em-dash cells in a separator row' do
      # Bare "|—|—|—|" — one em-dash per cell, no hyphens at all.
      bad  = "| a | b | c |\n|—|—|—|\n| 1 | 2 | 3 |"
      good = "| a | b | c |\n|-|-|-|\n| 1 | 2 | 3 |"
      assert_equal raw(good), render(bad)
    end

    it 'leaves prose containing em-dashes alone' do
      # The interior-pipe requirement protects prose: "foo — bar" has
      # no pipes, so the pattern doesn't match.
      src = "foo — bar\n\nbaz — quux"
      assert_equal raw(src), render(src)
    end

    it 'leaves a properly-formed separator row untouched' do
      src = "| a | b |\n|---|---|\n| 1 | 2 |"
      assert_equal raw(src), render(src)
    end

    it 'leaves a horizontal rule of em-dashes alone (no interior pipe)' do
      # "———" alone is not a separator row candidate — no pipe — so we
      # don't rewrite it.
      src = "before\n\n———\n\nafter"
      assert_equal raw(src), render(src)
    end
  end

  context 'blank-run collapse' do
    it 'collapses adjacent blank lines down to one' do
      assert_equal ['a', '', 'b'], described_class.collapse_blank_runs("a\n\n\n\nb").split("\n")
    end

    it 'is a no-op when there are no adjacent blanks' do
      assert_equal ['a', '', 'b', '', 'c'], described_class.collapse_blank_runs("a\n\nb\n\nc").split("\n")
    end

    it 'is a no-op on stock TTY::Markdown output' do
      sources = [
        "# heading\n\nparagraph.",
        "para one.\n\npara two.",
        "```\ncode\n```\n\npara.",
        "intro\n\n* a\n* b\n\noutro",
      ]
      sources.each do |src|
        ansi = TTY::Markdown.parse(src, width: width)
        assert_equal ansi, described_class.collapse_blank_runs(ansi),
                     "collapse changed stock TTY::Markdown output for: #{src.inspect}"
      end
    end
  end
end
