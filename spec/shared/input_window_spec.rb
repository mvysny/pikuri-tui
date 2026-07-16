# frozen_string_literal: true

RSpec.describe Shared::InputWindow do
  let(:submitted) { [] }
  let(:window)    { described_class.new(on_submit: ->(text) { submitted << text }) }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  it 'stands up as a titled "Prompt" Tuile Window' do
    assert_kind_of Tuile::Component::Window, window
    assert_equal 'Prompt', window.caption
  end

  it 'frames a Shared::InputArea as its content' do
    assert_kind_of Shared::InputArea, window.content
  end

  it 'cascades focus onto the inner InputArea when the window is focused' do
    screen = Tuile::Screen.instance
    screen.content = window
    screen.focused = window
    # Window is focusable but delegates focus to its content, so the caret
    # lands on the InputArea — the host focuses the window, not the area.
    assert_same window.content, screen.focused
  end

  it 'forwards Enter submissions from the framed InputArea to on_submit' do
    screen = Tuile::Screen.instance
    screen.content = window
    screen.focused = window
    window.content.text = 'hello'
    screen.send(:handle_key, Tuile::Keys::ENTER)
    assert_equal ['hello'], submitted
    assert_equal '', window.content.text.to_s
  end
end
