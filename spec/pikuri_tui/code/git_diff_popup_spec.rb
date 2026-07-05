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

  it 'is sized fullscreen so the diff has room' do
    popup.open
    assert_equal Tuile::Screen.instance.size.width, popup.rect.width
    assert_equal Tuile::Screen.instance.size.height, popup.rect.height
  end
end
