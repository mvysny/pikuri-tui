# frozen_string_literal: true

# Paints one component the way {Tuile::Screen#repaint} would, for the specs
# that read a row back off the buffer because the component renders its items
# at paint time (the slash palette, the leader menu's picker, the transcript's
# indentation).
#
# There is no shorter way since tuile's canvas seam: {Tuile::Component#repaint}
# takes a required {Tuile::Canvas}, and only {Tuile::Screen#canvas_for} builds
# one carrying that component's resolved background and clip.
module PaintOne
  # Settles the layout first, exactly as {Tuile::Screen#repaint} does — paint is
  # the heaviest reader of rects there is, and a spec dispatches no event to
  # settle them. The whole screen, since an ancestor (the pane, once a popup
  # opens) may owe this component its rect.
  #
  # @param component [Tuile::Component]
  # @return [void]
  def paint(component)
    Tuile::Screen.instance.flush_layout
    component.flush_layout
    component.repaint(Tuile::Screen.instance.canvas_for(component))
  end

  # The painted rows under +component+, read back in **screen** coordinates —
  # a rect is measured inside its parent now, so the buffer is addressed
  # through {Tuile::Component#absolute_rect} rather than +rect+.
  #
  # @param component [Tuile::Component] the component to paint and read.
  # @param trim_right [Integer] columns to drop off the right edge, for a pane
  #   whose scrollbar would otherwise land in the compared text.
  # @return [Array<String>] one string per row, top to bottom, untrimmed.
  def painted_region(component, trim_right: 0)
    paint(component)
    rect = component.absolute_rect
    area = Tuile::Rect.new(rect.left, rect.top, [rect.width - trim_right, 0].max, rect.height)
    Tuile::Screen.instance.buffer.region_text(area)
  end
end
