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
    # Every changed line gets a full-width background "bar" (the +line+ tier,
    # padded to {#width} so the tint reads as a solid bar, not just a smudge
    # behind the text). A *pure* addition / removal — a line {Diff::LCS.sdiff}
    # could not pair with a similar counterpart — carries only that bar: dim
    # green for additions, dim red for removals, nothing "more changed" than
    # the whole line.
    #
    # A *modified* line — a removed line sdiff aligned against a similar added
    # line — is rendered as a single inline row on an amber +line_mod+ bar:
    # the characters that actually differ get the brighter +span+ tier on top
    # (red for the deleted characters, green for the inserted ones), the rest
    # stays on the amber line tint. A one-word edit therefore reads as one
    # tinted line with the changed word picked out, not a delete row stacked
    # over an add row. This mirrors the diff polarity Claude Code uses: subtle
    # whole-line tint, saturated changed-span.
    #
    # The +-+ / +++ / +~+ / + + gutter markers carry the
    # add/remove/modify/context meaning independently of color. Inline word
    # emphasis can't survive color stripping, so under +NO_COLOR+ (which the
    # spec suite runs under) a modified line falls back to the unambiguous
    # +-+ old / +++ new two-line form instead of the merged inline row.
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
      # The background tones a diff paints: the dim whole-line tier (for pure
      # added / removed lines and the amber modified-line bar) and the bright
      # changed-span tier (for the inserted / deleted characters within a
      # modified line).
      #
      # @!attribute [r] line_add
      #   @return [Tuile::Color] whole-line background for a pure added line.
      # @!attribute [r] line_del
      #   @return [Tuile::Color] whole-line background for a pure removed line.
      # @!attribute [r] line_mod
      #   @return [Tuile::Color] whole-line background for an inline modified line.
      # @!attribute [r] span_add
      #   @return [Tuile::Color] inserted-character background within a modified line.
      # @!attribute [r] span_del
      #   @return [Tuile::Color] deleted-character background within a modified line.
      Palette = Data.define(:line_add, :line_del, :line_mod, :span_add, :span_del)

      # Default cap on rendered diff lines before the overflow tail kicks in.
      # @return [Integer]
      DEFAULT_MAX_LINES = 40

      # The 2-column gutter prefix per row kind. The marker char distinguishes
      # add / remove / modify / context when color is stripped.
      # @return [Hash{Symbol => String}]
      GUTTERS = { context: '  ', del: '- ', add: '+ ', mod: '~ ' }.freeze
      private_constant :GUTTERS

      # One rendered diff line: its kind (drives the gutter and line tier) and
      # its text broken into +[text, span]+ segments. +span+ is +nil+ (paint
      # the line tier), +:add+, or +:del+ (paint that span tier) — only a
      # +:mod+ row mixes +:add+ / +:del+ segments inline; every other kind is a
      # single +nil+-span segment.
      #
      # @!attribute [r] kind
      #   @return [Symbol] +:context+, +:del+, +:add+, or +:mod+.
      # @!attribute [r] segments
      #   @return [Array(String, Symbol)] +[text, span]+ pairs.
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
      # each aligned change into one or more {Row}s. A +!+ (modified pair)
      # becomes a single inline +:mod+ row (deleted + inserted characters
      # picked out on one bar) when color is on, or — since inline emphasis
      # can't survive color stripping — the unambiguous +:del+ then +:add+
      # two-line form under +NO_COLOR+. Everything else is one +nil+-span row.
      #
      # @param old_lines [Array<String>]
      # @param new_lines [Array<String>]
      # @return [Array<Row>]
      def diff_rows(old_lines, new_lines)
        rows = []
        Diff::LCS.sdiff(old_lines, new_lines).each do |change|
          case change.action
          when '=' then rows << Row.new(kind: :context, segments: [[change.old_element, nil]])
          when '-' then rows << Row.new(kind: :del, segments: [[change.old_element, nil]])
          when '+' then rows << Row.new(kind: :add, segments: [[change.new_element, nil]])
          when '!' then rows.concat(modified_rows(change.old_element, change.new_element))
          end
        end
        rows
      end

      # The {Row}(s) for one modified line pair: a single inline +:mod+ row in
      # color, the +:del+ / +:add+ split in plain text (see {#diff_rows}).
      #
      # @param old_line [String]
      # @param new_line [String]
      # @return [Array<Row>]
      def modified_rows(old_line, new_line)
        return [Row.new(kind: :mod, segments: inline_segments(old_line, new_line))] if @color

        [Row.new(kind: :del, segments: [[old_line, nil]]),
         Row.new(kind: :add, segments: [[new_line, nil]])]
      end

      # Character-level diff of one modified line pair, merged into a single
      # inline sequence of +[text, span]+ segments: +=+-aligned characters
      # carry no span (+nil+, the line tier), deleted characters carry +:del+,
      # inserted ones +:add+. A substitution (+!+) emits the deleted character
      # then the inserted one. Adjacent same-span characters are coalesced.
      #
      # @param old_line [String]
      # @param new_line [String]
      # @return [Array(String, Symbol)]
      def inline_segments(old_line, new_line)
        segments = []
        Diff::LCS.sdiff(old_line.chars, new_line.chars).each do |change|
          case change.action
          when '=' then push_char(segments, change.old_element, nil)
          when '-' then push_char(segments, change.old_element, :del)
          when '+' then push_char(segments, change.new_element, :add)
          when '!'
            push_char(segments, change.old_element, :del)
            push_char(segments, change.new_element, :add)
          end
        end
        segments.empty? ? [['', nil]] : segments
      end

      # Append +char+ to +segments+, opening a fresh segment when its +span+
      # differs from the last (so runs of the same span coalesce).
      #
      # @param segments [Array(String, Symbol)]
      # @param char [String]
      # @param span [Symbol, nil]
      # @return [void]
      def push_char(segments, char, span)
        segments << [+'', span] if segments.empty? || segments.last[1] != span
        segments.last[0] << char
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

        spans = [span(gutter, line_bg)]
        row.segments.each { |text, span_kind| spans << span(text, span_kind ? span_bg_for(span_kind) : line_bg) }

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
        when :mod then @palette.line_mod
        end
      end

      # @param span [Symbol] +:add+ or +:del+.
      # @return [Tuile::Color] the span-tier background for an inline changed run.
      def span_bg_for(span)
        case span
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
