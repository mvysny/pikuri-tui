# frozen_string_literal: true

RSpec.describe Code::TaskListWindow do
  let(:window) { described_class.new }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  def changed(*items) = Pikuri::Tasks::ListChanged.new(items: items)
  def item(id, content, status) = Pikuri::Tasks::Item.new(id: id, content: content, status: status)

  it 'stands up as a titled "Tasks" Tuile Window framing a TextView' do
    assert_kind_of Tuile::Component::Window, window
    assert_equal 'Tasks', window.caption
    assert_kind_of Tuile::Component::TextView, window.view
  end

  it 'owns the TaskListener it exposes for the agent ListenerList' do
    assert_kind_of Code::TaskListener, window.listener
  end

  it 'renders task-list changes driven through its listener into its own pane' do
    window.listener.on_event(changed(item(1, 'Add dark mode', 'pending')))
    assert_includes window.view.text.to_s, 'Add dark mode'
  end
end
