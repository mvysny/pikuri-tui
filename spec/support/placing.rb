# frozen_string_literal: true

# Puts a component at a rect the only way a rect gets there: through what places
# it. A spec never writes +rect=+ — {Tuile::Component#rect=} raises outside the
# parent's +relayout+.
module Placing
  # @param component [Tuile::Component]
  # @param rect [Tuile::Rect] in the parent's coordinates (the screen's, for an
  #   open overlay).
  # @return [Tuile::Component] +component+, settled.
  def place(component, rect)
    parent = component.parent
    case parent
    when nil
      # A root has nothing to place it, so a holder does, and lets go again:
      # the rect it assigned stays.
      holder = Tuile::Component::Layout::Absolute.new
      holder.add(component, rect)
      holder.flush_layout
      holder.remove(component)
    when Tuile::Component::Layout::Absolute
      parent.constrain(component, rect)
    when Tuile::ScreenPane
      if component.is_a?(Tuile::Component::Overlay)
        component.placement = Tuile::Component::Overlay::At[rect]
      else
        # The pane hands its content the whole screen, so a holder takes over.
        holder = Tuile::Component::Layout::Absolute.new
        Tuile::Screen.instance.content = holder
        holder.add(component, rect)
      end
    else
      raise ArgumentError, "place: #{parent} places #{component} itself; constrain it there"
    end
    settle(component)
  end
end
