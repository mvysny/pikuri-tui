# frozen_string_literal: true

require 'tuile'

module Code
  # The coding shell's workspace sidebar as one Tuile container: a fixed
  # {TASK_HEIGHT} task pane stacked over the git change-summary pane, plus the
  # off-layout diff popup they share. Composes {TaskListWindow},
  # {GitSummaryWindow} / {GitDiffWindow}, {GitDiffPopup}, and the
  # {GitWatcher} service that feeds the two git panes:
  #
  #   +-- tasks ----+   <- fixed TASK_HEIGHT rows
  #   +-------------+
  #   |  changes    |   <- the remaining rows; the full-width diff is a
  #   |             |      leader-menu popup (#open_diff), not part of this box
  #   +-------------+
  #
  # The host builds it, folds {#task_listener} into the agent's
  # +ListenerList+, hands it to {Layout} as the single +sidebar:+ child, and
  # drives its lifecycle: {#start_git_watching} before the event loop and
  # {#stop_git_watching} after (see {App#run}); the leader menu's +d+ entry
  # calls {#open_diff}. Everything git flows from the {GitWatcher} this box
  # owns — the host never touches it.
  #
  # Coding-shell-only — the chat / computer shells carry no sidebar.
  #
  # UI-thread-confined. The one off-thread entry is the {GitWatcher}
  # +on_change+ callback (it runs on the poll thread); it marshals onto the UI
  # thread via +screen.event_queue.submit+ before touching the panes, so the
  # service itself stays UI-independent.
  class WorkspaceSidebar < Tuile::Component::Layout
    # Rows the task pane (top of the sidebar) occupies: ~4 task lines + 2 rows
    # of {Tuile::Component::Window} frame. The git change-summary pane below it
    # takes whatever sidebar rows remain.
    #
    # @return [Integer]
    TASK_HEIGHT = 6

    # Builds the two git panes ({GitSummaryWindow} / {GitDiffWindow}), the shared
    # {GitDiffPopup}, and the {GitWatcher}, then subscribes the panes to it. Adds
    # the task and change-summary windows as layout children; the diff window is
    # *not* a child — it lives in the popup, shown only on {#open_diff}.
    def initialize
      super()
      @task_list_window = TaskListWindow.new
      @git_summary_window = GitSummaryWindow.new

      # The full colored diff is too wide for the sidebar, so it lives in a
      # near-fullscreen popup opened from the leader menu's 'd' entry. Built
      # eagerly (like the diagnostic LogWindow) so the watcher can feed the
      # latest diff into it every poll whether or not the popup is shown.
      @git_diff_window = GitDiffWindow.new
      @git_diff_popup = GitDiffPopup.new(diff_window: @git_diff_window)

      # GitWatcher is a UI-independent service: it emits Snapshots on its poll
      # thread and knows nothing of these panes. We subscribe, marshal onto the
      # event loop, and hand each pane the snapshot (it renders the half it
      # cares about) — the one place the service's data becomes UI.
      @git_watcher = GitWatcher.new
      @git_watcher.on_change do |snapshot|
        screen.event_queue.submit do
          @git_summary_window.snapshot = snapshot
          @git_diff_window.snapshot = snapshot
        end
      end

      add(@task_list_window)
      add(@git_summary_window)
    end

    # @return [GitWatcher] the background git service the panes subscribe to;
    #   exposed for tests.
    attr_reader :git_watcher

    # @return [GitSummaryWindow] the change-summary pane; exposed for tests,
    #   production drives it through the {GitWatcher} subscription.
    attr_reader :git_summary_window

    # @return [GitDiffWindow] the diff pane wrapped by {GitDiffPopup}; exposed
    #   for tests.
    attr_reader :git_diff_window

    # @return [TaskListTextView::Listener] the task-stream listener (owned by
    #   the task pane's view); fold it into the agent's +ListenerList+.
    def task_listener = @task_list_window.listener

    # Starts the {GitWatcher}'s background poll; call before the event loop
    # ({App#run}) and pair with {#stop_git_watching}.
    #
    # @return [void]
    def start_git_watching = @git_watcher.start

    # Stops the {GitWatcher}'s background poll; call after the event loop
    # unwinds ({App#run}'s +ensure+).
    #
    # @return [void]
    def stop_git_watching = @git_watcher.stop

    # Opens the {GitDiffPopup} with the latest full diff (kept current by the
    # {GitWatcher} subscription). A no-op if it is already open. The leader
    # menu's +d+ action.
    #
    # @return [void]
    def open_diff
      return if @git_diff_popup.open?

      @git_diff_popup.open
    end

    # @return [Boolean] whether the {GitDiffPopup} is currently open.
    def diff_open? = @git_diff_popup.open?

    # Stacks a fixed {TASK_HEIGHT} task pane over the git change-summary pane
    # across the sidebar rect. On an empty rect — {Layout} hands one down when
    # it collapses the sidebar column on a too-narrow terminal — both panes
    # take empty rects and so paint nothing.
    #
    # @param new_rect [Tuile::Rect]
    # @return [void]
    def rect=(new_rect)
      super
      return if rect.empty?

      tasks_h = [TASK_HEIGHT, rect.height].min
      git_h   = rect.height - tasks_h
      @task_list_window.rect = Tuile::Rect.new(rect.left, rect.top, rect.width, tasks_h)
      @git_summary_window.rect = Tuile::Rect.new(rect.left, rect.top + tasks_h, rect.width, git_h)
    end
  end
end
