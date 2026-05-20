# frozen_string_literal: true

require 'tuile'

module PikuriTui
  # Turns an ANSI-colored string into the same string repainted as a
  # single muted-gray fg, with structural attributes (bold, italic,
  # underline) preserved. Used by {TuileListener} on the thinking-pane
  # path: +TTY::Markdown+ produces full-color ANSI for reasoning blocks,
  # but reasoning needs to read as visually distinct from the assistant's
  # final answer — one gray tone with structure intact strikes that
  # balance without giving up Markdown legibility.
  #
  # Round-trip is through {Tuile::StyledString}: +#parse+ the input,
  # repaint every span via +#with_fg(GRAY)+ + +#with_bg(nil)+ (text
  # attributes pass through untouched), then +#to_ansi+ to rebuild the
  # line. {Tuile::StyledString.parse} is strict — it raises
  # {Tuile::StyledString::ParseError} on SGR codes it doesn't model
  # (+dim+, +reverse+, +strike+, …). +TTY::Markdown+'s default theme
  # uses Pastel and sticks to fg/bold/italic so the happy path is
  # fine; if a theme tweak ever emits an unsupported code we log
  # through {Tuile.logger} and return the input unrecolored rather
  # than tearing down the agent loop with an uncaught raise on the
  # worker thread. The expected fix when the log fires is to add the
  # missing code to {Tuile::StyledString}'s parser, not to grow a
  # parallel ANSI parser here.
  module AnsiGrayscale
    # The gray fg every recolored span carries. Matches the
    # +Rainbow.color(85, 85, 85)+ tone the listener used for thinking
    # text before this module existed — same SGR (+\e[38;2;85;85;85m+),
    # kept as a constant so any future adjustment lands in one place.
    # @return [Tuile::Color]
    GRAY = Tuile::Color.new([85, 85, 85])

    class << self
      # Repaint +ansi+ as one gray tone, preserving bold/italic/underline.
      # Empty input fast-paths to the empty string.
      #
      # @param ansi [String] ANSI/SGR-coded line. May contain no escapes
      #   (treated as one default-styled span), or arbitrarily many
      #   supported SGR runs.
      # @return [String] same content, repainted. On parse failure (an
      #   SGR code {Tuile::StyledString} doesn't model), returns +ansi+
      #   unchanged and logs through {Tuile.logger}.
      def recolor(ansi)
        return ansi if ansi.nil? || ansi.empty?

        Tuile::StyledString.parse(ansi).with_fg(GRAY).with_bg(nil).to_ansi
      rescue Tuile::StyledString::ParseError => e
        Tuile.logger.warn(
          "AnsiGrayscale.recolor: StyledString parse failed " \
          "(#{e.class}: #{e.message}); returning input unrecolored"
        )
        ansi
      end
    end
  end
end
