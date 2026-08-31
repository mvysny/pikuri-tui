# frozen_string_literal: true

require 'tuile'

module Computer
  # Vertical-split root layout for {App}, borderless throughout: the
  # conversation pane on top, the {Shared::StatusRuleLabel} beneath it, the
  # tinted {Shared::InputPane} at the bottom. A parallel copy of
  # {Chat::Layout} (see {Computer} for why the computer shell duplicates rather
  # than shares) — the computer shell is laid out like the chat shell, with no
  # sidebar.
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
    # {Shared::InputPane::PAD} so the transcript and the +❯+ marker share a
    # left margin.
    #
    # @return [Integer]
    CONTENT_INSET = Shared::InputPane::PAD

    # @param conversation [Shared::ConversationTextView] the transcript pane
    #   (top). Added as a child during construction; its rect is managed by
    #   {#rect=}.
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

    # Re-positions the three rows whenever the layout's own rect changes. The
    # prompt takes the bottom {INPUT_HEIGHT} rows and the rule the one above
    # it; the conversation takes everything left, inset by {CONTENT_INSET}. On
    # a terminal too short for all three the prompt shrinks first, then the
    # rule drops out, then the conversation.
    #
    # @param new_rect [Tuile::Rect]
    # @return [void]
    def rect=(new_rect)
      super
      return if rect.empty?

      input_h = [INPUT_HEIGHT, rect.height].min
      rule_h = rect.height > input_h ? 1 : 0
      top_h = rect.height - input_h - rule_h
      @conversation.rect = Tuile::Rect.new(rect.left + CONTENT_INSET, rect.top,
                                           [rect.width - CONTENT_INSET, 0].max, top_h)
      @status_rule.rect = Tuile::Rect.new(rect.left, rect.top + top_h, rect.width, rule_h)
      @input.rect = Tuile::Rect.new(rect.left, rect.top + top_h + rule_h, rect.width, input_h)
    end
  end
end
