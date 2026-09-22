# frozen_string_literal: true

RSpec.describe Computer::Layout do
  let(:conversation) { Shared::ConversationTextView.new }
  let(:status_rule)  { Shared::StatusRuleLabel.new(token_log: Pikuri::Agent::Listener::TokenLog.new) }
  let(:input)        { Shared::InputPane.new(on_submit: ->(_text) {}) }
  let(:layout)       { described_class.new(conversation: conversation, status_rule: status_rule, input: input) }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  it 'stacks the conversation over a one-row status rule over the prompt, with no sidebar' do
    Tuile::Testing.place(layout, Tuile::Rect.new(0, 0, 80, 24))
    inset = described_class::CONTENT_INSET
    top_h = 24 - described_class::INPUT_HEIGHT - 1

    assert_equal Tuile::Rect.new(inset, 0, 80 - inset, top_h), conversation.rect
    assert_equal Tuile::Rect.new(0, top_h, 80, 1), status_rule.rect
    assert_equal Tuile::Rect.new(0, top_h + 1, 80, described_class::INPUT_HEIGHT), input.rect
  end

  it 'starves the prompt first, then the rule, on a terminal too short for all three' do
    Tuile::Testing.place(layout, Tuile::Rect.new(0, 0, 80, 3))
    assert_equal 3, input.rect.height
    assert_equal 0, status_rule.rect.height
    assert_equal 0, conversation.rect.height
  end

  it 'exposes the three panes it lays out' do
    assert_same conversation, layout.conversation
    assert_same status_rule, layout.status_rule
    assert_same input, layout.input
  end
end
