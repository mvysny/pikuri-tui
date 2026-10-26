# frozen_string_literal: true

RSpec.describe Code::WorkspaceSidebar do
  let(:sidebar) { described_class.new }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  it 'exposes the task-pane listener for the agent ListenerList' do
    assert_kind_of Code::TaskListPane::Listener, sidebar.task_listener
  end

  describe 'layout' do
    it 'stacks a fixed-height task pane over the git changes pane' do
      Tuile::Testing.place(sidebar, Tuile::Rect.new(0, 0, 30, 20))
      tasks = sidebar.instance_variable_get(:@task_pane)
      changes = sidebar.git_summary_pane

      assert_equal Tuile::Rect.new(0, 0, 30, described_class::TASK_HEIGHT), tasks.rect
      assert_equal described_class::TASK_HEIGHT, changes.rect.top
      assert_equal 20 - described_class::TASK_HEIGHT, changes.rect.height
      assert_equal 30, changes.rect.width
    end

    it 'leaves both panes empty when handed an empty rect (collapsed sidebar)' do
      Tuile::Testing.place(sidebar, Tuile::Rect.new(0, 0, 0, 0))
      assert sidebar.instance_variable_get(:@task_pane).rect.empty?
      assert sidebar.git_summary_pane.rect.empty?
    end

    # The example above starts from panes that are *already* empty, so it stays
    # green even if #relayout short-circuits and leaves them pointing at the
    # columns they used to hold. This one lays the column out first.
    it 'empties both panes when the column is emptied after having been laid out' do
      tasks = sidebar.instance_variable_get(:@task_pane)
      Tuile::Testing.place(sidebar, Tuile::Rect.new(96, 0, 24, 20))
      refute_predicate tasks.rect, :empty?
      refute_predicate sidebar.git_summary_pane.rect, :empty?

      Tuile::Testing.place(sidebar, Tuile::Rect.new(120, 0, 0, 20))
      assert_predicate tasks.rect, :empty?
      assert_predicate sidebar.git_summary_pane.rect, :empty?
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
    # on_change listener submits through the FakeEventQueue, the loop turn
    # projects the snapshot onto both git panes — so this exercises the full
    # wire without starting the poll thread.
    def emit(snapshot)
      sidebar.git_watcher.send(:emit, snapshot)
      Tuile::Testing.loop
    end

    def summary_text
      list = sidebar.git_summary_pane.view
      list.items.map { |entry| list.renderer.call(entry, 0).to_s }.join("\n")
    end
    def diff_text
      sidebar.git_diff_window.flush_layout # a snapshot renders at the next relayout
      sidebar.git_diff_window.view.text.to_s
    end

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

  describe '#digest / #on_digest' do
    def task_pane = sidebar.instance_variable_get(:@task_pane)

    def emit(*changes)
      sidebar.git_watcher.send(:emit, Code::GitWatcher::Snapshot.new(
                                       changes: changes, diff_text: '', error: nil
                                     ))
      Tuile::Testing.loop
    end

    def change(path, added, deleted)
      Code::GitWatcher::Change.new(code: ' M', path: path, added: added, deleted: deleted)
    end

    it 'reduces both panes to counts' do
      emit(change('a.rb', 2, 1), change('b.rb', 40, 6))
      task_pane.items = [Pikuri::Tasks::Item.new(id: 1, content: 'x', status: 'completed')]
      assert_equal Shared::StatusRuleLabel::WorkspaceDigest.new(
        files: 2, added: 42, deleted: 7, tasks_done: 1, tasks_total: 1
      ), sidebar.digest
    end

    it 'reads as an empty digest before any git poll has landed' do
      assert_equal 0, sidebar.digest.files
      assert_equal [0, 0], [sidebar.digest.added, sidebar.digest.deleted]
    end

    it 'fires on a git poll' do
      seen = []
      sidebar.on_digest { |digest| seen << digest.files }
      emit(change('a.rb', 1, 0))
      assert_equal [1], seen
    end

    it 'fires on a task change too, so the tasks half is never a poll behind' do
      seen = []
      sidebar.on_digest { |digest| seen << [digest.tasks_done, digest.tasks_total] }
      task_pane.items = [Pikuri::Tasks::Item.new(id: 1, content: 'x', status: 'pending')]
      assert_equal [[0, 1]], seen
    end
  end
end
