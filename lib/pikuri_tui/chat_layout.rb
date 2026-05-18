# frozen_string_literal: true

require 'tuile'

module PikuriTui
  # Vertical-split root layout for {ChatApp}: the conversation Window
  # occupies the top, the input Window occupies a fixed-height strip at
  # the bottom.
  #
  # Layout only — global keybindings (Ctrl+L, Ctrl+C) are installed by
  # {ChatApp} via {Tuile::Screen#register_global_shortcut}, which
  # bypasses the cursor-owner suppression that would otherwise let the
  # focused {Tuile::Component::TextArea} swallow them.
  class ChatLayout < Tuile::Component::Layout
    # Number of rows the bottom input pane occupies: 3 lines of editable
    # text + 2 rows of {Tuile::Component::Window} frame.
    #
    # @return [Integer]
    INPUT_HEIGHT = 5

    # @param conversation [Tuile::Component::Window] the framed conversation
    #   pane (top). Added as a child during construction; its rect is
    #   managed by {#rect=}.
    # @param input [Tuile::Component::Window] the framed input pane
    #   (bottom). Same lifecycle as +conversation+.
    def initialize(conversation:, input:)
      super()
      @conversation = conversation
      @input = input
      add(conversation)
      add(input)
    end

    # @return [Tuile::Component::Window]
    attr_reader :conversation

    # @return [Tuile::Component::Window]
    attr_reader :input

    # Re-positions the conversation and input panes whenever the layout's
    # own rect changes. Top pane takes all rows except the bottom
    # {INPUT_HEIGHT}; bottom pane takes the last {INPUT_HEIGHT} rows. If
    # the terminal is too small to give both panes a positive height,
    # the input shrinks first (its lower bound is +0+, at which point
    # {Tuile::Component} treats it as invisible).
    #
    # @param new_rect [Tuile::Rect]
    # @return [void]
    def rect=(new_rect)
      super
      return if rect.empty?

      top_h = [rect.height - INPUT_HEIGHT, 0].max
      bottom_h = rect.height - top_h
      @conversation.rect = Tuile::Rect.new(rect.left, rect.top, rect.width, top_h)
      @input.rect = Tuile::Rect.new(rect.left, rect.top + top_h, rect.width, bottom_h)
    end
  end
end
