# frozen_string_literal: true

require 'tuile'

module PikuriTui
  module Chat
    # The bottom-pane text input. Subclasses {Tuile::Component::TextArea} to
    # rebind Enter from "insert newline" to "submit and clear" — pikuri's
    # CLI is line-at-a-time, and Shift+Enter for newline is not portable
    # across terminals (most don't distinguish it from a plain Enter on the
    # wire). All other TextArea behaviour (caret motion, word-jumps,
    # backspace/delete) is inherited unchanged.
    #
    # Empty / whitespace-only buffers are not submitted — Enter is a no-op
    # so the user can't accidentally burn a turn on a blank message.
    class Input < Tuile::Component::TextArea
      # @param on_submit [Proc, Method] one-arg callable invoked when the
      #   user presses Enter on a non-blank buffer. Receives the buffer text
      #   *before* it is cleared; Input is responsible for the clear, so
      #   callers don't need to wipe the input in their handler.
      def initialize(on_submit:)
        super()
        @on_submit = on_submit
      end

      # Intercepts Enter to fire {@on_submit}; everything else falls through
      # to {Tuile::Component::TextArea#handle_key}. Returns true on a
      # consumed Enter (including the blank-buffer no-op case) so the key
      # doesn't get re-dispatched up the tree as something else.
      #
      # @param key [String]
      # @return [Boolean]
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
      #   meaningful key for Input
      def submit
        message = text.dup
        return true if message.strip.empty?

        self.text = ''
        @on_submit.call(message)
        true
      end
    end
  end
end
