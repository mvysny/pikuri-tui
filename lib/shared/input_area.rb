# frozen_string_literal: true

require 'tuile'

# The bottom-pane text input: a {Tuile::Component::TextArea} that rebinds
# Enter from "insert a newline" to "submit the buffer and clear it".
#
#   input = Shared::InputArea.new(on_submit: method(:submit_message))
#   # Enter on "hi"   → submit_message("hi"), then the field clears
#   # Enter on "   "  → no-op (a blank buffer can't burn a turn)
#
# Enter is line-at-a-time because pikuri's turn is, and Shift+Enter is not
# used for a newline: most terminals don't distinguish it from a plain Enter
# on the wire. All other TextArea behaviour (caret motion, word-jumps,
# backspace/delete) is inherited unchanged.
#
# UI-thread-confined.
class Shared::InputArea < Tuile::Component::TextArea
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
  # handler that triggers a synchronous redraw sees the fresh empty
  # input (and so a handler that raises doesn't leave the buffer in a
  # half-cleared state).
  #
  # @return [Boolean] always true; the host has decided Enter is a
  #   meaningful key for Shared::InputArea
  def submit
    message = text.dup
    return true if message.strip.empty?

    self.text = ''
    @on_submit.call(message)
    true
  end
end
