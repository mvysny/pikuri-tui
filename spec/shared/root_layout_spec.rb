# frozen_string_literal: true

RSpec.describe Shared::RootLayout do
  # A shell layout only has to be a component to be stacked; a Label stands in.
  let(:shell) { Tuile::Component::Label.new('shell') }
  let(:status_bar) { Shared::StatusBar.new }
  let(:root) { described_class.new(shell, status_bar) }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  it 'gives the status bar the last row and the shell every row above it' do
    Tuile::Testing.place(root, Tuile::Rect.new(0, 0, 40, 10))
    assert_equal Tuile::Rect.new(0, 0, 40, 9), shell.rect
    assert_equal Tuile::Rect.new(0, 9, 40, 1), status_bar.rect
  end

  it 'exposes both children' do
    assert_same shell, root.shell
    assert_same status_bar, root.status_bar
  end
end
