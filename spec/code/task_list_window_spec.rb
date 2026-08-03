# frozen_string_literal: true

RSpec.describe Code::TaskListWindow do
  let(:window)   { described_class.new }
  let(:listener) { window.listener }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  def rendered = window.view.text.to_s

  def changed(*items) = Pikuri::Tasks::ListChanged.new(items: items)
  def item(id, content, status) = Pikuri::Tasks::Item.new(id: id, content: content, status: status)

  it 'stands up as a titled "Tasks" Tuile Window framing a text view' do
    assert_kind_of Tuile::Component::Window, window
    assert_equal 'Tasks', window.caption.to_s
    assert_kind_of Tuile::Component::TextView, window.view
  end

  it 'owns a thin Listener bound to itself' do
    assert_kind_of Code::TaskListWindow::Listener, listener
  end

  it 'shows a placeholder before any tasks exist' do
    listener.on_event(changed)
    assert_includes rendered, Code::TaskListWindow::PLACEHOLDER
  end

  it 'renders one line per task with its content' do
    listener.on_event(changed(item(1, 'Add dark mode', 'pending'), item(2, 'Write tests', 'in_progress')))
    assert_includes rendered, 'Add dark mode'
    assert_includes rendered, 'Write tests'
    assert_equal 2, rendered.lines.size
  end

  it 'marks each status with its glyph' do
    listener.on_event(changed(
                        item(1, 'pend', 'pending'),
                        item(2, 'busy', 'in_progress'),
                        item(3, 'done', 'completed')
                      ))
    assert_includes rendered, "#{Code::TaskListWindow::GLYPHS['pending']} pend"
    assert_includes rendered, "#{Code::TaskListWindow::GLYPHS['in_progress']} busy"
    assert_includes rendered, "#{Code::TaskListWindow::GLYPHS['completed']} done"
  end

  it 'rewrites the whole pane from the latest snapshot (last-wins, not append)' do
    listener.on_event(changed(item(1, 'first plan', 'pending')))
    listener.on_event(changed(item(1, 'first plan', 'completed'), item(2, 'second', 'pending')))
    assert_includes rendered, 'first plan'
    assert_includes rendered, 'second'
    assert_equal 2, rendered.lines.size
  end

  it 'returns to the placeholder when the list empties out' do
    listener.on_event(changed(item(1, 'lonely', 'pending')))
    listener.on_event(changed)
    refute_includes rendered, 'lonely'
    assert_includes rendered, Code::TaskListWindow::PLACEHOLDER
  end

  it 'ignores non-ListChanged events' do
    listener.on_event(Pikuri::Agent::Event::ToolResult.new(content: 'noise'))
    refute_includes rendered, 'noise'
  end

  it 'drives #items= directly (the UI verb the listener calls)' do
    window.items = [item(1, 'direct', 'pending')]
    assert_includes rendered, 'direct'
  end
end
