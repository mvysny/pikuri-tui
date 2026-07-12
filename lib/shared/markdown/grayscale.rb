# frozen_string_literal: true

require 'tuile'

# Turns an ANSI-colored string into the same string repainted as a
# single muted-gray fg, with structural attributes (bold, italic,
# underline) preserved. Used by {Shared::TuileListener} on the thinking-pane
# path: {Shared::Markdown::Renderer} produces full-color ANSI for reasoning blocks,
# but reasoning needs to read as visually distinct from the assistant's
# final answer — one gray tone with structure intact strikes that
# balance without giving up Markdown legibility.
#
# Round-trip is through {Tuile::StyledString}: +#parse+ the input,
# repaint every span via +#with_fg(GRAY)+ + +#with_bg(nil)+ (text
# attributes pass through untouched), then +#to_ansi+ to rebuild the
# line. {Tuile::StyledString.parse} is strict — it raises
# {Tuile::StyledString::ParseError} on SGR codes it doesn't model
# (+dim+, +reverse+, +strike+, …). {Shared::Markdown::AnsiConverter}
# deliberately emits only that supported alphabet (see its "Output
# contract" doc) so the happy path is fine; if a styling tweak ever
# emits an unsupported code we log
# through the +'markdown'+ pikuri logger and return the input unrecolored rather
# than tearing down the agent loop with an uncaught raise on the
# worker thread. The expected fix when the log fires is to add the
# missing code to {Tuile::StyledString}'s parser, not to grow a
# parallel ANSI parser here.
module Shared::Markdown::Grayscale
  # The fallback tone applied when {.recolor} is called without an
  # explicit +fg:+ — +#555555+, the +Rainbow.color(85, 85, 85)+ tone the
  # listener used for thinking text before this module existed (same SGR,
  # +\e[38;2;85;85;85m+). The themed call sites pass
  # +Shared::AppTheme+'s +:thinking+ token instead (the dark variant is this
  # same color); this default keeps the module usable — and its spec
  # screen-free — without a {Tuile::Theme} in hand.
  # @return [Tuile::Color]
  GRAY = Tuile::Color.new([85, 85, 85])

  LOG = Pikuri.logger_for('markdown')
  private_constant :LOG

  class << self
    # Repaint +ansi+ as one flat tone, preserving bold/italic/underline.
    # Empty input fast-paths to the empty string.
    #
    # @param ansi [String] ANSI/SGR-coded line. May contain no escapes
    #   (treated as one default-styled span), or arbitrarily many
    #   supported SGR runs.
    # @param fg [Tuile::Color] the foreground every span is repainted to.
    #   Defaults to {GRAY}; callers with a {Tuile::Screen} pass their
    #   theme's +:thinking+ token so the tone tracks light/dark.
    # @return [String] same content, repainted. On parse failure (an
    #   SGR code {Tuile::StyledString} doesn't model), returns +ansi+
    #   unchanged and logs through the +'markdown'+ pikuri logger.
    def recolor(ansi, fg: GRAY)
      return ansi if ansi.nil? || ansi.empty?

      Tuile::StyledString.parse(ansi).with_fg(fg).with_bg(nil).to_ansi
    rescue Tuile::StyledString::ParseError => e
      LOG.warn(
        "Shared::Markdown::Grayscale.recolor: StyledString parse failed " \
        "(#{e.class}: #{e.message}); returning input unrecolored"
      )
      ansi
    end
  end
end
