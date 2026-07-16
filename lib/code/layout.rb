# frozen_string_literal: true

require 'tuile'

module Code
  # Dual-column root layout for {App}. Unlike {Chat::Layout}'s simple
  # top/bottom split, the coding shell devotes the right edge to a
  # {WorkspaceSidebar}:
  #
  #   +-- conversation -----+-- sidebar --+
  #   |                     |  (tasks over |
  #   |                     |   changes)   |
  #   +-- input ------------+             |
  #   |                     |             |
  #   +---------------------+-------------+
  #
  # The screen splits left/right by {SIDEBAR_FRACTION}: the left column
  # is the conversation pane over a fixed-height input strip (the same
  # stacking {Chat::Layout} uses, but only as wide as the left column);
  # the right column is the full-height {WorkspaceSidebar}, which owns its
  # own tasks-over-git split. A parallel copy / extension of {Chat::Layout}
  # (see {Code} for why the coding shell duplicates rather than shares).
  #
  # Layout only — global keybindings (Ctrl+K, Ctrl+C) are installed
  # by {App} via {Tuile::Screen#register_global_shortcut}, which bypasses
  # the cursor-owner suppression that would otherwise let the focused
  # {Tuile::Component::TextArea} swallow them. The confirmation and git-diff
  # popups are modal overlays, not part of this layout.
  #
  # UI-thread-confined.
  class Layout < Tuile::Component::Layout
    # Number of rows the bottom input pane occupies: 3 lines of editable
    # text + 2 rows of {Tuile::Component::Window} frame.
    #
    # @return [Integer]
    INPUT_HEIGHT = 5

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
    # @param sidebar [WorkspaceSidebar] the full-height sidebar column
    #   (right), which owns its own tasks-over-git split. Same lifecycle.
    def initialize(conversation:, input:, sidebar:)
      super()
      @conversation = conversation
      @input = input
      @sidebar = sidebar
      add(conversation)
      add(input)
      add(sidebar)
    end

    # @return [Tuile::Component::Window]
    attr_reader :conversation

    # @return [Tuile::Component::Window]
    attr_reader :input

    # @return [WorkspaceSidebar]
    attr_reader :sidebar

    # Re-positions the three panes whenever the layout's own rect changes.
    # The width splits into a conversation column and a sidebar column
    # ({#sidebar_width}); the conversation column stacks the conversation pane
    # over a fixed {INPUT_HEIGHT} input strip; the sidebar takes the full
    # height of its column and splits itself. When the terminal is too narrow
    # for a readable sidebar, {#sidebar_width} returns +0+ and the sidebar
    # takes an empty rect ({Tuile::Component} treats a zero-area rect as
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

      @sidebar.rect = Tuile::Rect.new(rect.left + left_w, rect.top, right_w, rect.height)
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
