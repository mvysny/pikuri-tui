# frozen_string_literal: true

RSpec.describe Shared::InputPane do
  let(:submitted) { [] }
  let(:window)    { described_class.new(on_submit: ->(text) { submitted << text }) }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  it 'stands up as an unframed layout tinted with the secondary-pane background' do
    assert_kind_of Tuile::Component::Layout, window
    assert_equal Tuile::Theme.ref(:pane_bg), window.bg_color
  end

  it 'wraps an editable TextArea' do
    assert_kind_of Tuile::Component::TextArea, window.area
  end

  it 'puts the caret on the text area when the pane is focused' do
    screen = Tuile::Screen.instance
    screen.content = window
    window.focus
    # A Layout cascades nothing, so the pane forwards #focus onto the area
    # itself — the host focuses the pane, not the area.
    assert_same window.area, screen.focused
  end

  it 'hangs the marker off the left edge, with the area starting past it' do
    Tuile::Testing.place(window, Tuile::Rect.new(0, 0, 40, described_class::HEIGHT))
    width = described_class::MARKER_WIDTH
    # The marker owns one row at column 0; every row is editable.
    assert_equal Tuile::Rect.new(0, 0, width, 1), window.instance_variable_get(:@marker).rect
    assert_equal Tuile::Rect.new(width, 0, 40 - width - described_class::TRAILING_PAD, described_class::HEIGHT),
                 window.area.rect
  end

  it 'leaves only the trailing pad unclaimed, so the buffer gets the rest' do
    Tuile::Testing.place(window, Tuile::Rect.new(0, 0, 40, described_class::HEIGHT))
    assert_equal 40 - described_class::MARKER_WIDTH - described_class::TRAILING_PAD, window.area.rect.width
  end

  it 'floors the area width at 0 on a pane too narrow for the marker and pad' do
    Tuile::Testing.place(window, Tuile::Rect.new(0, 0, 2, described_class::HEIGHT))
    assert_equal 0, window.area.rect.width
  end

  it 'paints the buffer on the inherited pane tint, not on a well of its own' do
    screen = Tuile::Screen.instance
    holder = Tuile::Component::Layout::Absolute.new
    screen.content = holder
    holder.add(window, Tuile::Rect.new(0, 0, 40, described_class::HEIGHT))
    screen.flush_layout
    tint = screen.theme[:pane_bg]
    # The buffer's own column, read off the painted cells rather than off
    # bg_color: Tuile's AbstractStringField resolves a well of its own
    # (input_bg_color, active_bg_color once focused) unless INHERIT sends it
    # to the parent, and a shade flip on focus is exactly what we removed.
    buffer_cell = lambda do
      screen.needs_full_repaint
      screen.repaint
      screen.buffer.cell(described_class::MARKER_WIDTH, 0).style.bg
    end
    assert_equal tint, buffer_cell.call
    window.focus
    assert_equal tint, buffer_cell.call
    refute_equal screen.theme.active_bg_color, tint
  end

  it 'forwards Enter submissions from the framed input to on_submit, then clears' do
    screen = Tuile::Screen.instance
    screen.content = window
    window.focus
    window.area.value = 'hello'
    screen.send(:handle_key?, Tuile::Keys::ENTER)
    assert_equal ['hello'], submitted
    assert_equal '', window.area.text.to_s
  end

  it 'clears the buffer BEFORE invoking on_submit (a redrawing handler sees it empty)' do
    seen = nil
    win = described_class.new(on_submit: ->(_text) { seen = win.area.text.to_s })
    screen = Tuile::Screen.instance
    screen.content = win
    win.focus
    win.area.value = 'hi'
    screen.send(:handle_key?, Tuile::Keys::ENTER)
    assert_equal '', seen
  end

  it 'treats Enter on a blank buffer as a consumed no-op' do
    screen = Tuile::Screen.instance
    screen.content = window
    window.focus
    window.area.value = '   '
    screen.send(:handle_key?, Tuile::Keys::ENTER)
    assert_empty submitted
  end

  describe 'a captured answer' do
    let(:answers) { [] }
    let(:area)    { window.area }

    before do
      screen = Tuile::Screen.instance
      screen.content = window
      window.focus
    end

    def capture(initial: '')
      window.capture(marker: '✎', initial: initial) { |text| answers << text }
    end

    def press(key) = Tuile::Screen.instance.send(:handle_key?, key)

    it 'pre-fills the buffer and takes the caret' do
      capture(initial: 'summarize CVEs')
      assert_equal 'summarize CVEs', area.text.to_s
      assert_predicate window, :capturing?
      assert_same area, Tuile::Screen.instance.focused
    end

    it 'wears its own marker while borrowed, and gives it back after' do
      capture
      assert_includes window.instance_variable_get(:@marker).text.to_s, '✎'
      press(Tuile::Keys::ENTER)
      assert_includes window.instance_variable_get(:@marker).text.to_s, described_class::MARKER
    end

    it 'sends the answer on Enter instead of submitting a turn, then clears' do
      capture
      area.value = 'use the other library'
      press(Tuile::Keys::ENTER)
      assert_equal ['use the other library'], answers
      assert_empty submitted
      assert_equal '', area.text.to_s
      refute_predicate window, :capturing?
    end

    it 'sends an emptied buffer as an answer (blank is a decision, not a no-op)' do
      capture(initial: 'draft')
      area.value = ''
      press(Tuile::Keys::ENTER)
      assert_equal [''], answers
    end

    it 'cancels with nil on ESC' do
      capture(initial: 'draft')
      press(Tuile::Keys::ESC)
      assert_equal [nil], answers
      assert_equal '', area.text.to_s
    end

    it 'cancels with nil on #cancel_capture (what an interrupt calls)' do
      capture
      window.cancel_capture
      assert_equal [nil], answers
    end

    it 'is a no-op to cancel when nothing is captured' do
      window.cancel_capture
      assert_empty answers
    end

    it 'keeps a leading slash literal — an answer is text, not a command' do
      capture
      area.value = '/etc/hosts is the wrong file'
      press(Tuile::Keys::ENTER)
      assert_equal ['/etc/hosts is the wrong file'], answers
    end

    it 'opens no palette for a slash typed into an answer' do
      menu = Shared::SlashMenuPopup.new(
        screen: Tuile::Screen.instance,
        commands: [Shared::SlashCommand.new('/logs', 'open the log', ->(_rest) { nil })],
        conversation: Shared::ConversationTextView.new
      )
      pane = described_class.new(on_submit: ->(_text) {}, slash_menu: menu)
      Tuile::Screen.instance.content = pane
      pane.focus
      pane.capture(marker: '✎') { |text| answers << text }
      pane.area.value = '/lo'
      refute_predicate menu, :visible?
    end

    it 'dismisses a palette left open by the abandoned draft, which would claim ESC' do
      menu = Shared::SlashMenuPopup.new(
        screen: Tuile::Screen.instance,
        commands: [Shared::SlashCommand.new('/logs', 'open the log', ->(_rest) { nil })],
        conversation: Shared::ConversationTextView.new
      )
      pane = described_class.new(on_submit: ->(_text) {}, slash_menu: menu)
      Tuile::Screen.instance.content = pane
      pane.focus
      pane.area.value = '/lo'
      assert_predicate menu, :visible?
      pane.capture(marker: '✎') { |text| answers << text }
      refute_predicate menu, :visible?
      Tuile::Screen.instance.send(:handle_key?, Tuile::Keys::ESC)
      assert_equal [nil], answers
    end

    it 'stays out of the history: the answer is not recallable as a turn' do
      area.value = 'a real turn'
      press(Tuile::Keys::ENTER)
      capture
      area.value = 'an answer'
      press(Tuile::Keys::ENTER)
      press(Tuile::Keys::UP_ARROW)
      assert_equal 'a real turn', area.text.to_s
    end
  end

  describe 'prompt history' do
    let(:area) { window.area }

    before do
      screen = Tuile::Screen.instance
      screen.content = window
      window.focus
    end

    def press(key) = Tuile::Screen.instance.send(:handle_key?, key)

    def submit(text)
      area.value = text
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
      area.value = 'half typed'
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
      area.value = "two\nlines"
      area.caret = area.text.length

      press(Tuile::Keys::UP_ARROW)
      assert_equal "two\nlines", area.text.to_s
      assert_equal 0, area.caret_row
    end

    it "leaves TextArea's edge snap in place when history has nothing to give" do
      area.value = 'unsent'
      area.caret = area.text.length
      press(Tuile::Keys::UP_ARROW)
      # Declined, not consumed: the plain TextArea behaviour survives.
      assert_equal 'unsent', area.text.to_s
      assert_equal 0, area.caret
    end

    it 'returns to the draft on ESC, then clears the buffer on a second ESC' do
      submit('sent')
      area.value = 'half typed'
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
      area.value = '   '
      press(Tuile::Keys::ENTER)
      press(Tuile::Keys::UP_ARROW)
      assert_equal 'real message', area.text.to_s
    end
  end

  describe 'with a slash menu' do
    let(:token_log)    { Pikuri::Agent::Listener::TokenLog.new }
    let(:conversation) { Shared::ConversationTextView.new }
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
      window.focus
    end

    def press(key) = Tuile::Screen.instance.send(:handle_key?, key)

    it 'makes the window the palette anchor' do
      assert_same window, menu.anchor
    end

    it 'opens the palette as soon as the buffer starts with a slash' do
      window.area.value = '/'
      assert menu.visible?
    end

    it 'closes the palette when the buffer stops being a slash command' do
      window.area.value = '/'
      window.area.value = 'hello'
      refute menu.visible?
    end

    it 'runs the slash command on Enter instead of submitting a turn, then clears' do
      window.area.value = '/quit'
      press(Tuile::Keys::ENTER)
      assert_equal [[:quit, '']], ran
      assert_empty submitted
      assert_equal '', window.area.text.to_s
    end

    it 'runs a slash command with a trailing argument (palette already hidden past the space)' do
      window.area.value = '/diff run the migration'
      refute menu.visible?
      press(Tuile::Keys::ENTER)
      assert_equal [[:diff, 'run the migration']], ran
      assert_empty submitted
      assert_equal '', window.area.text.to_s
    end

    it 'blocks an unknown slash command from reaching the agent' do
      window.area.value = '/nope'
      press(Tuile::Keys::ENTER)
      assert_empty submitted
      assert_includes conversation.text.to_s, 'Command not found'
    end

    it 'forwards Down to the palette while it is shown, so Enter runs the selection' do
      window.area.value = '/'
      press(Tuile::Keys::DOWN_ARROW) # /diff -> /quit
      press(Tuile::Keys::ENTER)
      assert_equal [[:quit, '']], ran
    end

    it 'still submits an ordinary turn on Enter when the buffer is not a slash' do
      window.area.value = 'hello there'
      press(Tuile::Keys::ENTER)
      assert_equal ['hello there'], submitted
      assert_empty ran
    end

    it 'records slash commands in history too, though they never reach on_submit' do
      window.area.value = '/quit'
      press(Tuile::Keys::ENTER)
      press(Tuile::Keys::UP_ARROW)
      assert_equal '/quit', window.area.text.to_s
    end

    it 'leaves the palette shut when a recalled entry starts with a slash' do
      window.area.value = '/quit'
      press(Tuile::Keys::ENTER)
      press(Tuile::Keys::UP_ARROW)
      refute menu.visible?
    end

    it 'runs a recalled slash command on Enter, palette or no palette' do
      window.area.value = '/quit'
      press(Tuile::Keys::ENTER)
      press(Tuile::Keys::UP_ARROW)
      press(Tuile::Keys::ENTER)
      assert_equal [[:quit, ''], [:quit, '']], ran
    end

    it 'opens the palette again as soon as a recalled command is edited' do
      window.area.value = '/di'
      press(Tuile::Keys::ENTER) # unknown command, but still an entry
      press(Tuile::Keys::UP_ARROW)
      refute menu.visible?
      press('f')
      assert menu.visible?
      assert_equal '/dif', window.area.text.to_s
    end

    it 'lets the palette keep Up while it is shown, so recall never traps it' do
      window.area.value = 'a turn'
      press(Tuile::Keys::ENTER)
      window.area.value = '/'
      assert menu.visible?
      press(Tuile::Keys::UP_ARROW)
      # The palette moved its selection; the buffer was not overwritten by history.
      assert_equal '/', window.area.text.to_s
    end
  end

  describe 'paging the conversation' do
    let(:token_log)    { Pikuri::Agent::Listener::TokenLog.new }
    let(:conversation) { Shared::ConversationTextView.new }
    let(:commands)     { [Shared::SlashCommand.new('/quit', 'quits the app', ->(_rest) { nil })] }
    let(:menu) do
      Shared::SlashMenuPopup.new(screen: Tuile::Screen.instance, commands: commands, conversation: conversation)
    end
    let(:window) do
      described_class.new(on_submit: ->(text) { submitted << text }, conversation: conversation)
    end
    let(:half_page) { conversation.rect.height / 2 }

    before do
      screen = Tuile::Screen.instance
      Tuile::Testing.place(conversation, Tuile::Rect.new(0, 0, 40, 10))
      30.times { |i| conversation.add_block("line #{i}") }
      screen.content = window
      window.focus
    end

    def press(key) = Tuile::Screen.instance.send(:handle_key?, key)

    it 'pages the transcript down half a screen on PageDown' do
      conversation.scroll_top_row = 0
      press(Tuile::Keys::PAGE_DOWN)
      assert_equal half_page, conversation.scroll_top_row
    end

    it 'pages the transcript up half a screen on PageUp' do
      conversation.scroll_top_row = 10
      press(Tuile::Keys::PAGE_UP)
      assert_equal 10 - half_page, conversation.scroll_top_row
    end

    it 'leaves the prompt buffer and caret untouched while paging' do
      window.area.value = 'half typed'
      window.area.caret = 4
      press(Tuile::Keys::PAGE_UP)
      assert_equal 'half typed', window.area.text.to_s
      assert_equal 4, window.area.caret
    end

    it 'clamps at the top rather than raising' do
      conversation.scroll_top_row = 0
      press(Tuile::Keys::PAGE_UP)
      assert_equal 0, conversation.scroll_top_row
    end

    it 'leaves the page keys alone without a conversation' do
      plain = described_class.new(on_submit: ->(text) { submitted << text })
      Tuile::Screen.instance.content = plain
      plain.focus
      refute plain.area.handle_key?(Tuile::Keys::PAGE_UP)
    end

    context 'with the slash palette open' do
      let(:window) do
        described_class.new(on_submit: ->(text) { submitted << text }, slash_menu: menu, conversation: conversation)
      end

      it 'pages the palette, not the transcript' do
        conversation.scroll_top_row = 5
        window.area.value = '/'
        assert menu.visible?
        press(Tuile::Keys::PAGE_DOWN)
        assert_equal 5, conversation.scroll_top_row
      end

      it 'pages the transcript again once the palette is gone' do
        conversation.scroll_top_row = 5
        window.area.value = ''
        refute menu.visible?
        press(Tuile::Keys::PAGE_DOWN)
        assert_equal 5 + half_page, conversation.scroll_top_row
      end
    end
  end
end
