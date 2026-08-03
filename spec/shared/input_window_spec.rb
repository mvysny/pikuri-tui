# frozen_string_literal: true

RSpec.describe Shared::InputWindow do
  let(:submitted) { [] }
  let(:window)    { described_class.new(on_submit: ->(text) { submitted << text }) }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  it 'stands up as a titled "Prompt" Tuile Window' do
    assert_kind_of Tuile::Component::Window, window
    assert_equal 'Prompt', window.caption.to_s
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

  describe 'with a slash menu' do
    let(:token_log)    { Pikuri::Agent::Listener::TokenLog.new }
    let(:conversation) { Shared::ConversationWindow.new(token_log: token_log) }
    let(:ran)          { [] } # [symbol, rest] pairs
    let(:commands) do
      [Shared::SlashCommand.new('/diff', 'show the git diff', ->(rest) { ran << [:diff, rest]; 'Opened the git diff.' }),
       Shared::SlashCommand.new('/quit', 'quits the app',     ->(rest) { ran << [:quit, rest]; nil })]
    end
    let(:menu) do
      Shared::SlashMenuPopup.new(screen: Tuile::Screen.instance, commands: commands, conversation: conversation)
    end
    let(:window) { described_class.new(on_submit: ->(text) { submitted << text }, slash_menu: menu) }

    before do
      screen = Tuile::Screen.instance
      screen.content = window
      screen.focused = window
    end

    def press(key) = Tuile::Screen.instance.send(:handle_key, key)

    it 'makes the window the palette anchor' do
      assert_same window, menu.anchor
    end

    it 'opens the palette as soon as the buffer starts with a slash' do
      window.content.text = '/'
      assert menu.visible?
    end

    it 'closes the palette when the buffer stops being a slash command' do
      window.content.text = '/'
      window.content.text = 'hello'
      refute menu.visible?
    end

    it 'runs the slash command on Enter instead of submitting a turn, then clears' do
      window.content.text = '/quit'
      press(Tuile::Keys::ENTER)
      assert_equal [[:quit, '']], ran
      assert_empty submitted
      assert_equal '', window.content.text.to_s
    end

    it 'runs a slash command with a trailing argument (palette already hidden past the space)' do
      window.content.text = '/diff run the migration'
      refute menu.visible?
      press(Tuile::Keys::ENTER)
      assert_equal [[:diff, 'run the migration']], ran
      assert_empty submitted
      assert_equal '', window.content.text.to_s
    end

    it 'blocks an unknown slash command from reaching the agent' do
      window.content.text = '/nope'
      press(Tuile::Keys::ENTER)
      assert_empty submitted
      assert_includes conversation.view.text.to_s, 'Command not found'
    end

    it 'forwards Down to the palette while it is shown, so Enter runs the selection' do
      window.content.text = '/'
      press(Tuile::Keys::DOWN_ARROW) # /diff -> /quit
      press(Tuile::Keys::ENTER)
      assert_equal [[:quit, '']], ran
    end

    it 'still submits an ordinary turn on Enter when the buffer is not a slash' do
      window.content.text = 'hello there'
      press(Tuile::Keys::ENTER)
      assert_equal ['hello there'], submitted
      assert_empty ran
    end
  end
end
