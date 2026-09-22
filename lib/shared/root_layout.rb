# frozen_string_literal: true

require 'tuile'

# The screen's content component: a shell's pane layout with the
# {Shared::StatusBar} on the last row.
#
#   screen.content = Shared::RootLayout.new(Chat::Layout.new(...), status_bar)
#
# Tuile draws no status bar and reserves no row for one (its +DECISIONS.md+
# +D-status-bar+), so the bottom line is a component the app has to place
# itself — which is all this layout is: the shell takes every row the bar
# doesn't, the bar takes exactly one.
#
# UI-thread-confined.
class Shared::RootLayout < Tuile::Component::Layout::Vertical
  # @param shell [Tuile::Component::Layout] the shell's own pane layout.
  # @param status_bar [Shared::StatusBar] the bottom row.
  def initialize(shell, status_bar)
    super()
    @shell = shell
    @status_bar = status_bar
    add(shell, Expand[1])
    add(status_bar, Fixed[1])
  end

  # @return [Tuile::Component::Layout] the shell's pane layout.
  attr_reader :shell

  # @return [Shared::StatusBar] the bottom row.
  attr_reader :status_bar
end
