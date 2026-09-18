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

  # @param caption [String, Tuile::StyledString] the pane's new name.
  #   Re-renders the row, so the hairline re-fills to whatever width the new
  #   name leaves.
  # @return [void]
  def caption=(caption)
    return if caption == @caption

    @caption = caption
    refresh
  end

  protected

  # Re-renders at the new width — the rule fill is width-derived.
  # @return [void]
  def handle_width_changed
    super
    refresh
  end

  # Re-renders against the new {Tuile::Screen#theme}: both tones are baked into
  # the label's text.
  # @return [void]
  def handle_theme_changed
    super
    refresh
  end

  private

  # Rebuilds the row: caption, a space, then hairline to the right edge. A
  # width too narrow for the rule simply drops it (the {Tuile::Component::Label}
  # ellipsizes the caption itself).
  #
  # @return [void]
  def refresh
    theme = screen.theme
    caption = @caption.is_a?(Tuile::StyledString) ? @caption : Tuile::StyledString.plain(@caption)
    text = under_fg(caption, theme[:hint])
    fill = rect.width - caption.display_width - 1
    text += Tuile::StyledString.styled(" #{'─' * fill}", fg: theme[:pane_frame]) if fill.positive?
    self.text = text
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
