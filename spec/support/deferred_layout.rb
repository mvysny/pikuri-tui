# frozen_string_literal: true

# Layout is deferred: a mutation ({Tuile::Component#rect=}, a
# {Tuile::Component#visible=} flip, a {Code::Layout#sidebar_mode=}) only *marks*
# the container, and {Tuile::Screen#dispatch} settles the marks at the end of
# the event that rode in. A spec dispatches no such event, so it settles by
# hand before reading any rect it just dirtied.
#
# The same module tuile's own suite carries, under the same name — a spec here
# that sizes a pane reads side by side with one there.
module DeferredLayout
  # @param target [Tuile::Component, Tuile::Screen] what owes a relayout — the
  #   container the example just sized, or the screen when the mutation is
  #   somewhere inside a mounted shell.
  # @return [Tuile::Component, Tuile::Screen] +target+, its rects current.
  def settle(target) = target.tap(&:flush_layout)
end
