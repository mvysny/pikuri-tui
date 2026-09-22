# frozen_string_literal: true

require 'tuile'

# A {Tuile::Component::List} that reads but never answers: display-only, so Tab
# never parks focus on it and a click can't either. For a summary pane, one row
# per item — a renderer that needs the width lays its row out against it, and
# the list ellipsizes the rest.
#
#   @view = Shared::PassiveList.new
#   @view.renderer = method(:row)   # (item, width) -> row
#   @view.items = tasks
#
# Tuile's +List+ is a tab stop by default, which is right for a picker and wrong
# for a summary pane: a focus stop that ignores every key is a hole in the Tab
# order.
class Shared::PassiveList < Tuile::Component::List
  # @return [Boolean] false — nothing here to interact with.
  def focusable? = false

  # @return [Boolean] false — keeps Tab moving between the panes that do take
  #   keys.
  def tab_stop? = false
end
