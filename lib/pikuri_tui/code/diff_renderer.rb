# frozen_string_literal: true

require 'tuile'
require 'diff/lcs'

module PikuriTui
  module Code
    # Renders a before/after string pair as a two-tier, ANSI-colored unified
    # diff for the conversation pane — the visual the edit / write tool
    # formatters paint instead of dumping raw arguments.
    #
    # == Two-tier coloring
    #
    # Every changed line gets a full-width background "bar" (the +line+ tier:
    # dim red for removals, dim green for additions, padded to {#width} so the
    # tint reads as a solid bar, not just a smudge behind the text). Within a
    # *modified* pair — a removed line that {Diff::LCS.sdiff} aligned against a
    # similar added line — the characters that actually differ get a second,
    # brighter background (the +span+ tier). Pure additions and pure deletions
    # (no aligned counterpart) carry only the line tier; there's nothing "more
    # changed" than the whole line. This mirrors the diff polarity Claude Code
    # uses: subtle whole-line tint, saturated changed-span.
    #
    # The +-+ / +++ / + + gutter markers carry the add/remove/context meaning
    # independently of color, so the output stays readable when +NO_COLOR+
    # strips the backgrounds away (the spec suite runs under +NO_COLOR+).
    #
    # == Colors come from the theme
    #
    # Like {AnsiGrayscale} (which takes a +fg:+ {Tuile::Color}, not a theme),
    # this takes its colors as an injected {Palette} and its width as a
    # parameter rather than reaching for a {Tuile::Screen} / {AppTheme} — so
    # it renders (and tests) without a screen. There is no built-in fallback
    # palette: the caller always supplies one. The tool formatters build it
    # from the *active* {AppTheme}'s four +:diff_*+ tokens at render time, so
    # the tones track the OS light/dark appearance — both {AppTheme::DARK}
    # and {AppTheme::LIGHT} define a tuned variant (dim bars + bright spans on
    # dark; light tints + stronger spans on light).
    #
    # Output is built from {Tuile::StyledString} spans and emitted via
    # +#to_ansi+, so it only ever contains the SGR alphabet
    # {Tuile::StyledString.parse} models — the conversation +TextView+
    # re-parses it without surprises.
    class DiffRenderer
      # The four background tones a diff paints: the dim whole-line tier and
      # the bright changed-span tier, for additions and removals.
      #
      # @!attribute [r] line_add
      #   @return [Tuile::Color] whole-line background for an added line.
      # @!attribute [r] line_del
      #   @return [Tuile::Color] whole-line background for a removed line.
      # @!attribute [r] span_add
      #   @return [Tuile::Color] changed-character background within an added line.
      # @!attribute [r] span_del
      #   @return [Tuile::Color] changed-character background within a removed line.
      Palette = Data.define(:line_add, :line_del, :span_add, :span_del)

      # Default cap on rendered diff lines before the overflow tail kicks in.
      # @return [Integer]
      DEFAULT_MAX_LINES = 40

      # The 2-column gutter prefix per row kind. The marker char distinguishes
      # add / remove / context when color is stripped.
      # @return [Hash{Symbol => String}]
      GUTTERS = { context: '  ', del: '- ', add: '+ ' }.freeze
      private_constant :GUTTERS

      # One rendered diff line: its kind (drives the gutter and line tier) and
      # its text broken into +[text, emphasized]+ segments (emphasized
      # segments get the span tier).
      #
      # @!attribute [r] kind
      #   @return [Symbol] +:context+, +:del+, or +:add+.
      # @!attribute [r] segments
      #   @return [Array(String, Boolean)] +[text, emphasized?]+ pairs.
      Row = Data.define(:kind, :segments)
      private_constant :Row

      # Render +old+ → +new+ as an ANSI diff string.
      #
      # @param old [String] the "before" content.
      # @param new [String] the "after" content.
      # @param width [Integer] target column width; line bars pad to this.
      # @param palette [Palette] the four diff tones, built by the caller from
      #   the active theme's +:diff_*+ tokens (so light/dark both work).
      # @param max_lines [Integer] cap before the +… +N more lines+ tail.
      # @param color [Boolean, nil] force color on (+true+) / off (+false+);
      #   +nil+ (default) follows +NO_COLOR+.
      # @return [String] newline-joined ANSI diff (no trailing newline).
      def self.render(old, new, width:, palette:, max_lines: DEFAULT_MAX_LINES, color: nil)
        new(width: width, palette: palette, max_lines: max_lines, color: color).render(old, new)
      end

      # @param width [Integer] see {.render}.
      # @param palette [Palette] see {.render}.
      # @param max_lines [Integer] see {.render}.
      # @param color [Boolean, nil] see {.render}.
      def initialize(width:, palette:, max_lines:, color:)
        @width = [width, 1].max
        @palette = palette
        @max_lines = max_lines
        @color = color.nil? ? ENV['NO_COLOR'].to_s.empty? : color
      end

      # @return [Integer] the column width line bars pad to.
      attr_reader :width

      # @param old [String]
      # @param new [String]
      # @return [String] see {.render}.
      def render(old, new)
        rows = diff_rows(split_lines(old), split_lines(new))
        shown = rows.first(@max_lines)
        dropped = rows.length - shown.length

        out = shown.map { |row| render_row(row) }
        out << overflow_line(dropped) if dropped.positive?
        out.join("\n")
      end

      private

      # Split content into display lines, dropping only the phantom empty
      # element a single trailing newline produces (internal blank lines are
      # preserved). Empty input yields no lines.
      #
      # @param str [String]
      # @return [Array<String>]
      def split_lines(str)
        return [] if str.nil? || str.empty?

        lines = str.split("\n", -1)
        lines.pop if lines.last == '' && str.end_with?("\n")
        lines
      end

      # Align +old_lines+ against +new_lines+ with {Diff::LCS.sdiff} and turn
      # each aligned change into one or two {Row}s. A +!+ (modified pair)
      # becomes a removed row + an added row, each with character-level
      # emphasis; everything else is a single row with no emphasis.
      #
      # @param old_lines [Array<String>]
      # @param new_lines [Array<String>]
      # @return [Array<Row>]
      def diff_rows(old_lines, new_lines)
        rows = []
        Diff::LCS.sdiff(old_lines, new_lines).each do |change|
          case change.action
          when '=' then rows << Row.new(kind: :context, segments: [[change.old_element, false]])
          when '-' then rows << Row.new(kind: :del, segments: [[change.old_element, false]])
          when '+' then rows << Row.new(kind: :add, segments: [[change.new_element, false]])
          when '!'
            rows << Row.new(kind: :del, segments: char_segments(change.old_element, change.new_element, :del))
            rows << Row.new(kind: :add, segments: char_segments(change.old_element, change.new_element, :add))
          end
        end
        rows
      end

      # Character-level diff of one modified line pair, projected onto one
      # side. Returns +[text, emphasized]+ segments where emphasized runs are
      # the characters unique to this side (the inserted/deleted text);
      # +=+-aligned characters are unemphasized. Adjacent same-emphasis
      # characters are coalesced into one segment.
      #
      # @param old_line [String]
      # @param new_line [String]
      # @param side [Symbol] +:del+ (project onto the old line) or +:add+.
      # @return [Array(String, Boolean)]
      def char_segments(old_line, new_line, side)
        drop = side == :del ? '+' : '-'
        pick = side == :del ? :old_element : :new_element
        segments = []
        Diff::LCS.sdiff(old_line.chars, new_line.chars).each do |change|
          next if change.action == drop

          char = change.public_send(pick)
          next if char.nil?

          emphasized = change.action != '='
          segments << [+'', emphasized] if segments.empty? || segments.last[1] != emphasized
          segments.last[0] << char
        end
        segments.empty? ? [['', false]] : segments
      end

      # Render one {Row} to a string: plain +gutter+text+ when color is off,
      # otherwise a {Tuile::StyledString} with the line tier behind the whole
      # row, the span tier on emphasized segments, and trailing padding to
      # {#width} so the bar is solid.
      #
      # @param row [Row]
      # @return [String]
      def render_row(row)
        gutter = GUTTERS.fetch(row.kind)
        return "#{gutter}#{row.segments.map(&:first).join}" unless @color

        line_bg = line_bg_for(row.kind)
        span_bg = span_bg_for(row.kind)

        spans = [span(gutter, line_bg)]
        row.segments.each { |text, emphasized| spans << span(text, emphasized ? span_bg : line_bg) }

        styled = Tuile::StyledString.new(spans)
        pad = @width - styled.display_width
        styled += Tuile::StyledString.new([span(' ' * pad, line_bg)]) if line_bg && pad.positive?
        styled.to_ansi
      end

      # The +… +N more lines+ tail shown when the diff exceeds {DEFAULT_MAX_LINES}.
      # Plain (no bar) — it's a meta note, not diff content.
      #
      # @param dropped [Integer]
      # @return [String]
      def overflow_line(dropped)
        "  … +#{dropped} more line#{dropped == 1 ? '' : 's'}"
      end

      # @param kind [Symbol]
      # @return [Tuile::Color, nil] the line-tier background, or +nil+ for context.
      def line_bg_for(kind)
        case kind
        when :add then @palette.line_add
        when :del then @palette.line_del
        end
      end

      # @param kind [Symbol]
      # @return [Tuile::Color, nil] the span-tier background, or +nil+ for context.
      def span_bg_for(kind)
        case kind
        when :add then @palette.span_add
        when :del then @palette.span_del
        end
      end

      # @param text [String]
      # @param bg [Tuile::Color, nil]
      # @return [Tuile::StyledString::Span]
      def span(text, bg)
        Tuile::StyledString::Span.new(text: text, style: Tuile::StyledString::Style.new(bg: bg))
      end
    end
  end
end
