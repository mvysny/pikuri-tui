# frozen_string_literal: true

require 'tuile'

# The diagnostic log: a {Tuile::Component::LogDialog} that tells its host when
# the user dismisses it.
#
#   dialog = Shared::Log::Dialog.new(on_dismiss: -> { error_count = 0 })
#   Pikuri.log_io = Tuile::Component::LogDialog::IO.new(dialog)  # logs while closed
#   dialog.open                                                   # ESC / q → on_dismiss
#
# Built once at boot and reopened, so +Pikuri.log_io=+ has a sink from the
# first write — agent construction already logs — long before the user opens
# it.
#
# UI-thread-confined.
class Shared::Log::Dialog < Tuile::Component::LogDialog
  # @param on_dismiss [Proc, Method] zero-arg callable fired on the UI thread
  #   after the dialog leaves the screen, so a handler inspecting the screen
  #   sees it already gone. Not fired when {Tuile::Screen.close} tears it down:
  #   that is not the user having read the logs.
  def initialize(on_dismiss:)
    super('Log')
    on_close { on_dismiss.call unless _1.reason == :teardown }
  end
end
