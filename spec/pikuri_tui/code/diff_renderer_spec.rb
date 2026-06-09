# frozen_string_literal: true

RSpec.describe PikuriTui::Code::DiffRenderer do
  # The palette is theme-sourced: the renderer has no colors of its own, so
  # every spec builds one from an AppTheme's :diff_* tokens.
  def palette_for(theme)
    described_class::Palette.new(
      line_add: theme[:diff_line_add],
      line_del: theme[:diff_line_del],
      line_mod: theme[:diff_line_mod],
      span_add: theme[:diff_span_add],
      span_del: theme[:diff_span_del]
    )
  end

  let(:theme)   { PikuriTui::AppTheme::DARK }
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

  # Whether every character of +substr+ on the given diff +line+ is struck.
  def struck?(line, substr)
    ss = parse(line)
    col = ss.to_s.index(substr)
    (col...(col + substr.length)).all? { |i| ss.slice(i, 1).spans.first.style.strikethrough }
  end

  describe 'plain output (NO_COLOR / color: false)' do
    it 'renders context, deletion and addition rows with gutter markers' do
      out = render("foo\nbar", "foo\nbaz", width: 20, color: false)
      assert_equal "  foo\n- bar\n+ baz", out
    end

    it 'emits no SGR escapes' do
      out = render("a", "b", width: 20, color: false)
      refute_includes out, "\e"
    end

    it 'treats empty old content as an all-added file' do
      out = render("", "x\ny", width: 20, color: false)
      assert_equal "+ x\n+ y", out
    end

    it 'treats empty new content as an all-removed file' do
      out = render("x\ny", "", width: 20, color: false)
      assert_equal "- x\n- y", out
    end

    it 'preserves internal blank lines but drops a single trailing newline' do
      out = render("", "a\n\nb\n", width: 20, color: false)
      assert_equal "+ a\n+ \n+ b", out
    end
  end

  describe 'two-tier coloring of a modified line (inline, single row)' do
    # "value = 10" → "value = 20": only the "1"/"2" digit differs, so it
    # aligns as a modified pair and renders inline on one amber line tier —
    # the unchanged text stays on the line tier, the deleted "1" gets the red
    # span tier, the inserted "2" the green span tier, in that order ("120").
    let(:rendered) { render("value = 10", "value = 20", width: 20, color: true) }
    let(:mod_line) { rendered.split("\n")[0] }

    it 'collapses the modified pair into a single inline row' do
      assert_equal 1, rendered.split("\n").length
      assert_equal '~ value = 120', parse(mod_line).to_s.rstrip
    end

    it 'paints the unchanged part of the line in the amber modified line tier' do
      assert_equal [palette.line_mod], bgs_for(mod_line, 'value = ').uniq
    end

    it 'paints the deleted character in the red span tier' do
      assert_equal [palette.span_del], bgs_for(mod_line, '1')
    end

    it 'paints the inserted character in the green span tier' do
      assert_equal [palette.span_add], bgs_for(mod_line, '2')
    end

    it 'paints the unchanged suffix back on the line tier' do
      assert_equal [palette.line_mod], bgs_for(mod_line, '0')
    end

    it 'tints the gutter so the bar is continuous' do
      assert_equal palette.line_mod, parse(mod_line).spans.first.style.bg
    end

    it 'pads the line to the full width so the bar is solid' do
      assert_equal 20, parse(mod_line).display_width
    end

    it 'strikes the deleted character through, leaving the inserted one unstruck' do
      assert struck?(mod_line, '1'), 'expected the deleted char struck through'
      refute struck?(mod_line, '2'), 'expected the inserted char not struck'
    end
  end

  describe 'a divergent change groups the deleted run then the inserted run' do
    # "60" → "55" share no characters; a raw per-character sdiff would emit
    # 6/5/0/5 interleaved. Instead the whole deleted "60" is emitted (struck,
    # red) then the whole inserted "55" (green), so it stays readable.
    let(:mod_line) { render("x = 60", "x = 55", width: 20, color: true).split("\n")[0] }

    it 'emits the deleted slice contiguously, then the inserted slice' do
      assert_equal '~ x = 6055', parse(mod_line).to_s.rstrip
    end

    it 'paints and strikes the whole deleted run, paints the whole inserted run' do
      assert_equal [palette.span_del], bgs_for(mod_line, '60').uniq
      assert_equal [palette.span_add], bgs_for(mod_line, '55').uniq
      assert struck?(mod_line, '60'), 'expected the whole deleted run struck'
      refute struck?(mod_line, '55'), 'expected the inserted run unstruck'
    end
  end

  describe 'a modified line under NO_COLOR falls back to a delete + add pair' do
    it 'renders the old line then the new line, each with its gutter' do
      out = render("value = 10", "value = 20", width: 20, color: false)
      assert_equal "- value = 10\n+ value = 20", out
    end
  end

  describe 'the palette comes from the theme (light and dark both supported)' do
    it 'paints with the dark theme tones when given the dark palette' do
      line = render("", "added", width: 20, color: true)
      assert_equal [PikuriTui::AppTheme::DARK[:diff_line_add]], bgs_for(line, 'added').uniq
    end

    it 'paints with the light theme tones when given the light palette' do
      light = palette_for(PikuriTui::AppTheme::LIGHT)
      line = described_class.render("", "added", width: 20, palette: light, color: true)
      assert_equal [PikuriTui::AppTheme::LIGHT[:diff_line_add]], bgs_for(line, 'added').uniq
    end

    it 'paints different tones for the two themes' do
      refute_equal PikuriTui::AppTheme::DARK[:diff_line_add],
                   PikuriTui::AppTheme::LIGHT[:diff_line_add]
    end
  end

  describe 'pure add / delete lines carry only the line tier' do
    it 'does not emphasize any span on a pure addition' do
      line = render("", "brand new", width: 20, color: true)
      assert_equal [palette.line_add], bgs_for(line, 'brand new').uniq
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
      out = render("", (1..5).map(&:to_s).join("\n"), width: 20, max_lines: 2, color: false)
      assert_equal "+ 1\n+ 2\n  … +3 more lines", out
    end

    it 'uses the singular form when one line is dropped' do
      out = render("", "a\nb", width: 20, max_lines: 1, color: false)
      assert_equal "+ a\n  … +1 more line", out
    end
  end
end
