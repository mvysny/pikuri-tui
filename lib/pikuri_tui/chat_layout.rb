# frozen_string_literal: true

require 'tuile'

module PikuriTui
  # Vertical-split root layout for {ChatApp}: the conversation Window
  # occupies the top, the input Window occupies a fixed-height strip at
  # the bottom. Doubles as the host of two global keybindings:
  #
  # - +Ctrl+L+ — opens the log popup. Bound to the control sequence
  #   (ASCII +0x0c+, form-feed) rather than plain +l+ so the binding
  #   survives focus being on a text input. Plain +l+ is a printable
  #   character that the focused {Tuile::Component::TextArea} consumes
  #   via {Tuile::Component::TextArea#insert_char}; Tuile's only
  #   "global" mechanism, {Tuile::Component#key_shortcut}, is
  #   intentionally suppressed while the focused component owns the
  #   hardware cursor (see {Tuile::Component#handle_key}), so a
  #   plain-letter binding wouldn't reach the layout either.
  #   +Ctrl+L+ sidesteps both: it isn't printable
  #   (+TextArea#printable?+ requires +0x20 ≤ ord < 0x7f+) so the
  #   focused input doesn't consume it, and ChatLayout intercepts it
  #   *before* +super+ (which would otherwise dispatch to the active
  #   child).
  # - +Ctrl+C+ — flips the agent's +Cancellable+ flag. Unguarded by
  #   cursor position, by design: Ctrl+C is universally "stop what you're
  #   doing," and the user's expectation that it interrupts a running
  #   turn outweighs the niche case of typing a literal control char into
  #   the input. The flag is idempotent — calling +cancel!+ outside a
  #   turn is harmless because {Pikuri::Agent#run_loop} calls +reset!+
  #   at the start of every turn.
  class ChatLayout < Tuile::Component::Layout
    # Number of rows the bottom input pane occupies: 3 lines of editable
    # text + 2 rows of {Tuile::Component::Window} frame.
    #
    # @return [Integer]
    INPUT_HEIGHT = 5

    # Raw key code for Ctrl+C in terminal raw mode (ASCII ETX, 0x03).
    # {Tuile::Keys} doesn't export a constant for it — Tuile only names
    # control keys it routes itself (Tab, Shift+Tab, ESC, Ctrl+H/U/D)
    # — so we define ours here rather than reach into Tuile internals.
    #
    # @return [String]
    CTRL_C = "\x03"

    # Raw key code for Ctrl+L in terminal raw mode (ASCII form-feed,
    # 0x0c). Same rationale as {CTRL_C}: Tuile doesn't surface a
    # constant for it.
    #
    # @return [String]
    CTRL_L = "\x0c"

    # @param conversation [Tuile::Component::Window] the framed conversation
    #   pane (top). Added as a child during construction; its rect is
    #   managed by {#rect=}.
    # @param input [Tuile::Component::Window] the framed input pane
    #   (bottom). Same lifecycle as +conversation+.
    # @param on_log [Proc, Method] zero-arg callable fired on Ctrl+L.
    #   Runs on the event-loop thread.
    # @param on_cancel [Proc, Method] zero-arg callable fired on Ctrl+C.
    #   Runs on the event-loop thread.
    def initialize(conversation:, input:, on_log:, on_cancel:)
      super()
      @conversation = conversation
      @input = input
      @on_log = on_log
      @on_cancel = on_cancel
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

    # @param key [String]
    # @return [Boolean] true if the key was consumed by a global binding
    #   or by an active child; false otherwise (lets the screen fall
    #   through to its +q+/ESC quit handler).
    def handle_key(key)
      if key == CTRL_L
        @on_log.call
        return true
      end
      if key == CTRL_C
        @on_cancel.call
        return true
      end
      super
    end
  end
end
