# frozen_string_literal: true

RSpec.describe Shared::StatusBar do
  let(:bar) { described_class.new }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  def rendered = bar.text.to_s

  def color_of(substr)
    bar.text.spans.find { |span| span.text.include?(substr) }&.style&.fg
  end

  it 'leads with ^C cancel in the theme error tone' do
    bar.refresh
    assert_equal '^C cancel', rendered
    assert_equal Tuile::Screen.instance.theme[:error], color_of('cancel')
  end

  it 'puts the menu hint after the cancel half' do
    bar.menu_hint { '^K menu' }
    assert_equal '^C cancel  ^K menu', rendered
  end

  it 'shows no hint when the block renders nil' do
    bar.menu_hint { nil }
    assert_equal '^C cancel', rendered
  end

  it 're-runs the block on refresh, so the hint can carry live state' do
    tally = 0
    bar.menu_hint { "^K menu (#{tally})" }
    tally = 2
    bar.refresh
    assert_equal '^C cancel  ^K menu (2)', rendered
  end

  it 'restyles when handle_theme_changed fires after a theme flip' do
    bar.refresh # bakes in the FakeScreen default (DARK) error tone
    Tuile::Screen.instance.theme = Shared::AppTheme::LIGHT
    bar.handle_theme_changed # Screen#theme= fires this tree-wide; here we drive it directly
    assert_equal Shared::AppTheme::LIGHT[:error], color_of('cancel')
  end
end
