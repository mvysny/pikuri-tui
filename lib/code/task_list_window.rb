# frozen_string_literal: true

require 'tuile'

module Code
  # The sidebar's task pane as one cohesive component: a
  # {Tuile::Component::Window} captioned "Tasks" framing a scrollable
  # {TaskListTextView} (which owns the rendering *and* the task-stream
  # {TaskListTextView::Listener}). {WorkspaceSidebar} composes it as its
  # top pane and folds {#listener} into the agent's +ListenerList+ — the same
  # frame-over-view shape as {Shared::ConversationWindow} ↔
  # {Shared::ConversationTextView}:
  #
  #   tasks = Code::TaskListWindow.new
  #   config.add_listener(tasks.listener)   # into the ListenerList
  #
  # Coding-shell-only — the chat / computer shells carry no sidebar.
  #
  # UI-thread-confined.
  class TaskListWindow < Tuile::Component::Window
    # Frames a fresh {TaskListTextView} (which builds its own listener); the
    # window itself adds only the caption and scrollbar chrome.
    def initialize
      super('Tasks')
      @view = TaskListTextView.new
      self.content = @view
      self.scrollbar = true
    end

    # @return [TaskListTextView] the task pane; exposed for tests,
    #   production reaches it through {#listener}.
    attr_reader :view

    # @return [TaskListTextView::Listener] the task-stream listener (owned
    #   by the view); fold it into the agent's +ListenerList+.
    def listener = @view.listener
  end
end
