# frozen_string_literal: true

RSpec.describe Code::TaskListPane do
  let(:window)   { described_class.new }
  let(:listener) { window.listener }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  # The pane renders in its own relayout, so a read settles first.
  def rendered = settle(window).view.text.to_s
  def caption = settle(window).caption_label.caption

  # Gives the pane a real width, so the width-dependent ellipsizing runs.
  def size!(width = 24) = place(window, Tuile::Rect.new(0, 0, width, 8))

  it 'displays and nothing more: Tab never parks focus on the sidebar' do
    assert_kind_of Shared::PassiveTextView, window.view
    refute_predicate window.view, :tab_stop?
    refute_predicate window.view, :focusable?
  end

  def changed(*items) = Pikuri::Tasks::ListChanged.new(items: items)
  def item(id, content, status) = Pikuri::Tasks::Item.new(id: id, content: content, status: status)

  it 'stands up as a borderless "Tasks" caption row over a text view' do
    assert_kind_of Tuile::Component::Layout::Vertical, window
    assert_kind_of Shared::PaneCaptionLabel, window.caption_label
    assert_equal window.caption_label, window.children.first
    assert_equal described_class::CAPTION, caption
    assert_kind_of Tuile::Component::TextView, window.view
  end

  it 'sets no background of its own — it inherits the sidebar tint' do
    assert_nil window.bg_color
  end

  it 'owns a thin Listener bound to itself' do
    assert_kind_of Code::TaskListPane::Listener, listener
  end

  it 'shows a placeholder before any tasks exist' do
    listener.on_event(changed)
    assert_includes rendered, Code::TaskListPane::PLACEHOLDER
  end

  it 'renders one line per task with its content' do
    listener.on_event(changed(item(1, 'Add dark mode', 'pending'), item(2, 'Write tests', 'in_progress')))
    assert_includes rendered, 'Add dark mode'
    assert_includes rendered, 'Write tests'
    assert_equal 2, rendered.lines.size
  end

  it 'marks each listed status with its glyph' do
    listener.on_event(changed(item(1, 'pend', 'pending'), item(2, 'busy', 'in_progress')))
    assert_includes rendered, "#{Code::TaskListPane::GLYPHS['pending']} pend"
    assert_includes rendered, "#{Code::TaskListPane::GLYPHS['in_progress']} busy"
  end

  it 'rewrites the whole pane from the latest snapshot (last-wins, not append)' do
    listener.on_event(changed(item(1, 'first plan', 'pending')))
    listener.on_event(changed(item(1, 'first plan', 'in_progress'), item(2, 'second', 'pending')))
    assert_includes rendered, 'first plan'
    assert_includes rendered, 'second'
    assert_equal 2, rendered.lines.size
  end

  it 'returns to the placeholder when the list empties out' do
    listener.on_event(changed(item(1, 'lonely', 'pending')))
    listener.on_event(changed)
    refute_includes rendered, 'lonely'
    assert_includes rendered, Code::TaskListPane::PLACEHOLDER
  end

  it 'ignores non-ListChanged events' do
    listener.on_event(tool_result('noise'))
    refute_includes rendered, 'noise'
  end

  it 'drives #items= directly (the UI verb the listener calls)' do
    window.items = [item(1, 'direct', 'pending')]
    assert_includes rendered, 'direct'
  end

  describe 'completed tasks move into the caption' do
    it 'lists only the live ones, tallying the rest' do
      window.items = [item(1, 'done one', 'completed'), item(2, 'done two', 'completed'),
                      item(3, 'still going', 'in_progress')]
      refute_includes rendered, 'done one'
      refute_includes rendered, 'done two'
      assert_includes rendered, 'still going'
      assert_equal 1, rendered.lines.size
      assert_equal 'Tasks: 2/3', caption
    end

    it 'says so when every task is done, rather than claiming there are none' do
      window.items = [item(1, 'wrapped up', 'completed')]
      assert_includes rendered, Code::TaskListPane::ALL_DONE
      refute_includes rendered, Code::TaskListPane::PLACEHOLDER
      assert_equal 'Tasks: 1/1', caption
    end

    it 'keeps the caption bare while there is nothing to tally' do
      window.items = []
      assert_equal described_class::CAPTION, caption
    end
  end

  describe 'one row per task, ellipsized to the pane width' do
    it 'truncates a long task instead of letting TextView wrap it' do
      size!
      window.items = [item(1, 'x' * 60, 'pending')]
      assert_equal 1, rendered.lines.size
      assert_equal 24, settle(window).view.text.display_width
      assert rendered.end_with?('…'), "expected an ellipsis, got #{rendered.inspect}"
    end

    it 'leaves a task that fits untouched' do
      size!
      window.items = [item(1, 'short', 'pending')]
      assert_equal '○ short', rendered
    end

    it 're-ellipsizes when the pane is resized' do
      size!(40)
      window.items = [item(1, 'y' * 60, 'pending')]
      assert_equal 40, settle(window).view.text.display_width
      size!(16)
      assert_equal 16, settle(window).view.text.display_width
    end

    it 'truncates nothing while the pane has no width yet' do
      window.items = [item(1, 'z' * 60, 'pending')]
      assert_includes rendered, 'z' * 60
    end
  end

  describe '#tally / #on_tally' do
    it 'starts at 0/0' do
      assert_equal [0, 0], window.tally
    end

    it 'reports done and total, matching the caption' do
      window.items = [item(1, 'a', 'completed'), item(2, 'b', 'pending')]
      assert_equal [1, 2], window.tally
      assert_equal 'Tasks: 1/2', caption
    end

    it 'fires the callback when the tally moves' do
      seen = []
      window.on_tally { |done, total| seen << [done, total] }
      window.items = [item(1, 'a', 'pending')]
      window.items = [item(1, 'a', 'completed')]
      assert_equal [[0, 1], [1, 1]], seen
    end

    it 'stays quiet when a re-render leaves the tally alone' do
      window.items = [item(1, 'a', 'pending')]
      seen = 0
      window.on_tally { seen += 1 }
      size!(30)
      window.items = [item(1, 'renamed but still pending', 'pending')]
      assert_equal 0, seen
    end
  end
end
