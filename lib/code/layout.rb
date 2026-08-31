# frozen_string_literal: true

require 'tuile'

module Code
  # Dual-column root layout for {App}, borderless throughout. Unlike
  # {Chat::Layout}'s simple stack, the coding shell devotes the right of its
  # *upper* region to a {WorkspaceSidebar}:
  #
  #   ┌──────────────────────────┬─┬─────────────────┐
  #   │  conversation            │││ Tasks ──────    │  <- sidebar is tinted,
  #   │  (terminal background)   │││ ○ port the tint │     the conversation is not
  #   │                          │││ Changes ────    │
  #   ├── Local Qwen · 25k/60k ──┴─┴─────────────────┤  <- Shared::StatusRuleLabel
  #   │ ❯ prompt (tinted, full width)                │  <- Shared::InputPane
  #   └──────────────────────────────────────────────┘
  #
  # Two deliberate departures from the framed layout this replaced. The
  # **prompt spans the full width**: it is the shell's one focus target and had
  # no business being squeezed into the conversation column, and running it
  # edge to edge is what lets a single status rule serve the whole app instead
  # of one per column. And the **sidebar is separated by a one-cell +│+
  # column** ({#separator}) rather than by two abutting frames — the rule
  # underneath it terminates it from below, so its tint needs no border of its
  # own.
  #
  # The upper region splits left/right by {SIDEBAR_FRACTION}. A parallel copy /
  # extension of {Chat::Layout} (see {Code} for why the coding shell duplicates
  # rather than shares).
  #
  # Layout only — global keybindings (Ctrl+K, Ctrl+C) are installed
  # by {App} via {Tuile::Screen#register_global_shortcut}, which bypasses
  # the cursor-owner suppression that would otherwise let the focused
  # {Tuile::Component::TextArea} swallow them. The confirmation and git-diff
  # popups are modal overlays, not part of this layout.
  #
  # UI-thread-confined.
  class Layout < Tuile::Component::Layout
    # Rows the bottom input pane occupies.
    #
    # @return [Integer]
    INPUT_HEIGHT = Shared::InputPane::HEIGHT

    # Columns the conversation pane is inset from the left edge, matching
    # {Shared::InputPane::MARKER_WIDTH} so the transcript lines up with the
    # prompt's *text* column, the +❯+ hanging into the margin below it.
    #
    # @return [Integer]
    CONTENT_INSET = Shared::InputPane::MARKER_WIDTH

    # Fraction of the terminal width allotted to the sidebar column
    # (tasks + git). The conversation column gets the rest — a 60/40
    # split in the conversation's favor.
    #
    # @return [Float]
    SIDEBAR_FRACTION = 0.4

    # Below this sidebar width the column is too narrow to read, so the
    # layout collapses it (width 0, sidebar and separator both invisible) and
    # gives the whole width to the conversation column.
    #
    # @return [Integer]
    MIN_SIDEBAR_WIDTH = 24

    # The conversation column never shrinks below this; if honoring
    # {SIDEBAR_FRACTION} would starve it, the sidebar collapses instead.
    #
    # @return [Integer]
    MIN_CONVERSATION_WIDTH = 24

    # @param conversation [Shared::ConversationTextView] the transcript pane
    #   (top-left). Added as a child during construction; its rect is managed
    #   by {#rect=}.
    # @param status_rule [Shared::StatusRuleLabel] the full-width rule under
    #   both columns, carrying the agent status readout. Same lifecycle.
    # @param input [Shared::InputPane] the full-width tinted prompt well
    #   (bottom). Same lifecycle.
    # @param sidebar [WorkspaceSidebar] the tasks-over-changes column
    #   (top-right), which owns its own split. Same lifecycle.
    def initialize(conversation:, status_rule:, input:, sidebar:)
      super()
      @conversation = conversation
      @status_rule = status_rule
      @input = input
      @sidebar = sidebar
      # The one-cell │ column between the conversation and the sidebar. Its
      # text is rebuilt to the row height by #rect=, its tone by
      # #on_theme_changed — both are baked into the label's text.
      @separator = Tuile::Component::Label.new
      @separator.bg_color = Tuile::Theme.ref(:pane_bg)
      add(conversation)
      add(@separator)
      add(sidebar)
      add(status_rule)
      add(input)
    end

    # @return [Shared::ConversationTextView]
    attr_reader :conversation

    # @return [Shared::StatusRuleLabel]
    attr_reader :status_rule

    # @return [Shared::InputPane]
    attr_reader :input

    # @return [WorkspaceSidebar]
    attr_reader :sidebar

    # @return [Tuile::Component::Label] the +│+ column between the conversation
    #   and the sidebar; exposed for tests.
    attr_reader :separator

    # Re-positions the five pieces whenever the layout's own rect changes. The
    # bottom {INPUT_HEIGHT} rows go to the prompt and the row above them to the
    # status rule, both full width; what is left splits into a conversation
    # column and a sidebar column ({#sidebar_width}) with the {#separator}
    # between them. When the terminal is too narrow for a readable sidebar,
    # {#sidebar_width} returns +0+ and both the sidebar and the separator take
    # empty rects ({Tuile::Component} treats a zero-area rect as invisible),
    # leaving the conversation full width.
    #
    # @param new_rect [Tuile::Rect]
    # @return [void]
    def rect=(new_rect)
      super
      return if rect.empty?

      input_h = [INPUT_HEIGHT, rect.height].min
      rule_h = rect.height > input_h ? 1 : 0
      top_h = rect.height - input_h - rule_h

      right_w = sidebar_width(rect.width)
      gap_w = right_w.positive? ? 1 : 0
      left_w = rect.width - right_w - gap_w

      @conversation.rect = Tuile::Rect.new(rect.left + CONTENT_INSET, rect.top,
                                           [left_w - CONTENT_INSET, 0].max, top_h)
      @separator.rect = Tuile::Rect.new(rect.left + left_w, rect.top, gap_w, top_h)
      @sidebar.rect = Tuile::Rect.new(rect.left + left_w + gap_w, rect.top, right_w, top_h)
      @status_rule.rect = Tuile::Rect.new(rect.left, rect.top + top_h, rect.width, rule_h)
      @input.rect = Tuile::Rect.new(rect.left, rect.top + top_h + rule_h, rect.width, input_h)
      rebuild_separator
    end

    protected

    # Re-tones the separator column, whose color is baked into its text.
    #
    # @return [void]
    def on_theme_changed
      super
      rebuild_separator
    end

    private

    # Rebuilds the separator column: one +:pane_frame+ +│+ per row of the upper
    # region. A collapsed sidebar leaves it empty.
    #
    # @return [void]
    def rebuild_separator
      column = Array.new(@separator.rect.height, '│').join("\n")
      @separator.text = Tuile::StyledString.styled(column, fg: screen.theme[:pane_frame])
    end

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
