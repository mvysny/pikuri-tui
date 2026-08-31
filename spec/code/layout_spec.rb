# frozen_string_literal: true

RSpec.describe Code::Layout do
  let(:conversation) { Shared::ConversationTextView.new }
  let(:status_rule)  { Shared::StatusRuleLabel.new(token_log: Pikuri::Agent::Listener::TokenLog.new) }
  let(:input)        { Shared::InputPane.new(on_submit: ->(_text) {}) }
  let(:sidebar)      { Code::WorkspaceSidebar.new }
  let(:layout) do
    described_class.new(conversation: conversation, status_rule: status_rule, input: input, sidebar: sidebar)
  end

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  # A width comfortably above MIN_SIDEBAR_WIDTH / MIN_CONVERSATION_WIDTH.
  WIDE = 120
  TALL = 30

  def top_height = TALL - described_class::INPUT_HEIGHT - 1

  it 'runs the status rule and the prompt full width, under both columns' do
    layout.rect = Tuile::Rect.new(0, 0, WIDE, TALL)
    assert_equal Tuile::Rect.new(0, top_height, WIDE, 1), status_rule.rect
    assert_equal Tuile::Rect.new(0, top_height + 1, WIDE, described_class::INPUT_HEIGHT), input.rect
  end

  it 'splits the upper region into conversation | separator | sidebar' do
    layout.rect = Tuile::Rect.new(0, 0, WIDE, TALL)
    right_w = (WIDE * described_class::SIDEBAR_FRACTION).round
    left_w = WIDE - right_w - 1
    inset = described_class::CONTENT_INSET

    assert_equal Tuile::Rect.new(inset, 0, left_w - inset, top_height), conversation.rect
    assert_equal Tuile::Rect.new(left_w, 0, 1, top_height), layout.separator.rect
    assert_equal Tuile::Rect.new(left_w + 1, 0, right_w, top_height), sidebar.rect
  end

  it 'draws the separator as one :pane_frame │ per row of the upper region' do
    layout.rect = Tuile::Rect.new(0, 0, WIDE, TALL)
    assert_equal Array.new(top_height, '│').join("\n"), layout.separator.text.to_s
    assert(layout.separator.text.spans.all? { |span| span.style.fg == Tuile::Screen.instance.theme[:pane_frame] })
  end

  it 'tints the separator so it belongs to the sidebar side of the boundary' do
    assert_equal Tuile::Theme.ref(:pane_bg), layout.separator.bg_color
  end

  it 'collapses the sidebar and its separator on a terminal too narrow for both' do
    layout.rect = Tuile::Rect.new(0, 0, 40, TALL)
    assert sidebar.rect.empty?
    assert layout.separator.rect.empty?
    assert_equal 40 - described_class::CONTENT_INSET, conversation.rect.width
  end

  it 'keeps the prompt full width even when the sidebar collapses' do
    layout.rect = Tuile::Rect.new(0, 0, 40, TALL)
    assert_equal 40, input.rect.width
  end

  it 're-tones the separator on a light/dark flip' do
    layout.rect = Tuile::Rect.new(0, 0, WIDE, TALL)
    Tuile::Screen.instance.theme = Shared::AppTheme::LIGHT
    layout.__send__(:on_theme_changed)
    assert(layout.separator.text.spans.all? { |span| span.style.fg == Shared::AppTheme::LIGHT[:pane_frame] })
  end
end
