# frozen_string_literal: true

RSpec.describe Shared::PaneCaptionLabel do
  let(:label) { described_class.new('Tasks') }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  # The rule is painted, not part of the text, so the row is read off the buffer.
  def painted_row = painted_region(label).first.rstrip

  # @return [Tuile::StyledString::Style] the painted style at column +x+.
  def painted_style(x) = Tuile::Screen.instance.buffer.cell(x, 0).style

  it 'renders the caption followed by a hairline filling the rest of the width' do
    Tuile::Testing.place(label, Tuile::Rect.new(0, 0, 20, 1))
    # "Tasks" + a space + 14 columns of rule.
    assert_equal "Tasks #{'─' * 14}", painted_row
  end

  it 'paints the caption in the hint accent and the rule in its own token' do
    Tuile::Testing.place(label, Tuile::Rect.new(0, 0, 20, 1))
    theme = Tuile::Screen.instance.theme
    caption_span = label.text.spans.find { |span| span.text.include?('Tasks') }
    assert_equal theme[:hint], caption_span.style.fg
    painted_row
    assert_equal theme[:pane_frame], painted_style(6).fg
  end

  it 're-renders the fill when the width changes' do
    Tuile::Testing.place(label, Tuile::Rect.new(0, 0, 20, 1))
    Tuile::Testing.place(label, Tuile::Rect.new(0, 0, 30, 1))
    assert_equal "Tasks #{'─' * 24}", painted_row
  end

  it 'drops the rule rather than overflowing when there is no room for it' do
    Tuile::Testing.place(label, Tuile::Rect.new(0, 0, 5, 1))
    assert_equal 'Tasks', painted_row
  end

  describe 'a caption that brings its own tones' do
    let(:theme) { Tuile::Screen.instance.theme }
    let(:tally) do
      Tuile::StyledString.plain('Changes: 2; ') + Tuile::StyledString.styled('+184', fg: theme[:added])
    end

    def toned = label.text.spans.to_h { |span| [span.text, span.style.fg] }

    it 'fills the accent under the untoned spans and leaves the toned ones alone' do
      Tuile::Testing.place(label, Tuile::Rect.new(0, 0, 24, 1))
      label.caption = tally
      assert_equal theme[:hint], toned['Changes: 2; ']
      assert_equal theme[:added], toned['+184']
    end

    it 'measures the fill on the whole caption, tones and all' do
      Tuile::Testing.place(label, Tuile::Rect.new(0, 0, 24, 1))
      label.caption = tally
      # 24 columns less "Changes: 2; +184" and the space before the rule.
      assert_equal "Changes: 2; +184 #{'─' * 7}", painted_row
    end
  end

  it 're-tones on a light/dark flip, since both colors are baked into the text' do
    Tuile::Testing.place(label, Tuile::Rect.new(0, 0, 20, 1))
    Tuile::Screen.instance.theme = Shared::AppTheme::LIGHT
    label.__send__(:handle_theme_changed)
    assert_equal Shared::AppTheme::LIGHT[:hint],
                 label.text.spans.find { |span| span.text.include?('Tasks') }.style.fg
  end
end
