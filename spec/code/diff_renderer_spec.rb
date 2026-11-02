# frozen_string_literal: true

RSpec.describe Code::DiffRenderer do
  # The palette is theme-sourced: the renderer has no colors of its own, so
  # every spec builds one from an Shared::AppTheme's :diff_* tokens.
  def palette_for(theme)
    described_class::Palette.new(
      line_add: theme[:diff_line_add],
      line_del: theme[:diff_line_del],
      span_add: theme[:diff_span_add],
      span_del: theme[:diff_span_del]
    )
  end

  let(:theme)   { Shared::AppTheme::DARK }
  let(:palette) { palette_for(theme) }

  # Render with the (required) palette injected, so per-example calls only
  # vary the inputs and options that matter to them.
  def render(old, new, **opts)
    described_class.render(old, new, palette: palette, **opts)
  end

  def parse(ansi)
    Tuile::StyledString.parse(ansi)
  end

  # The whole-line and changed-span backgrounds covering the characters of
  # +substr+ on the given diff +line+.
  def bgs_for(line, substr)
    ss = parse(line)
    col = ss.to_s.index(substr)
    (col...(col + substr.length)).map { |i| ss.slice(i, 1).spans.first.style.bg }
  end

  describe 'plain output (NO_COLOR / color: false)' do
    it 'renders context, deletion and addition rows with gutter markers' do
      out = render("foo\nbar", "foo\nbaz", width: 20, color: false)
      assert_equal "  foo\n- bar\n+ baz", out
    end

    it 'emits no SGR escapes' do
      out = render('a', 'b', width: 20, color: false)
      refute_includes out, "\e"
    end

    it 'treats empty old content as an all-added file' do
      out = render('', "x\ny", width: 20, color: false)
      assert_equal "+ x\n+ y", out
    end

    it 'treats empty new content as an all-removed file' do
      out = render("x\ny", '', width: 20, color: false)
      assert_equal "- x\n- y", out
    end

    it 'preserves internal blank lines but drops a single trailing newline' do
      out = render('', "a\n\nb\n", width: 20, color: false)
      assert_equal "+ a\n+ \n+ b", out
    end
  end

  describe 'two-tier coloring' do
    # "value = 10" → "value = 20": only the number differs, so the pair aligns
    # as a modification — the rest of the line carries the line tier, the
    # changed word the span tier.
    let(:rendered) { render('value = 10', 'value = 20', width: 20, color: true) }
    let(:del_line) { rendered.split("\n")[0] }
    let(:add_line) { rendered.split("\n")[1] }

    it 'splits a modified pair into a removed row then an added row' do
      assert_equal '- value = 10', parse(del_line).to_s.rstrip
      assert_equal '+ value = 20', parse(add_line).to_s.rstrip
    end

    it 'paints the unchanged part of a removed line in the dim line tier' do
      assert_equal [palette.line_del], bgs_for(del_line, 'value = ').uniq
    end

    it 'paints the changed word of a removed line in the bright span tier' do
      assert_equal [palette.span_del] * 2, bgs_for(del_line, '10')
    end

    it 'paints the unchanged part of an added line in the dim line tier' do
      assert_equal [palette.line_add], bgs_for(add_line, 'value = ').uniq
    end

    it 'paints the changed word of an added line in the bright span tier' do
      assert_equal [palette.span_add] * 2, bgs_for(add_line, '20')
    end

    it 'tints the gutter so the bar is continuous' do
      assert_equal palette.line_del, parse(del_line).spans.first.style.bg
    end

    it 'pads the line to the full width so the bar is solid' do
      assert_equal 20, parse(del_line).display_width
    end
  end

  describe 'the palette comes from the theme (light and dark both supported)' do
    it 'paints with the dark theme tones when given the dark palette' do
      line = render('', 'added', width: 20, color: true)
      assert_equal [Shared::AppTheme::DARK[:diff_line_add]], bgs_for(line, 'added').uniq
    end

    it 'paints with the light theme tones when given the light palette' do
      light = palette_for(Shared::AppTheme::LIGHT)
      line = described_class.render('', 'added', width: 20, palette: light, color: true)
      assert_equal [Shared::AppTheme::LIGHT[:diff_line_add]], bgs_for(line, 'added').uniq
    end

    it 'paints different tones for the two themes' do
      refute_equal Shared::AppTheme::DARK[:diff_line_add],
                   Shared::AppTheme::LIGHT[:diff_line_add]
    end
  end

  describe 'pure add / delete lines carry only the line tier' do
    it 'does not emphasize any span on a pure addition' do
      line = render('', 'brand new', width: 20, color: true)
      assert_equal [palette.line_add], bgs_for(line, 'brand new').uniq
    end
  end

  describe 'word-level emphasis' do
    # Character-level alignment would light "i", "s", "t" and "ant"
    # separately inside "instant"; the whole word is the unit.
    let(:rendered) do
      render('the instant a pane is hidden', 'the moment a pane is hidden', width: 40, color: true)
    end
    let(:add_line) { rendered.split("\n")[1] }

    it 'lights the whole changed word, with no gaps inside it' do
      assert_equal [palette.span_add] * 6, bgs_for(add_line, 'moment')
    end

    it 'leaves the words it shares with the other side on the line tier' do
      assert_equal [palette.line_add], bgs_for(add_line, ' a pane is hidden').uniq
    end
  end

  describe 'a modified pair with too little in common gets no span tier' do
    # sdiff pairs modified lines positionally, so a rewritten paragraph aligns
    # sides that share nothing; emphasizing their stray letters in common is
    # what speckles a reflowed block into confetti.
    let(:rendered) do
      render('Each is a local patch for something Tuile cannot yet express',
             '`Component#visible = false` means gone — no paint, no focus',
             width: 70, color: true)
    end

    it 'paints the removed line in the line tier alone' do
      assert_equal [palette.line_del], bgs_for(rendered.split("\n")[0], 'local patch').uniq
    end

    it 'paints the added line in the line tier alone' do
      assert_equal [palette.line_add], bgs_for(rendered.split("\n")[1], 'no paint').uniq
    end

    it 'still splits the pair into a removed row and an added row' do
      assert_equal 2, rendered.split("\n").length
      assert parse(rendered.split("\n")[0]).to_s.start_with?('- ')
      assert parse(rendered.split("\n")[1]).to_s.start_with?('+ ')
    end

    it 'keeps the span tier for a pair that is a genuine edit of one line' do
      line = render('  @width = [width, 1].max', '  @width = [width, 1].max.clamp(1, 9)',
                    width: 60, color: true).split("\n")[1]
      assert_equal [palette.span_add], bgs_for(line, '.clamp').uniq
    end
  end

  describe 'context lines' do
    it 'carry no background' do
      out = render("keep\nold", "keep\nnew", width: 20, color: true)
      context = out.split("\n").first
      assert_equal 'keep', parse(context).to_s.strip
      assert_nil parse(context).spans.first.style.bg
    end
  end

  describe 'truncation' do
    it 'caps at max_lines and appends a pluralized overflow tail' do
      out = render('', (1..5).map(&:to_s).join("\n"), width: 20, max_lines: 2, color: false)
      assert_equal "+ 1\n+ 2\n  … +3 more lines", out
    end

    it 'uses the singular form when one line is dropped' do
      out = render('', "a\nb", width: 20, max_lines: 1, color: false)
      assert_equal "+ a\n  … +1 more line", out
    end
  end
end
