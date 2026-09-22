# frozen_string_literal: true

RSpec.describe Chat::Layout do
  let(:conversation) { Shared::ConversationTextView.new }
  let(:status_rule)  { Shared::StatusRuleLabel.new(token_log: Pikuri::Agent::Listener::TokenLog.new) }
  let(:input)        { Shared::InputPane.new(on_submit: ->(_text) {}) }
  let(:layout)       { described_class.new(conversation: conversation, status_rule: status_rule, input: input) }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  it 'stacks the conversation over a one-row status rule over the prompt' do
    layout.rect = Tuile::Rect.new(0, 0, 80, 24)
    settle(layout)
    inset = described_class::CONTENT_INSET
    top_h = 24 - described_class::INPUT_HEIGHT - 1

    assert_equal Tuile::Rect.new(inset, 0, 80 - inset, top_h), conversation.rect
    assert_equal Tuile::Rect.new(0, top_h, 80, 1), status_rule.rect
    assert_equal Tuile::Rect.new(0, top_h + 1, 80, described_class::INPUT_HEIGHT), input.rect
  end

  it 'insets the conversation to the prompt text column, and nothing else' do
    layout.rect = Tuile::Rect.new(0, 0, 80, 24)
    settle(layout)
    # The transcript's left edge lines up with the prompt's buffer (the ❯
    # hangs into the margin below it); the rule and the prompt well run full
    # width so the tint reads as a band.
    assert_equal Shared::InputPane::MARKER_WIDTH, conversation.rect.left
    # Both in screen coordinates: a rect is measured inside its parent now, and
    # the buffer's parent is the prompt well, not the layout.
    assert_equal input.area.absolute_rect.left, conversation.absolute_rect.left
    assert_equal 0, status_rule.rect.left
    assert_equal 0, input.rect.left
    assert_equal 80, status_rule.rect.width
    assert_equal 80, input.rect.width
  end

  it 'starves the prompt first, then the rule, on a terminal too short for all three' do
    layout.rect = Tuile::Rect.new(0, 0, 80, 3)
    settle(layout)
    assert_equal 3, input.rect.height
    assert_equal 0, status_rule.rect.height
    assert_equal 0, conversation.rect.height
  end

  it 'empties its children on an empty rect rather than handing out negative geometry' do
    layout.rect = Tuile::Rect.new(0, 0, 0, 0)
    settle(layout)
    assert conversation.rect.empty?
  end

  it 'exposes the three panes it lays out' do
    assert_same conversation, layout.conversation
    assert_same status_rule, layout.status_rule
    assert_same input, layout.input
  end
end
