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

  describe 'prompt history' do
    let(:area) { window.content }

    before do
      screen = Tuile::Screen.instance
      screen.content = window
      screen.focused = window
    end

    def press(key) = Tuile::Screen.instance.send(:handle_key, key)

    def submit(text)
      area.text = text
      press(Tuile::Keys::ENTER)
    end

    it 'recalls the previous message on Up, caret at the end' do
      submit('deploy staging')
      press(Tuile::Keys::UP_ARROW)
      assert_equal 'deploy staging', area.text.to_s
      assert_equal 'deploy staging'.length, area.caret
    end

    it 'walks back through older messages and forward again to the draft' do
      submit('first')
      submit('second')
      area.text = 'half typed'
      area.caret = area.text.length

      press(Tuile::Keys::UP_ARROW)
      assert_equal 'second', area.text.to_s
      press(Tuile::Keys::UP_ARROW)
      assert_equal 'first', area.text.to_s
      press(Tuile::Keys::DOWN_ARROW)
      assert_equal 'second', area.text.to_s
      press(Tuile::Keys::DOWN_ARROW)
      assert_equal 'half typed', area.text.to_s
    end

    it 'sends a recalled message verbatim on Enter' do
      submit('run the tests')
      press(Tuile::Keys::UP_ARROW)
      press(Tuile::Keys::ENTER)
      assert_equal ['run the tests', 'run the tests'], submitted
      assert_equal '', area.text.to_s
    end

    it 'shows an entry as submitted even after it was edited and left' do
      submit('first')
      submit('second')
      press(Tuile::Keys::UP_ARROW) # => 'second'
      press('!')                   # edit it, but never send
      assert_equal 'second!', area.text.to_s

      press(Tuile::Keys::UP_ARROW)   # => 'first'
      press(Tuile::Keys::DOWN_ARROW) # back to 'second', as submitted
      assert_equal 'second', area.text.to_s
    end

    it 'moves the caret instead of recalling while there is a row above' do
      submit('sent')
      area.text = "two\nlines"
      area.caret = area.text.length

      press(Tuile::Keys::UP_ARROW)
      assert_equal "two\nlines", area.text.to_s
      assert_equal 0, area.caret_row
    end

    it "leaves TextArea's edge snap in place when history has nothing to give" do
      area.text = 'unsent'
      area.caret = area.text.length
      press(Tuile::Keys::UP_ARROW)
      # Declined, not consumed: the plain TextArea behaviour survives.
      assert_equal 'unsent', area.text.to_s
      assert_equal 0, area.caret
    end

    it 'returns to the draft on ESC, then clears the buffer on a second ESC' do
      submit('sent')
      area.text = 'half typed'
      area.caret = area.text.length
      press(Tuile::Keys::UP_ARROW)
      assert_equal 'sent', area.text.to_s

      press(Tuile::Keys::ESC)
      assert_equal 'half typed', area.text.to_s
      press(Tuile::Keys::ESC)
      assert_equal '', area.text.to_s
    end

    it 'keeps focus on ESC rather than clearing it like a plain field' do
      press(Tuile::Keys::ESC)
      assert_same area, Tuile::Screen.instance.focused
    end

    it 'does not record a blank submit' do
      submit('real message')
      area.text = '   '
      press(Tuile::Keys::ENTER)
      press(Tuile::Keys::UP_ARROW)
      assert_equal 'real message', area.text.to_s
    end
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

    it 'records slash commands in history too, though they never reach on_submit' do
      window.content.text = '/quit'
      press(Tuile::Keys::ENTER)
      press(Tuile::Keys::UP_ARROW)
      assert_equal '/quit', window.content.text.to_s
    end

    it 'leaves the palette shut when a recalled entry starts with a slash' do
      window.content.text = '/quit'
      press(Tuile::Keys::ENTER)
      press(Tuile::Keys::UP_ARROW)
      refute menu.visible?
    end

    it 'runs a recalled slash command on Enter, palette or no palette' do
      window.content.text = '/quit'
      press(Tuile::Keys::ENTER)
      press(Tuile::Keys::UP_ARROW)
      press(Tuile::Keys::ENTER)
      assert_equal [[:quit, ''], [:quit, '']], ran
    end

    it 'opens the palette again as soon as a recalled command is edited' do
      window.content.text = '/di'
      press(Tuile::Keys::ENTER) # unknown command, but still an entry
      press(Tuile::Keys::UP_ARROW)
      refute menu.visible?
      press('f')
      assert menu.visible?
      assert_equal '/dif', window.content.text.to_s
    end

    it 'lets the palette keep Up while it is shown, so recall never traps it' do
      window.content.text = 'a turn'
      press(Tuile::Keys::ENTER)
      window.content.text = '/'
      assert menu.visible?
      press(Tuile::Keys::UP_ARROW)
      # The palette moved its selection; the buffer was not overwritten by history.
      assert_equal '/', window.content.text.to_s
    end
  end
end
