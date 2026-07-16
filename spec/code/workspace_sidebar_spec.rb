# frozen_string_literal: true

RSpec.describe Code::WorkspaceSidebar do
  let(:sidebar) { described_class.new }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  it 'exposes the task-pane listener for the agent ListenerList' do
    assert_kind_of Code::TaskListTextView::Listener, sidebar.task_listener
  end

  describe 'layout' do
    it 'stacks a fixed-height task pane over the git changes pane' do
      sidebar.rect = Tuile::Rect.new(0, 0, 30, 20)
      tasks = sidebar.instance_variable_get(:@task_list_window)
      changes = sidebar.git_summary_window

      assert_equal Tuile::Rect.new(0, 0, 30, described_class::TASK_HEIGHT), tasks.rect
      assert_equal described_class::TASK_HEIGHT, changes.rect.top
      assert_equal 20 - described_class::TASK_HEIGHT, changes.rect.height
      assert_equal 30, changes.rect.width
    end

    it 'leaves both panes empty when handed an empty rect (collapsed sidebar)' do
      sidebar.rect = Tuile::Rect.new(0, 0, 0, 0)
      assert sidebar.instance_variable_get(:@task_list_window).rect.empty?
      assert sidebar.git_summary_window.rect.empty?
    end
  end

  describe 'git diff popup' do
    it 'opens the diff popup and reports it open' do
      refute sidebar.diff_open?
      sidebar.open_diff
      assert sidebar.diff_open?
    end

    it 'open_diff is a no-op when already open' do
      sidebar.open_diff
      sidebar.open_diff # must not raise or re-open
      assert sidebar.diff_open?
    end
  end

  describe 'git watcher subscription' do
    # Drive the service's emit directly (on this thread); the sidebar's
    # on_change listener marshals through the FakeEventQueue (synchronous) and
    # projects the snapshot onto both git panes — so this exercises the full
    # wire without starting the poll thread.
    def emit(snapshot) = sidebar.git_watcher.send(:emit, snapshot)

    def summary_text = sidebar.git_summary_window.view.text.to_s
    def diff_text = sidebar.git_diff_window.view.text.to_s

    it 'projects an emitted snapshot onto the two git panes' do
      emit(Code::GitWatcher::Snapshot.new(
             changes: [Code::GitWatcher::Change.new(code: 'M', path: 'wired.rb', added: 1, deleted: 0)],
             diff_text: "diff --git a/wired.rb b/wired.rb\n@@ -1 +1 @@\n-x\n+y\n",
             error: nil
           ))
      assert_includes summary_text, 'wired.rb'
      assert_includes diff_text, 'wired.rb'
    end

    it 'projects an error snapshot as a notice in both panes' do
      emit(Code::GitWatcher::Snapshot.new(changes: [], diff_text: '', error: 'git unavailable: boom'))
      assert_includes summary_text, 'git unavailable'
      assert_includes diff_text, 'git unavailable'
    end
  end
end
