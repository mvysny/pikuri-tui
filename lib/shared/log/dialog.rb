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
# == Implementation details
#
# The hook is {#close}, not +on_close+: +on_close+ also fires when the screen
# tears down, which is not the user having read the logs.
#
# UI-thread-confined.
class Shared::Log::Dialog < Tuile::Component::LogDialog
  # @param on_dismiss [Proc, Method] zero-arg callable fired after {#close},
  #   on the UI thread, so it may mutate UI state.
  def initialize(on_dismiss:)
    super('Log')
    @on_dismiss = on_dismiss
  end

  # Closes the dialog, then fires +on_dismiss+ — after the unmount, so a
  # handler inspecting the screen sees the dialog already gone.
  #
  # @return [void]
  def close
    super
    @on_dismiss.call
  end
end
