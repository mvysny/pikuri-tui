# frozen_string_literal: true

require 'tuile'

# A borderless pane's caption row: the pane's name in the theme's
# {Shared::AppTheme::TALUS} hint accent, then a hairline rule filling the rest
# of the width.
#
#   Tasks ──────────────────────
#
# This is what replaced the caption a {Tuile::Component::Window} used to paint
# into its top border. The rule half is what keeps the row reading as a
# *boundary* — without it a bare word floating above content reads as a list
# item, not a section head.
#
#   caption = Shared::PaneCaptionLabel.new('Tasks')
#   pane.add(caption, Fixed[1])
#   caption.caption = 'Tasks: 2/5'   # a pane carrying a live count re-labels it
#   caption.caption = Tuile::StyledString.plain('Changes: 13; ') +
#                     Tuile::StyledString.styled('+147', fg: theme[:added])
#
# The accent is filled *under* the caption rather than painted over it, so the
# toned half of that tally survives and only the prose picks the accent up.
#
# The hairline is +:pane_frame+, derived for the tinted +:pane_bg+ ground every
# captioned pane sits on. There is no token parameter: every borderless
# surface in these shells that carries chrome is a tinted secondary — the one
# untinted pane, the transcript, has no caption and no rule.
#
# UI-thread-confined.
class Shared::PaneCaptionLabel < Tuile::Component::Label
  # @param caption [String, Tuile::StyledString] the pane's name.
  def initialize(caption)
    super()
    @caption = caption
    refresh
  end

  # @return [String, Tuile::StyledString] the pane's name, as set.
  attr_reader :caption

  # @param caption [String, Tuile::StyledString] the pane's new name; the
  #   hairline re-fills to whatever width it leaves.
  # @return [void]
  def caption=(caption)
    return if caption == @caption

    @caption = caption
    refresh
  end

  # Paints the caption, then the hairline out to the right edge — ink, not
  # text, because only at paint time is the width settled. A width too narrow
  # for the rule drops it.
  #
  # @param canvas [Tuile::Canvas]
  # @return [void]
  def repaint(canvas)
    super
    used = text.display_width
    fill = width - used - 1
    return unless fill.positive?

    canvas.set_text(used, 0, Tuile::StyledString.styled(" #{'─' * fill}", fg: screen.theme[:pane_frame]))
  end

  protected

  # Re-renders against the new {Tuile::Screen#theme}: the caption's tone is
  # baked into the label's text.
  # @return [void]
  def handle_theme_changed
    super
    refresh
  end

  private

  # Rebuilds the caption text in the hint accent; {#repaint} adds the rule (the
  # {Tuile::Component::Label} ellipsizes the caption itself).
  #
  # @return [void]
  def refresh
    caption = @caption.is_a?(Tuile::StyledString) ? @caption : Tuile::StyledString.plain(@caption)
    self.text = under_fg(caption, screen.theme[:hint])
  end

  # +text+ with +fg+ on the spans that carry none, the rest untouched — the
  # foreground counterpart of +Tuile::StyledString#under_bg+, which upstream
  # has no fg sibling for (+with_fg+ overrides every span).
  #
  # @param text [Tuile::StyledString]
  # @param fg [Tuile::Color]
  # @return [Tuile::StyledString]
  def under_fg(text, fg)
    Tuile::StyledString.new(text.spans.map do |span|
      next span unless span.style.fg.nil?

      Tuile::StyledString::Span.new(text: span.text, style: span.style.merge(fg: fg))
    end)
  end
end
