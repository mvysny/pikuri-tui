# frozen_string_literal: true

require 'pikuri-core'
require 'tuile'

module PikuriTui
  module Code
    # Tool formatter for the +edit+ tool: renders its +ToolCall+ as the
    # before/after diff of +old_string+ → +new_string+ instead of the
    # default +→ edit(path=…, old_string=…, new_string=…)+ argument dump.
    #
    # The diff is self-contained — the +ToolCall+ event already carries both
    # strings, so no file read is needed (the seam stays clean and nothing
    # blocks the UI thread on IO). Installed in {TuileListener}'s
    # +tool_formatters+ map by +bin/pikuri-tui-code+; the listener calls
    # {#render_call} on the +ToolCall+ and {#render_result} on the paired
    # +ToolResult+.
    class EditFormatter
      # Render the diff block for an +edit+ call.
      #
      # @param arguments [Hash] the tool-call arguments
      #   (+path+ / +old_string+ / +new_string+; keys may be String or Symbol).
      # @param width [Integer] the conversation pane's render width.
      # @param theme [Tuile::Theme] the active theme.
      # @return [String, nil] the rendered diff block, or +nil+ to fall back
      #   to the listener's default tool-call line (on a rendering failure —
      #   pikuri-tui catches library exceptions and degrades, per CLAUDE.md).
      def render_call(arguments:, width:, theme:)
        args = arguments.transform_keys(&:to_s)
        DiffToolFormatting.render_call(
          verb: 'edit',
          path: args['path'],
          old: args['old_string'].to_s,
          new: args['new_string'].to_s,
          width: width,
          theme: theme
        )
      rescue StandardError => e
        Tuile.logger.warn("EditFormatter.render_call failed (#{e.class}: #{e.message}); falling back to default")
        nil
      end

      # @param content [String] the +edit+ tool observation.
      # @param theme [Tuile::Theme] the active theme.
      # @return [String, nil] error line, or +nil+ to suppress on success.
      def render_result(content:, theme:)
        DiffToolFormatting.render_result(content: content, theme: theme)
      end
    end
  end
end
