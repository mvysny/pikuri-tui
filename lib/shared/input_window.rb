# frozen_string_literal: true

require 'tuile'

# The bottom input pane, framed: a {Tuile::Component::Window} captioned
# "Prompt" wrapping a {Shared::InputArea} (Enter submits, blank buffers
# are a no-op). Frames the input the way {Shared::ConversationWindow}
# frames the transcript — the host builds one, drops it into the layout,
# and focuses the *window*; Tuile's Window→content focus cascade
# (+HasContent#on_focus+) lands focus on the inner {Shared::InputArea},
# so there is no focus plumbing to expose here:
#
#   win = Shared::InputWindow.new(on_submit: method(:submit_message))
#   layout = Chat::Layout.new(conversation: conversation_window, input: win)
#   screen.focused = win   # cascades onto the inner InputArea
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
  #   straight to the wrapped {Shared::InputArea}.
  def initialize(on_submit:)
    super(TITLE)
    self.content = Shared::InputArea.new(on_submit: on_submit)
  end
end
