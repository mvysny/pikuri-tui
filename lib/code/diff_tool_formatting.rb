# frozen_string_literal: true

require 'tuile'

module Code
  # Shared rendering helpers for the edit / write tool formatters
  # ({EditFormatter}, {WriteFormatter}). Plain module functions rather
  # than a base class — the two formatters differ only in how they derive
  # the before/after pair, so they compose this rendering rather than
  # inheriting it.
  #
  # Both the call-time diff block and the result-time error line live here
  # so the two formatters stay identical wherever they can: a +ToolCall+
  # renders {render_call} (a themed header over a {DiffRenderer} body), and
  # the paired +ToolResult+ renders {render_result} — +nil+ on success (the
  # diff already showed the change), the error line otherwise.
  module DiffToolFormatting
    module_function

    # Glyph prefixing the diff header, marking the line as a file mutation.
    # @return [String]
    GLYPH = '✎'

    # Render the call-time diff block: a themed header line
    # (+"✎ <verb>  <path>"+) over the {DiffRenderer} diff of +old+ → +new+.
    #
    # @param verb [String] the action shown in the header (+"edit"+,
    #   +"write"+, +"create"+).
    # @param path [String] the file path shown in the header.
    # @param old [String] the "before" content.
    # @param new [String] the "after" content.
    # @param width [Integer] target render width (the conversation pane's).
    # @param theme [Tuile::Theme] the active theme; supplies the header
    #   color and the four diff background tones.
    # @return [String] header + ANSI diff body.
    def render_call(verb:, path:, old:, new:, width:, theme:)
      header = theme.tool("#{GLYPH} #{verb}  #{path}")
      body = DiffRenderer.render(old, new, width: width, palette: palette(theme))
      "#{header}\n#{body}"
    end

    # Render the result-time line for a paired edit / write +ToolResult+.
    # Success is silent — the diff already told the story; an +"Error: ..."+
    # observation surfaces as a themed error line so a failed attempt
    # (rare) doesn't read as if it applied.
    #
    # @param content [String] the tool observation.
    # @param theme [Tuile::Theme] the active theme.
    # @return [String, nil] the error line, or +nil+ to suppress on success.
    def render_result(content:, theme:)
      text = content.to_s
      return nil unless text.start_with?('Error:')

      theme.error("✗ #{text.lines.first.to_s.strip}")
    end

    # Build the {DiffRenderer::Palette} from the theme's four diff tokens,
    # read at render time so OS light/dark flips restyle the diff.
    #
    # @param theme [Tuile::Theme]
    # @return [DiffRenderer::Palette]
    def palette(theme)
      DiffRenderer::Palette.new(
        line_add: theme[:diff_line_add],
        line_del: theme[:diff_line_del],
        span_add: theme[:diff_span_add],
        span_del: theme[:diff_span_del]
      )
    end
  end
end
