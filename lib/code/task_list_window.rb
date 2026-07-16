# frozen_string_literal: true

require 'tuile'

module Code
  # The sidebar's task pane as one cohesive component: a
  # {Tuile::Component::Window} captioned "Tasks" framing a scrollable
  # {Tuile::Component::TextView} and owning the {TaskListener} that renders
  # the agent's task-list stream into it. The host folds {#listener} into
  # the agent's +ListenerList+ and drops the window into the layout — the
  # same widget-owns-its-listener shape as {Shared::ConversationWindow}:
  #
  #   tasks = Code::TaskListWindow.new
  #   config.add_listener(tasks.listener)          # into the ListenerList
  #   layout = Code::Layout.new(tasks: tasks, ...)  # into the sidebar
  #
  # Coding-shell-only — the chat / computer shells carry no sidebar.
  #
  # UI-thread-confined.
  class TaskListWindow < Tuile::Component::Window
    # Claims no observer slot and takes no arguments; builds its own
    # {TextView} content and the {TaskListener} bound to it. Reaches for the
    # installed +Tuile::Screen+ singleton (fake-able via +Tuile::Screen.fake+
    # in tests) to give the listener its +event_queue+ / +theme+.
    def initialize
      super('Tasks')
      @view = Tuile::Component::TextView.new
      self.content = @view
      self.scrollbar = true
      @listener = TaskListener.new(text_view: @view, screen: screen)
    end

    # @return [Tuile::Component::TextView] the task pane; exposed for tests,
    #   production reaches it through {#listener}.
    attr_reader :view

    # @return [TaskListener] the task-list listener; fold it into the
    #   agent's +ListenerList+.
    attr_reader :listener
  end
end
