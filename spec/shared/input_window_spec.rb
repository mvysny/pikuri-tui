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

  it 'frames an editable TextArea as its content' do
    assert_kind_of Tuile::Component::TextArea, window.content
  end

  it 'cascades focus onto the inner text area when the window is focused' do
    screen = Tuile::Screen.instance
    screen.content = window
    screen.focused = window
    # Window is focusable but delegates focus to its content, so the caret
    # lands on the text area — the host focuses the window, not the area.
    assert_same window.content, screen.focused
  end

  it 'forwards Enter submissions from the framed input to on_submit, then clears' do
    screen = Tuile::Screen.instance
    screen.content = window
    screen.focused = window
    window.content.text = 'hello'
    screen.send(:handle_key, Tuile::Keys::ENTER)
    assert_equal ['hello'], submitted
    assert_equal '', window.content.text.to_s
  end

  it 'clears the buffer BEFORE invoking on_submit (a redrawing handler sees it empty)' do
    seen = nil
    win = described_class.new(on_submit: ->(_text) { seen = win.content.text.to_s })
    screen = Tuile::Screen.instance
    screen.content = win
    screen.focused = win
    win.content.text = 'hi'
    screen.send(:handle_key, Tuile::Keys::ENTER)
    assert_equal '', seen
  end

  it 'treats Enter on a blank buffer as a consumed no-op' do
    screen = Tuile::Screen.instance
    screen.content = window
    screen.focused = window
    window.content.text = '   '
    screen.send(:handle_key, Tuile::Keys::ENTER)
    assert_empty submitted
  end
end
