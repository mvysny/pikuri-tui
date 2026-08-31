# frozen_string_literal: true

RSpec.describe Shared::PaneCaptionLabel do
  let(:label) { described_class.new('Tasks') }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  def rule_spans = label.text.spans.select { |span| span.text.include?('─') }

  it 'renders the caption followed by a hairline filling the rest of the width' do
    label.rect = Tuile::Rect.new(0, 0, 20, 1)
    # "Tasks" + a space + 14 columns of rule.
    assert_equal "Tasks #{'─' * 14}", label.text.to_s
  end

  it 'paints the caption in the hint accent and the rule in its own token' do
    label.rect = Tuile::Rect.new(0, 0, 20, 1)
    theme = Tuile::Screen.instance.theme
    caption_span = label.text.spans.find { |span| span.text.include?('Tasks') }
    assert_equal theme.hint_color, caption_span.style.fg
    assert_equal theme[:pane_frame], rule_spans.first.style.fg
  end

  it 're-renders the fill when the width changes' do
    label.rect = Tuile::Rect.new(0, 0, 20, 1)
    label.rect = Tuile::Rect.new(0, 0, 30, 1)
    assert_equal "Tasks #{'─' * 24}", label.text.to_s
  end

  it 'drops the rule rather than overflowing when there is no room for it' do
    label.rect = Tuile::Rect.new(0, 0, 5, 1)
    assert_equal 'Tasks', label.text.to_s
  end

  it 're-tones on a light/dark flip, since both colors are baked into the text' do
    label.rect = Tuile::Rect.new(0, 0, 20, 1)
    Tuile::Screen.instance.theme = Shared::AppTheme::LIGHT
    label.__send__(:on_theme_changed)
    assert_equal Shared::AppTheme::LIGHT.hint_color,
                 label.text.spans.find { |span| span.text.include?('Tasks') }.style.fg
  end
end
