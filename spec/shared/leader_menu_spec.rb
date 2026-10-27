# frozen_string_literal: true

RSpec.describe Shared::LeaderMenu do
  let(:menu) { described_class.new(screen: Tuile::Screen.instance) }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  # Drive keys as the terminal reports them (FakeScreen#key), so the action the
  # menu defers to the event queue has run once the keystroke returns: opening
  # the popup focuses the inner list and keys reach the picker by capture + bubble.
  def press(key) = Tuile::Screen.instance.key(key)

  def modal_overlay = Tuile::Screen.instance.pane.modal_overlay

  # The picker's list holds Option items and renders them at paint time, so the
  # rows are read off the painted buffer.
  def painted_rows
    Tuile::Testing.place(modal_overlay, Tuile::Rect.new(0, 0, 30, 4))
    painted_region(modal_overlay.content).map(&:strip).reject(&:empty?)
  end

  it 'is empty until an action is added' do
    assert menu.empty?
    menu.add('l', 'logs') {}
    refute menu.empty?
  end

  it 'returns self from #add so registrations chain' do
    assert_same menu, menu.add('l', 'logs') {}
  end

  it 'raises when #add is given no block' do
    assert_raises(ArgumentError) { menu.add('l', 'logs') }
  end

  it 'exposes registered actions in registration order' do
    menu.add('l', 'logs') {}
    menu.add('q', 'quit') {}
    assert_equal %w[l q], menu.actions.map(&:key)
    assert_equal ['logs', 'quit'], menu.actions.map(&:label)
  end

  it 'resolves a callable label each time it opens, so a toggle can advertise its state' do
    state = 'shown'
    menu.add('t', -> { "thinking: #{state}" }) {}
    menu.open
    assert_includes painted_rows, 't thinking: shown'

    state = 'hidden'
    menu.open
    assert_includes painted_rows, 't thinking: hidden'
  end

  it 'captions the popup Menu by default, and whatever a submenu asks for' do
    menu.add('l', 'logs') {}
    menu.open
    assert_includes modal_overlay.caption.to_s, described_class::CAPTION

    submenu = described_class.new(screen: Tuile::Screen.instance, caption: 'UI')
    submenu.add('t', 'thinking') {}
    submenu.open
    assert_includes modal_overlay.caption.to_s, 'UI'
  end

  it 'does not open a popup when no actions are registered' do
    menu.open
    assert_nil modal_overlay, 'an empty menu must not open a popup'
  end

  it 'opens a modal popup whose list shows each action as "key label"' do
    menu.add('l', 'logs') {}
    menu.add('q', 'quit') {}
    menu.open

    picker = modal_overlay
    assert_kind_of Tuile::Component::PickerDialog, picker
    # The picker's list holds Option items and renders them at paint time, so the
    # rows are read off the painted buffer.
    Tuile::Testing.place(modal_overlay, Tuile::Rect.new(0, 0, 20, 4))
    rows = painted_region(picker.content).map(&:strip)
    assert_equal ['l logs', 'q quit'], rows.reject(&:empty?)
  end

  it 'runs the matching action and closes the menu when its key is pressed' do
    ran = []
    menu.add('l', 'logs') { ran << :logs }
    menu.add('q', 'quit') { ran << :quit }
    menu.open

    press('q')
    assert_equal [:quit], ran
    assert_nil modal_overlay, 'picking an action closes the menu'
  end

  it 'keeps the menu open and runs nothing on an unbound key' do
    ran = []
    menu.add('l', 'logs') { ran << :logs }
    menu.open

    press('x')
    assert_empty ran
    refute_nil modal_overlay, 'an unbound key leaves the menu open'
  end

  it 'dismisses the menu on ESC without running anything' do
    ran = []
    menu.add('l', 'logs') { ran << :logs }
    menu.open

    press(Tuile::Keys::ESC)
    assert_empty ran
    assert_nil modal_overlay, 'ESC cancels the menu'
  end

  it 'dismisses the menu on Ctrl+C without running anything, exactly like ESC' do
    ran = []
    menu.add('l', 'logs') { ran << :logs }
    menu.open

    press(Tuile::Keys::CTRL_C)
    assert_empty ran
    assert_nil modal_overlay, 'Ctrl+C cancels the menu'
  end

  it 'defers the action through the screen event queue (menu closes before it runs)' do
    deferred = []
    Tuile::Screen.instance.event_queue.define_singleton_method(:submit) do |&blk|
      deferred << blk
    end
    menu.add('l', 'logs') { raise 'should not run synchronously' }
    menu.open

    press('l')
    assert_equal 1, deferred.size, 'the action must be submitted, not run inline'
  end
end
