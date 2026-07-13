# frozen_string_literal: true

require 'tuile'

# {Tuile::Component::Popup} subclass that wraps a long-lived
# {Tuile::Component::LogWindow} and notifies the host on dismiss.
#
# The wrapped +LogWindow+ is constructed eagerly at boot (so
# +Pikuri.log_io=+ has a sink from the first write — early ruby_llm /
# agent / tool log noise from agent construction would be lost
# otherwise) but is only shown when the user presses the toggle key.
# The popup hosts the same +LogWindow+ instance across many open/close
# cycles; +Tuile::Component::Popup+ supports this directly (it nils its
# parent on close, so it can be re-added on the next open).
#
# On dismiss (ESC / q from the popup itself), the host's
# +on_dismiss+ callback fires so it can reset the conversation Window's
# error-count cell — the user has now *seen* the logs, so the unread
# counter resets.
#
# UI-thread-confined.
class Shared::Log::Popup < Tuile::Component::Popup
  # @param log_window [Tuile::Component::LogWindow] the eager-constructed
  #   log destination this popup wraps. Its parent is set to +self+
  #   here; do not re-parent it elsewhere.
  # @param on_dismiss [Proc, Method] zero-arg callable fired after the
  #   popup is closed. Runs on the event-loop thread (close is invoked
  #   by Tuile's key dispatch) so it may safely mutate UI state.
  def initialize(log_window:, on_dismiss:)
    super(content: log_window)
    @on_dismiss = on_dismiss
  end

  # Closes the popup and fires +@on_dismiss+. The base implementation
  # unmounts the popup from the screen first; the callback runs after,
  # so handlers that inspect screen state see the popup as already
  # gone.
  #
  # @return [void]
  def close
    super
    @on_dismiss.call
  end
end
