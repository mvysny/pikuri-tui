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
#   win = Shared::InputWindow.new(on_submit: method(:submit_message))
#   layout = Chat::Layout.new(conversation: conversation_window, input: win)
#   screen.focused = win   # cascades onto the inner Area
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
  def initialize(on_submit:)
    super(TITLE)
    self.content = Area.new(on_submit: on_submit)
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
    def initialize(on_submit:)
      super()
      @on_submit = on_submit
    end

    # Intercept Enter to submit; every other key falls through to
    # {Tuile::Component::TextArea#handle_key}. Returns +true+ on a consumed
    # Enter — including the blank-buffer no-op — so the key isn't
    # re-dispatched up the tree as something else.
    #
    # @param key [String]
    # @return [Boolean] +true+ if the key was consumed here.
    def handle_key(key)
      return submit if key == Tuile::Keys::ENTER && active?

      super
    end

    private

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
