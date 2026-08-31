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
#   pane.add(Shared::PaneCaptionLabel.new('Tasks'), Fixed[1])
#
# The default +rule_token+ is +:pane_frame+, the hairline derived for the
# tinted +:pane_bg+ ground every captioned pane sits on; pass +:frame+ for a
# caption on the terminal's own background.
#
# UI-thread-confined.
class Shared::PaneCaptionLabel < Tuile::Component::Label
  # @param caption [String] the pane's name.
  # @param rule_token [Symbol] theme token for the hairline — +:pane_frame+ on
  #   a tinted ground (the default), +:frame+ on the terminal's own.
  def initialize(caption, rule_token: :pane_frame)
    super()
    @caption = caption
    @rule_token = rule_token
    refresh
  end

  # @return [String] the pane's name, as painted.
  attr_reader :caption

  protected

  # Re-renders at the new width — the rule fill is width-derived.
  # @return [void]
  def on_width_changed
    super
    refresh
  end

  # Re-renders against the new {Tuile::Screen#theme}: both tones are baked into
  # the label's text.
  # @return [void]
  def on_theme_changed
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
    text = Tuile::StyledString.plain(@caption).with_fg(theme.hint_color)
    fill = rect.width - @caption.length - 1
    text += Tuile::StyledString.styled(" #{'─' * fill}", fg: theme[@rule_token]) if fill.positive?
    self.text = text
  end
end
