# frozen_string_literal: true

RSpec.describe Shared::UIToggleMenu do
  let(:conversation) { Shared::ConversationTextView.new }
  let(:menu)         { described_class.new(screen: Tuile::Screen.instance, conversation: conversation) }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  def press(key) = Tuile::Screen.instance.key(key)

  def labels = menu.actions.map(&:text)

  it 'offers the two display toggles, on t and v' do
    assert_equal %w[t v], menu.actions.map(&:key)
  end

  it 'labels each entry with the value in force right now' do
    assert_equal ['thinking: shown', 'tool lines: short'], labels

    conversation.toggle_thinking
    conversation.toggle_tool_detail
    assert_equal ['thinking: hidden', 'tool lines: verbose'], labels
  end

  it 'flips the pane when a key is picked' do
    menu.open
    press('t')
    # The menu defers each pick to the next event-loop turn, which the
    # keystroke finishes.
    refute conversation.show_thinking
  end

  it 'captions the popup UI, so it reads apart from the leader menu' do
    menu.open
    assert_includes Tuile::Screen.instance.pane.modal_popup.caption.to_s, described_class::CAPTION
  end
end
