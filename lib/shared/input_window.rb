# frozen_string_literal: true

require 'tuile'

# The bottom input pane, framed: a {Tuile::Component::Window} captioned
# "Prompt" wrapping an editable {Area} (Enter submits, blank buffers are a
# no-op). Frames the input the way {Shared::ConversationWindow} frames the
# transcript — the host builds one, drops it into the layout, and focuses
# the *window*; Tuile's Window→content focus cascade (+HasContent#on_focus+)
# lands focus on the inner {Area}, so there is no focus plumbing to expose
# here:
#
#   menu = Shared::SlashMenuPopup.new(screen:, commands:, conversation:)
#   win  = Shared::InputWindow.new(on_submit: session.method(:submit), slash_menu: menu)
#   layout = Chat::Layout.new(conversation: conversation_window, input: win)
#   screen.focused = win   # cascades onto the inner Area
#
# With a +slash_menu+, the prompt also owns slash-command entry: the {Area}
# opens/filters the palette as the buffer changes, arbitrates Enter (a
# leading-+/+ buffer runs a command instead of submitting a turn), and forwards
# Up/Down/ESC to the palette while it's shown. The prompt is the natural owner —
# it already holds Enter and the buffer, and the {Area} is private, so nothing
# outside could arbitrate them.
#
# Shared by all three shells.
#
# UI-thread-confined.
class Shared::InputWindow < Tuile::Component::Window
  # Border caption. Not a constructor parameter — all three shells frame
  # the input identically.
  #
  # @return [String]
  TITLE = 'Prompt'

  # @param on_submit [Proc, Method] one-arg callable invoked with the
  #   buffer text when the user presses Enter on a non-blank line; handed
  #   straight to the wrapped {Area}.
  # @param slash_menu [Shared::SlashMenuPopup, nil] the slash-command palette
  #   this prompt drives, or nil for a plain input. This window becomes its
  #   anchor (the palette floats just above it).
  def initialize(on_submit:, slash_menu: nil)
    super(TITLE)
    self.content = Area.new(on_submit: on_submit, slash_menu: slash_menu)
    slash_menu.anchor = self if slash_menu
  end

  # The editable content: a {Tuile::Component::TextArea} that rebinds Enter
  # from "insert a newline" to "submit the buffer and clear it".
  #
  #   # Enter on "hi"   → on_submit.call("hi"), then the field clears
  #   # Enter on "   "  → no-op (a blank buffer can't burn a turn)
  #
  # Enter is line-at-a-time because pikuri's turn is, and Shift+Enter is not
  # used for a newline: most terminals don't distinguish it from a plain
  # Enter on the wire. All other TextArea behaviour (caret motion,
  # word-jumps, backspace/delete) is inherited unchanged. Private to
  # {InputWindow} — the frame is the only public handle.
  class Area < Tuile::Component::TextArea
    # @param on_submit [Proc, Method] one-arg callable invoked when the
    #   user presses Enter on a non-blank buffer. Receives the buffer text
    #   *before* it is cleared; this class owns the clear, so callers don't
    #   wipe the input in their handler.
    # @param slash_menu [Shared::SlashMenuPopup, nil] the palette to drive, or
    #   nil for a plain input (then every slash branch below is skipped).
    def initialize(on_submit:, slash_menu:)
      super()
      @on_submit = on_submit
      @slash_menu = slash_menu
      self.on_change = ->(text) { slash_menu.sync(text) } if slash_menu
    end

    # Route keys with the slash palette in mind, then fall through to
    # {Tuile::Component::TextArea#handle_key}. Returns +true+ on a consumed key
    # so it isn't re-dispatched up the tree as something else. While a palette
    # is present: Up/Down/ESC drive it *only when shown* (otherwise they edit
    # normally), and Enter on a leading-+/+ buffer runs a command instead of
    # submitting a turn.
    #
    # @param key [String]
    # @return [Boolean] +true+ if the key was consumed here.
    def handle_key(key)
      if @slash_menu
        return @slash_menu.handle_nav_key(key) if nav_key?(key) && @slash_menu.visible?
        return submit_command if key == Tuile::Keys::ENTER && active? && text.start_with?('/')
      end
      return submit if key == Tuile::Keys::ENTER && active?

      super
    end

    private

    # @param key [String]
    # @return [Boolean] whether the palette claims this key while shown.
    def nav_key?(key)
      [Tuile::Keys::UP_ARROW, Tuile::Keys::DOWN_ARROW, Tuile::Keys::ESC].include?(key)
    end

    # Run the slash command in the buffer, then clear the field. Order matters:
    # {Shared::SlashMenuPopup#submit} resolves against the still-open palette
    # (so the highlighted row wins) *before* the clear closes it.
    #
    # @return [Boolean] always true; Enter on a slash buffer is ours.
    def submit_command
      @slash_menu.submit(text.dup)
      self.text = ''
      true
    end

    # Capture the current buffer, clear it, and hand off to the host
    # callback. The order matters: clear happens before the callback so a
    # handler that triggers a synchronous redraw sees the fresh empty input
    # (and so a handler that raises doesn't leave the buffer in a
    # half-cleared state).
    #
    # @return [Boolean] always true; the host has decided Enter is a
    #   meaningful key for the input.
    def submit
      message = text.dup
      return true if message.strip.empty?

      self.text = ''
      @on_submit.call(message)
      true
    end
  end

  private_constant :Area
end
