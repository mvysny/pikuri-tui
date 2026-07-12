# frozen_string_literal: true

RSpec.describe Shared::LeaderMenu do
  let(:menu) { described_class.new(screen: Tuile::Screen.instance) }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  # Drive keys through the real dispatcher (Screen#handle_key), exactly as
  # Tuile's own PickerWindow spec does: opening the popup focuses the inner
  # list and keys reach the picker / popup by capture + bubble.
  def press(key) = Tuile::Screen.instance.send(:handle_key, key)

  def modal_popup = Tuile::Screen.instance.pane.modal_popup

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

  it 'does not open a popup when no actions are registered' do
    menu.open
    assert_nil modal_popup, 'an empty menu must not open a popup'
  end

  it 'opens a modal popup whose list shows each action as "key label"' do
    menu.add('l', 'logs') {}
    menu.add('q', 'quit') {}
    menu.open

    assert_kind_of Tuile::Component::PickerWindow, modal_popup.content
    lines = modal_popup.content.content.lines.map(&:to_s)
    assert_equal ['l logs', 'q quit'], lines
  end

  it 'runs the matching action and closes the menu when its key is pressed' do
    ran = []
    menu.add('l', 'logs') { ran << :logs }
    menu.add('q', 'quit') { ran << :quit }
    menu.open

    press('q')
    assert_equal [:quit], ran
    assert_nil modal_popup, 'picking an action closes the menu'
  end

  it 'keeps the menu open and runs nothing on an unbound key' do
    ran = []
    menu.add('l', 'logs') { ran << :logs }
    menu.open

    press('x')
    assert_empty ran
    refute_nil modal_popup, 'an unbound key leaves the menu open'
  end

  it 'dismisses the menu on ESC without running anything' do
    ran = []
    menu.add('l', 'logs') { ran << :logs }
    menu.open

    press(Tuile::Keys::ESC)
    assert_empty ran
    assert_nil modal_popup, 'ESC cancels the menu'
  end

  it 'dismisses the menu on Ctrl+C without running anything, exactly like ESC' do
    ran = []
    menu.add('l', 'logs') { ran << :logs }
    menu.open

    press(Tuile::Keys::CTRL_C)
    assert_empty ran
    assert_nil modal_popup, 'Ctrl+C cancels the menu'
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
