# frozen_string_literal: true

require 'tuile'

module Code
  # Dual-pane root layout for {App}. Unlike {Chat::Layout}'s simple
  # top/bottom split, the coding shell devotes the right edge to a
  # workspace sidebar:
  #
  #   +-- conversation -----+-- tasks ----+
  #   |                     +-------------+
  #   |                     |  changes    |
  #   +-- input ------------+             |
  #   |                     |             |
  #   +---------------------+-------------+
  #
  # The screen splits left/right by {SIDEBAR_FRACTION}: the left column
  # is the conversation pane over a fixed-height input strip (the same
  # stacking {Chat::Layout} uses, but only as wide as the left column);
  # the right column is the full-height sidebar, a fixed {TASK_HEIGHT}
  # task window over the git change-summary window (the full diff is a
  # leader-menu popup, not part of this layout). A parallel copy / extension
  # of {Chat::Layout} (see {Code} for why the coding shell duplicates rather
  # than shares).
  #
  # Layout only — global keybindings (Ctrl+K, Ctrl+C) are installed
  # by {App} via {Tuile::Screen#register_global_shortcut}, which bypasses
  # the cursor-owner suppression that would otherwise let the focused
  # {Tuile::Component::TextArea} swallow them. The confirmation and git-diff
  # popups are modal overlays, not part of this layout.
  class Layout < Tuile::Component::Layout
    # Number of rows the bottom input pane occupies: 3 lines of editable
    # text + 2 rows of {Tuile::Component::Window} frame.
    #
    # @return [Integer]
    INPUT_HEIGHT = 5

    # Number of rows the task window (top of the sidebar) occupies: ~4
    # task lines + 2 rows of {Tuile::Component::Window} frame. The
    # git change-summary window below it takes whatever sidebar rows remain.
    #
    # @return [Integer]
    TASK_HEIGHT = 6

    # Fraction of the terminal width allotted to the sidebar column
    # (tasks + git). The conversation column gets the rest — a 60/40
    # split in the conversation's favor.
    #
    # @return [Float]
    SIDEBAR_FRACTION = 0.4

    # Below this sidebar width the column is too narrow to read, so the
    # layout collapses it (width 0, both sidebar windows invisible) and
    # gives the whole width to the conversation column.
    #
    # @return [Integer]
    MIN_SIDEBAR_WIDTH = 24

    # The conversation column never shrinks below this; if honoring
    # {SIDEBAR_FRACTION} would starve it, the sidebar collapses instead.
    #
    # @return [Integer]
    MIN_CONVERSATION_WIDTH = 24

    # @param conversation [Tuile::Component::Window] the framed
    #   conversation pane (top-left). Added as a child during
    #   construction; its rect is managed by {#rect=}.
    # @param input [Tuile::Component::Window] the framed input pane
    #   (bottom-left). Same lifecycle as +conversation+.
    # @param tasks [Tuile::Component::Window] the framed task-list pane
    #   (top of the sidebar). Same lifecycle.
    # @param git [Tuile::Component::Window] the framed git change-summary
    #   pane (rest of the sidebar), kept current by {GitWatcher}. Same
    #   lifecycle.
    def initialize(conversation:, input:, tasks:, git:)
      super()
      @conversation = conversation
      @input = input
      @tasks = tasks
      @git = git
      add(conversation)
      add(input)
      add(tasks)
      add(git)
    end

    # @return [Tuile::Component::Window]
    attr_reader :conversation

    # @return [Tuile::Component::Window]
    attr_reader :input

    # @return [Tuile::Component::Window]
    attr_reader :tasks

    # @return [Tuile::Component::Window]
    attr_reader :git

    # Re-positions all four panes whenever the layout's own rect
    # changes. The width splits into a conversation column and a sidebar
    # column ({#sidebar_width}); the conversation column stacks the
    # conversation pane over a fixed {INPUT_HEIGHT} input strip; the
    # sidebar column stacks a fixed {TASK_HEIGHT} task pane over the
    # git change-summary pane. When the terminal is too narrow for a readable
    # sidebar, {#sidebar_width} returns +0+ and the sidebar windows take
    # empty rects ({Tuile::Component} treats a zero-area rect as
    # invisible), leaving the conversation column full width.
    #
    # @param new_rect [Tuile::Rect]
    # @return [void]
    def rect=(new_rect)
      super
      return if rect.empty?

      right_w = sidebar_width(rect.width)
      left_w  = rect.width - right_w

      top_h    = [rect.height - INPUT_HEIGHT, 0].max
      bottom_h = rect.height - top_h
      @conversation.rect = Tuile::Rect.new(rect.left, rect.top, left_w, top_h)
      @input.rect = Tuile::Rect.new(rect.left, rect.top + top_h, left_w, bottom_h)

      sidebar_left = rect.left + left_w
      tasks_h = [TASK_HEIGHT, rect.height].min
      git_h   = rect.height - tasks_h
      @tasks.rect = Tuile::Rect.new(sidebar_left, rect.top, right_w, tasks_h)
      @git.rect = Tuile::Rect.new(sidebar_left, rect.top + tasks_h, right_w, git_h)
    end

    private

    # The sidebar column width for a given total width: {SIDEBAR_FRACTION}
    # of it, collapsed to +0+ when either the sidebar would fall below
    # {MIN_SIDEBAR_WIDTH} or honoring it would starve the conversation
    # below {MIN_CONVERSATION_WIDTH}.
    #
    # @param total_width [Integer]
    # @return [Integer]
    def sidebar_width(total_width)
      candidate = (total_width * SIDEBAR_FRACTION).round
      return 0 if candidate < MIN_SIDEBAR_WIDTH
      return 0 if total_width - candidate < MIN_CONVERSATION_WIDTH

      candidate
    end
  end
end
