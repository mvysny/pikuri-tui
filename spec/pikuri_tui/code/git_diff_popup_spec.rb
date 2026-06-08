# frozen_string_literal: true

RSpec.describe PikuriTui::Code::GitDiffPopup do
  let(:diff_view)   { Tuile::Component::TextView.new }
  let(:diff_window) { Tuile::Component::Window.new('Git diff').tap { _1.content = diff_view } }
  let(:popup)       { described_class.new(diff_window: diff_window) }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  it 'wraps the given window as its content' do
    assert_same diff_window, popup.content
  end

  it 'opens and closes on the screen' do
    refute popup.open?
    popup.open
    assert popup.open?
    popup.close
    refute popup.open?
  end

  it 'allows a far taller popup than the base 12-row cap' do
    assert_operator popup.max_height, :>, Tuile::Component::Popup.new.max_height
  end
end
