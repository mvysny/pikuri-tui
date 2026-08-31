# frozen_string_literal: true

RSpec.describe Shared::RootLayout do
  # A shell layout only has to be a component to be stacked; a Label stands in.
  let(:shell) { Tuile::Component::Label.new('shell') }
  let(:status_bar) { Shared::StatusBar.new }
  let(:root) { described_class.new(shell, status_bar) }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  it 'gives the status bar the last row and the shell every row above it' do
    root.rect = Tuile::Rect.new(0, 0, 40, 10)
    assert_equal Tuile::Rect.new(0, 0, 40, 9), shell.rect
    assert_equal Tuile::Rect.new(0, 9, 40, 1), status_bar.rect
  end

  it 'exposes both children' do
    assert_same shell, root.shell
    assert_same status_bar, root.status_bar
  end

  describe 'keeping the derived theme current' do
    it 're-derives the background-dependent tokens when the theme changes' do
      screen = Tuile::Screen.instance
      screen.content = root
      screen.background_color = Tuile::Color.hex('#282c34')

      root.__send__(:on_theme_changed)
      expected = Shared::AppTheme.derived(Tuile::Color.hex('#282c34'))
      assert_equal expected.dark[:pane_bg], screen.theme_def.dark[:pane_bg]
      assert_equal expected.dark[:pane_frame], screen.theme_def.dark[:pane_frame]
    end

    it 'settles rather than recursing — the derivation is deterministic' do
      screen = Tuile::Screen.instance
      screen.content = root
      screen.background_color = Tuile::Color.hex('#1e1e2e')

      root.__send__(:on_theme_changed)
      before = screen.theme
      root.__send__(:on_theme_changed)
      assert_equal before, screen.theme
    end
  end
end
