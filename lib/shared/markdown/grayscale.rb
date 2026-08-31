# frozen_string_literal: true

require 'tuile'

# Repaints an ANSI-colored string as one muted-gray foreground, preserving
# structural attributes (bold, italic, underline):
#
#   Shared::Markdown::Grayscale.recolor(rendered_ansi, fg: theme[:thinking])
#
# Used by {Shared::ConversationTextView} on the thinking-pane path so
# reasoning reads as visually distinct from the assistant's final answer —
# one gray tone, structure intact, without giving up Markdown legibility.
#
# Round-trips through {Tuile::StyledString} (+parse+ → +with_fg+ →
# +to_ansi+), whose parser is strict: it raises
# {Tuile::StyledString::ParseError} on SGR codes it doesn't model (+dim+,
# +reverse+, +strike+, …). {Shared::Markdown::AnsiConverter} deliberately
# emits only that supported alphabet (see its "Output contract"), so the
# happy path is fine; an unsupported code is logged and returns the input
# unrecolored rather than raising on the worker thread. The fix when that
# log fires is to teach {Tuile::StyledString}'s parser the missing code,
# not to grow a parallel ANSI parser here.
module Shared::Markdown::Grayscale
  # The fallback tone applied when {.recolor} is called without an explicit
  # +fg:+ — +#555555+ (+\e[38;2;85;85;85m+). Themed call sites pass
  # {Shared::AppTheme}'s +:thinking+ token instead (its dark variant is this
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
