# frozen_string_literal: true

require 'tuile'

module Chat
  # Vertical-split root layout for {App}, borderless throughout:
  #
  #   ┌────────────────────────────────────────────┐
  #   │   conversation (terminal background)       │
  #   │                                            │
  #   ├── Local Qwen 3.6 · 25k/60k ────────────────┤  <- Shared::StatusRuleLabel
  #   │ ❯ prompt (tinted :pane_bg)                 │  <- Shared::InputPane
  #   └────────────────────────────────────────────┘
  #
  # Nothing here is framed; what separates the two panes is the one-row status
  # rule and the prompt's own tint. The conversation is inset {CONTENT_INSET}
  # columns from the left so its text lines up with the prompt's buffer, with
  # the +❯+ hanging into the margin below it; the rule and the prompt well both
  # span the full width, so the tinted block reads as a band across the bottom
  # of the screen.
  #
  # Layout only — global keybindings (Ctrl+K, Ctrl+C) are installed by
  # {App} via {Tuile::Screen#register_global_shortcut}, which bypasses
  # the cursor-owner suppression that would otherwise let the focused
  # {Tuile::Component::TextArea} swallow them.
  #
  # UI-thread-confined.
  class Layout < Tuile::Component::Layout
    # Rows the bottom input pane occupies.
    #
    # @return [Integer]
    INPUT_HEIGHT = Shared::InputPane::HEIGHT

    # Columns the conversation pane is inset from the left edge, matching
    # {Shared::InputPane::MARKER_WIDTH} so the transcript lines up with the
    # prompt's *text* column, the +❯+ hanging into the margin below it. The
    # status rule and the prompt well are deliberately *not* inset — a
    # full-bleed rule reads as a divider, an inset one as a caption.
    #
    # @return [Integer]
    CONTENT_INSET = Shared::InputPane::MARKER_WIDTH

    # @param conversation [Shared::ConversationTextView] the transcript pane
    #   (top). Added as a child during construction; its rect is managed by
    #   {#relayout}.
    # @param status_rule [Shared::StatusRuleLabel] the one-row rule between the
    #   two panes, carrying the agent status readout. Same lifecycle.
    # @param input [Shared::InputPane] the tinted prompt well (bottom). Same
    #   lifecycle.
    def initialize(conversation:, status_rule:, input:)
      super()
      @conversation = conversation
      @status_rule = status_rule
      @input = input
      add(conversation)
      add(status_rule)
      add(input)
    end

    # @return [Shared::ConversationTextView]
    attr_reader :conversation

    # @return [Shared::StatusRuleLabel]
    attr_reader :status_rule

    # @return [Shared::InputPane]
    attr_reader :input

    private

    # Divides the layout's own rect between the three rows. The prompt takes
    # the bottom {INPUT_HEIGHT} rows and the rule the one above it; the
    # conversation takes everything left, inset by {CONTENT_INSET}. On a
    # terminal too short for all three the prompt shrinks first, then the rule
    # drops out, then the conversation — each floored at +0+, at which point
    # {Tuile::Component} treats the pane as invisible.
    #
    # @return [void]
    def relayout
      input_h = [INPUT_HEIGHT, height].min
      rule_h = height > input_h ? 1 : 0
      top_h = height - input_h - rule_h
      @conversation.rect = Tuile::Rect.new(CONTENT_INSET, 0, [width - CONTENT_INSET, 0].max, top_h)
      @status_rule.rect = Tuile::Rect.new(0, top_h, width, rule_h)
      @input.rect = Tuile::Rect.new(0, top_h + rule_h, width, input_h)
    end
  end
end
