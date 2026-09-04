# frozen_string_literal: true

require 'tuile'

# A {Tuile::Component::TextView} that reads but never answers: display-only, so
# Tab never parks focus on it and a click can't either.
#
#   view = Shared::PassiveTextView.new
#   view.scrollbar_visibility = :gone   # nothing focuses it, so nothing can scroll it
#
# Tuile's +TextView+ is a tab stop by default, which is right for a transcript
# the user pages through and wrong for a summary pane: a focus stop that ignores
# every key is a hole in the Tab order. Reach for this whenever a pane displays
# and nothing more.
class Shared::PassiveTextView < Tuile::Component::TextView
  # @return [Boolean] false — nothing here to interact with.
  def focusable? = false

  # @return [Boolean] false — keeps Tab moving between the panes that do take
  #   keys.
  def tab_stop? = false
end
