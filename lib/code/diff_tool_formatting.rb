# frozen_string_literal: true

require 'pikuri-core'
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
  #
  # Every string leaving here for the pane is {defang}ed first. The path, the
  # payload and the error summary are all model-authored, and {DiffRenderer}
  # emits its span text verbatim — so one raw ESC in a written line recolors
  # the transcript from that cell on.
  module DiffToolFormatting
    module_function

    # Glyph prefixing the diff header, marking the line as a file mutation.
    # @return [String]
    GLYPH = '✎'

    # Render the call-time diff block: a themed header line
    # (+"✎ Edit(lib/foo.rb)"+) over the {DiffRenderer} diff of +old+ → +new+.
    # The header keeps the +Verb(argument)+ shape every other tool call has, so
    # a diff reads as one of the family rather than a second convention.
    #
    # @param verb [String] the action shown in the header (+"Edit"+,
    #   +"Write"+, +"Create"+).
    # @param path [String] the file path shown in the header.
    # @param old [String] the "before" content.
    # @param new [String] the "after" content.
    # @param width [Integer] target render width (the conversation pane's).
    # @param theme [Tuile::Theme] the active theme; supplies the header
    #   color and the four diff background tones.
    # @return [String] header + ANSI diff body.
    def render_call(verb:, path:, old:, new:, width:, theme:)
      header = theme.tool("#{GLYPH} #{verb}(#{defang_line(path)})")
      body = DiffRenderer.render(defang(old), defang(new), width: width, palette: palette(theme))
      "#{header}\n#{body}"
    end

    # Render the result-time line for a paired edit / write +ToolResult+.
    # Success is silent — the diff already told the story; a failure surfaces
    # as a themed error line so a failed attempt (rare) doesn't read as if it
    # applied.
    #
    # @param summary [String] the tool's own one-line status; +"Error: ..."+
    #   for a failure, which pikuri prefixes in +Tool::Result.error+.
    # @param theme [Tuile::Theme] the active theme.
    # @return [String, nil] the error line, or +nil+ to suppress on success.
    def render_result(summary:, theme:)
      text = summary.to_s
      return nil unless text.start_with?('Error:')

      theme.error("✗ #{defang_line(text)}")
    end

    # Make a model-authored string printable, for the diff body:
    #
    #   defang("rm -rf \e[2Kbuild")   # => 'rm -rf \x1b[2Kbuild'
    #
    # Newlines and indentation survive, so a diff stays a diff.
    #
    # @param text [String] file content, or a +write+'s payload.
    # @return [String] with control / bidi / zero-width bytes made visible.
    def defang(text) = Pikuri::Sanitizer.sanitize(text.to_s).text

    # {defang} for a string that has to fit one row — a path, an error summary
    # — so an embedded newline can't forge a second line.
    #
    # @param text [String]
    # @return [String] one line, whitespace runs collapsed.
    def defang_line(text) = Pikuri::Tool.one_line(defang(text))

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
