# frozen_string_literal: true

require 'tuile'

# A {Tuile::Component::List} that reads but never answers: display-only, so Tab
# never parks focus on it and a click can't either. The {Shared::PassiveTextView}
# of one-row-per-item panes — a row wider than the pane is ellipsized by the
# list itself, at paint time.
#
#   @view = Shared::PassiveList.new
#   @view.renderer = method(:row)
#   @view.items = tasks
class Shared::PassiveList < Tuile::Component::List
  # @return [Boolean] false — nothing here to interact with.
  def focusable? = false

  # @return [Boolean] false — keeps Tab moving between the panes that do take
  #   keys.
  def tab_stop? = false
end
