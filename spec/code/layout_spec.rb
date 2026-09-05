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

  it 'hides the sidebar and its separator on a terminal too narrow for both' do
    layout.rect = Tuile::Rect.new(0, 0, 40, TALL)
    refute_predicate sidebar, :visible?
    refute_predicate layout.separator, :visible?
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

  describe 'sidebar mode' do
    def widths = [conversation.rect.width, layout.separator.rect.width, sidebar.rect.width]

    it 'starts full — the fraction of the width' do
      assert_equal :full, layout.sidebar_mode
      layout.rect = Tuile::Rect.new(0, 0, WIDE, TALL)
      assert_equal (WIDE * described_class::SIDEBAR_FRACTION).round, sidebar.rect.width
    end

    it 'narrows the column to a fixed width, handing the rest to the conversation' do
      layout.rect = Tuile::Rect.new(0, 0, WIDE, TALL)
      layout.sidebar_mode = :narrow
      narrow = described_class::NARROW_SIDEBAR_WIDTH
      assert_equal [WIDE - narrow - 1 - described_class::CONTENT_INSET, 1, narrow], widths
    end

    it 'drops the sidebar and its separator entirely when hidden' do
      layout.rect = Tuile::Rect.new(0, 0, WIDE, TALL)
      layout.sidebar_mode = :hidden
      refute_predicate sidebar, :visible?
      refute_predicate layout.separator, :visible?
      assert_equal WIDE - described_class::CONTENT_INSET, conversation.rect.width
    end

    it 'gives the column its geometry back when it comes out of hiding' do
      layout.rect = Tuile::Rect.new(0, 0, WIDE, TALL)
      full = sidebar.rect
      layout.sidebar_mode = :hidden
      layout.sidebar_mode = :full
      assert_predicate sidebar, :visible?
      assert_equal full, sidebar.rect
      assert_equal Tuile::Rect.new(full.left - 1, 0, 1, top_height), layout.separator.rect
    end

    it 're-splits immediately, without waiting for a resize' do
      layout.rect = Tuile::Rect.new(0, 0, WIDE, TALL)
      before = sidebar.rect.width
      layout.sidebar_mode = :narrow
      refute_equal before, sidebar.rect.width
    end

    it 'keeps the prompt and status rule full width in every mode' do
      layout.rect = Tuile::Rect.new(0, 0, WIDE, TALL)
      described_class::SIDEBAR_MODES.each do |mode|
        layout.sidebar_mode = mode
        assert_equal WIDE, input.rect.width, "input in #{mode}"
        assert_equal WIDE, status_rule.rect.width, "status rule in #{mode}"
      end
    end

    it 'cycles full → narrow → hidden and back around' do
      layout.rect = Tuile::Rect.new(0, 0, WIDE, TALL)
      assert_equal %i[narrow hidden full], Array.new(3) { layout.cycle_sidebar_mode }
    end

    it 'raises on an unknown mode — our bug, with the offending value' do
      error = assert_raises(ArgumentError) { layout.sidebar_mode = :tiny }
      assert_includes error.message, ':tiny'
    end

    it 'still honors the starve floors: an explicit narrow is a request, not an override' do
      # 40 columns leaves the conversation under MIN_CONVERSATION_WIDTH once a
      # 24-column sidebar and its separator are taken out.
      layout.rect = Tuile::Rect.new(0, 0, 40, TALL)
      layout.sidebar_mode = :narrow
      refute_predicate sidebar, :visible?
      assert_equal 40, input.rect.width
    end

    it 'survives a mode change before it has a rect' do
      layout.sidebar_mode = :narrow
      assert_equal :narrow, layout.sidebar_mode
      layout.rect = Tuile::Rect.new(0, 0, WIDE, TALL)
      assert_equal described_class::NARROW_SIDEBAR_WIDTH, sidebar.rect.width
    end
  end

  describe '#on_sidebar_visibility' do
    it 'reports the sidebar visible once it first lays out' do
      seen = []
      layout.on_sidebar_visibility { |visible| seen << visible }
      layout.rect = Tuile::Rect.new(0, 0, WIDE, TALL)
      assert_equal [true], seen
      assert_predicate layout, :sidebar_visible?
    end

    it 'fires on a mode change' do
      layout.rect = Tuile::Rect.new(0, 0, WIDE, TALL)
      seen = []
      layout.on_sidebar_visibility { |visible| seen << visible }
      layout.sidebar_mode = :hidden
      layout.sidebar_mode = :full
      assert_equal [false, true], seen
    end

    it 'fires on a resize that collapses the column, which no host would see otherwise' do
      layout.rect = Tuile::Rect.new(0, 0, WIDE, TALL)
      seen = []
      layout.on_sidebar_visibility { |visible| seen << visible }
      layout.rect = Tuile::Rect.new(0, 0, 40, TALL)
      assert_equal [false], seen
      refute_predicate layout, :sidebar_visible?
    end

    it 'is edge-triggered: a reflow that changes nothing says nothing' do
      layout.rect = Tuile::Rect.new(0, 0, WIDE, TALL)
      seen = 0
      layout.on_sidebar_visibility { seen += 1 }
      layout.rect = Tuile::Rect.new(0, 0, WIDE - 4, TALL)
      layout.sidebar_mode = :narrow
      assert_equal 0, seen
    end

    it 'answers sidebar_visible? on the column, not the mode — a narrow mode can still collapse' do
      layout.rect = Tuile::Rect.new(0, 0, 40, TALL)
      layout.sidebar_mode = :narrow
      assert_equal :narrow, layout.sidebar_mode
      refute_predicate layout, :sidebar_visible?
    end
  end
end
