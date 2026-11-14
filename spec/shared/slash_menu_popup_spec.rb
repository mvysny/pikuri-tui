# frozen_string_literal: true

RSpec.describe Shared::SlashMenuPopup do
  let(:conversation) { Shared::ConversationTextView.new }
  let(:ran)          { [] } # [symbol, rest] pairs, so tests assert the forwarded arg too
  let(:commands) do
    [Shared::SlashCommand.new('/diff', 'show the git diff', ->(rest) { ran << [:diff, rest]; 'Opened the git diff.' }),
     Shared::SlashCommand.new('/exit', 'quits the app', ->(rest) { ran << [:exit, rest]; nil }),
     Shared::SlashCommand.new('/quit', 'quits the app', ->(rest) { ran << [:quit, rest]; nil })]
  end
  let(:menu) do
    described_class.new(screen: Tuile::Screen.instance, commands: commands, conversation: conversation)
  end

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  def rendered
    Tuile::Testing.loop
    conversation.text.to_s
  end

  def list = menu.content

  # The list holds SlashCommands and renders them at paint time, so the rows are
  # read off the painted buffer (blank filler rows dropped).
  def rows
    painted_region(list).map(&:strip).reject(&:empty?)
  end

  it 'stands up as a non-modal, borderless Overlay wrapping a List directly' do
    # An Overlay, not a Popup: since tuile 0.14 Popup *is* the modal one, and
    # ListDropdown hangs off the bare Overlay instead.
    assert_kind_of Tuile::Component::Overlay, menu
    refute menu.modal?
    assert_kind_of Tuile::Component::List, list
    refute menu.visible?
  end

  it 'tints the panel with the ComboBox dropdown tint (:input_bg_color)' do
    assert_equal Tuile::Theme.ref(:input_bg_color), menu.bg_color
    # inherited down to the list so the rows + blank filler read as one panel
    assert_equal Tuile::Screen.instance.theme.input_bg_color, list.__send__(:bg).effective
  end

  describe '#sync opens, filters and closes off the buffer' do
    it 'opens on a bare slash and lists every command' do
      menu.sync('/')
      assert menu.visible?
      assert_equal 3, rows.size
    end

    it 'renders each row as two columns: name then description' do
      menu.sync('/')
      assert_equal ['/diff  show the git diff', '/exit  quits the app', '/quit  quits the app'], rows
    end

    it 'filters to commands whose name starts with the first word' do
      menu.sync('/d')
      assert_equal ['/diff  show the git diff'], rows
    end

    it 'closes when the buffer is not a slash command' do
      menu.sync('/')
      menu.sync('hello')
      refute menu.visible?
    end

    it 'closes when a slash prefix matches nothing' do
      menu.sync('/')
      menu.sync('/zzz')
      refute menu.visible?
    end

    it 'closes once the buffer has a space (past the command name into its argument)' do
      menu.sync('/diff')
      assert menu.visible?
      menu.sync('/diff run the thing')
      refute menu.visible?
    end

    it 'resets the selection to the top match on each refilter' do
      menu.sync('/')
      menu.handle_nav_key(Tuile::Keys::DOWN_ARROW)
      menu.sync('/q')
      assert_equal 0, list.cursor.position
    end
  end

  describe '#handle_nav_key' do
    before { menu.sync('/') }

    it 'moves the selection down and reports the key consumed' do
      assert menu.handle_nav_key(Tuile::Keys::DOWN_ARROW)
      assert_equal 1, list.cursor.position
    end

    it 'closes the palette on ESC' do
      assert menu.handle_nav_key(Tuile::Keys::ESC)
      refute menu.visible?
    end

    it 'declines keys it does not own' do
      refute menu.handle_nav_key('x')
    end
  end

  describe '#submit runs a command and echoes to the conversation, not the agent' do
    it 'runs the exact-named command and echoes its returned outcome below it' do
      menu.sync('/diff')
      menu.submit('/diff')
      Tuile::Testing.loop
      assert_equal [[:diff, '']], ran
      assert_includes rendered, '/diff'
      assert_includes rendered, 'Opened the git diff.'
      refute menu.visible?
    end

    it 'passes the rest of the line to the callback as its argument' do
      menu.submit('/diff run the migration')
      Tuile::Testing.loop
      assert_equal [[:diff, 'run the migration']], ran
    end

    it 'completes a partial buffer to the highlighted row' do
      menu.sync('/')
      menu.handle_nav_key(Tuile::Keys::DOWN_ARROW) # /diff -> /exit
      menu.submit('/')
      Tuile::Testing.loop
      assert_equal [[:exit, '']], ran
    end

    it 'echoes a red "Command not found" and runs nothing on an unknown command' do
      menu.submit('/nope')
      Tuile::Testing.loop
      assert_empty ran
      assert_includes rendered, '/nope'
      assert_includes rendered, 'Command not found'
    end

    it 'echoes nothing when the callback returns nil (the effect is its own feedback)' do
      menu.sync('/quit')
      menu.submit('/quit')
      Tuile::Testing.loop
      assert_equal [[:quit, '']], ran
      refute_includes rendered, '/quit'
    end
  end

  describe 'geometry' do
    it 'spans the screen width less one column each edge, ten rows tall' do
      menu.sync('/')
      Tuile::Screen.instance.flush_layout
      assert_equal 1, menu.rect.left
      assert_equal Tuile::Screen.instance.size.width - 2, menu.rect.width
      assert_equal 10, menu.rect.height
    end

    it 'anchors its bottom edge just above the anchor input' do
      # Mounted, since a detached anchor has no screen position to float over.
      input = Tuile::Component::Label.new
      holder = Tuile::Component::Layout::Absolute.new
      holder.add(input, Tuile::Rect.new(0, 20, 80, 4))
      Tuile::Screen.instance.content = holder
      menu.anchor = input
      menu.sync('/')
      Tuile::Screen.instance.flush_layout
      assert_equal 10, menu.rect.top # 20 (input top) - 10 (height)
    end
  end
end
