# frozen_string_literal: true

require 'tuile'

module Code
  # The coding shell's workspace sidebar as one Tuile container: a fixed
  # {TASK_HEIGHT} task pane stacked over the git change-summary pane, plus the
  # off-layout diff dialog. Composes {TaskListPane}, {GitSummaryPane},
  # {GitDiffDialog}, and the {GitWatcher} service that feeds the last two:
  #
  #   Tasks ───────    <- fixed TASK_HEIGHT rows, caption included
  #   ○ port the tint
  #   Changes ─────    <- the remaining rows; the full diff is a
  #   M lib/x.rb +2       leader-menu dialog (#open_diff), not part of this box
  #
  # This is a *secondary* surface, so the whole column paints +:pane_bg+ — set
  # once here, inherited by both panes — which is what tells it apart from the
  # untinted conversation beside it now that neither is framed. The +│+ column
  # on its left edge and the status rule below it belong to {Layout}, not here.
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
    # Rows the task pane (top of the sidebar) occupies: its caption row plus
    # ~5 task lines. The git change-summary pane below it takes whatever
    # sidebar rows remain.
    #
    # @return [Integer]
    TASK_HEIGHT = 6

    # Builds the panes, the {GitDiffDialog} and the {GitWatcher}, then subscribes
    # the git views to it. Adds the task and change-summary panes as layout
    # children; the diff dialog is *not* a child — it opens only on {#open_diff}.
    def initialize
      super()
      @task_pane = TaskListPane.new
      @git_summary_pane = GitSummaryPane.new

      # The full colored diff is too wide for the sidebar, so it lives in a
      # fullscreen dialog opened from the leader menu's 'd' entry. Built
      # eagerly (like the diagnostic log dialog) so the watcher can feed the
      # latest diff into it every poll whether or not the dialog is shown.
      @git_diff_dialog = GitDiffDialog.new

      # GitWatcher is a UI-independent service: it emits Snapshots on its poll
      # thread and knows nothing of these panes. We subscribe, marshal onto the
      # event loop, and hand each pane the snapshot (it renders the half it
      # cares about) — the one place the service's data becomes UI.
      @git_snapshot = nil
      @on_digest = nil
      @task_pane.on_tally { emit_digest }

      @git_watcher = GitWatcher.new
      @git_watcher.on_change do |snapshot|
        screen.event_queue.submit do
          @git_snapshot = snapshot
          @git_summary_pane.snapshot = snapshot
          @git_diff_dialog.snapshot = snapshot
          emit_digest
        end
      end

      add(@task_pane)
      add(@git_summary_pane)
      # Tint the whole column; a Theme::Ref re-resolves on every theme swap by
      # itself, and both panes inherit it via ComponentBackground#effective.
      self.bg_color = Tuile::Theme.ref(:pane_bg)
    end

    # @return [GitWatcher] the background git service the panes subscribe to;
    #   exposed for tests.
    attr_reader :git_watcher

    # @return [GitSummaryPane] the change-summary pane; exposed for tests,
    #   production drives it through the {GitWatcher} subscription.
    attr_reader :git_summary_pane

    # @return [GitDiffDialog] the full-diff dialog; exposed for tests.
    attr_reader :git_diff_dialog

    # @return [TaskListPane::Listener] the task-stream listener (owned by
    #   the task pane's view); fold it into the agent's +ListenerList+.
    def task_listener = @task_pane.listener

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

    # Opens the {GitDiffDialog} with the latest full diff (kept current by the
    # {GitWatcher} subscription). A no-op if it is already open. The leader
    # menu's +d+ action.
    #
    # @return [void]
    def open_diff
      return if @git_diff_dialog.open?

      @git_diff_dialog.open
    end

    # @return [Boolean] whether the {GitDiffDialog} is currently open.
    def diff_open? = @git_diff_dialog.open?

    # @return [Shared::StatusRuleLabel::WorkspaceDigest] what the two panes are
    #   showing, reduced to counts — for a host to stand up elsewhere while this
    #   column is off screen.
    def digest
      changes = @git_snapshot&.changes || []
      done, total = @task_pane.tally
      Shared::StatusRuleLabel::WorkspaceDigest.new(
        files: changes.size, added: changes.sum(&:added), deleted: changes.sum(&:deleted),
        tasks_done: done, tasks_total: total
      )
    end

    # Registers a callback fired with a fresh {#digest} whenever either pane's
    # data moves — the git poll landing or the task list changing.
    #
    #   sidebar.on_digest { |digest| status_rule.workspace_digest = digest }
    #
    # Called on the UI thread (the git leg is already marshalled). One
    # callback; a second registration replaces the first.
    #
    # @yieldparam digest [Shared::StatusRuleLabel::WorkspaceDigest]
    # @return [void]
    def on_digest(&block)
      @on_digest = block
    end

    private

    # Stacks a fixed {TASK_HEIGHT} task pane over the git change-summary pane
    # across the sidebar rect; an empty one makes both panes' rects empty, so
    # they paint nothing. The {GitWatcher} keeps polling either way, so
    # {#open_diff} still opens on a current diff.
    #
    # Assigns both panes on every pass, empty rect included — Tuile's own rule
    # for a container whose rect has gone empty, and here the bite is concrete:
    # children left pointing at the columns they used to hold survive every
    # normal repaint and then paint at those stale coordinates the moment a
    # popup close fires {Tuile::Screen#needs_full_repaint}, silent under test.
    #
    # @return [void]
    def relayout
      tasks_h = [TASK_HEIGHT, height].min
      git_h   = height - tasks_h
      @task_pane.rect = Tuile::Rect.new(0, 0, width, tasks_h)
      @git_summary_pane.rect = Tuile::Rect.new(0, tasks_h, width, git_h)
    end

    # @return [void]
    def emit_digest = @on_digest&.call(digest)
  end
end
