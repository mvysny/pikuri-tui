# frozen_string_literal: true

require 'pikuri-core'
require 'tuile'

module Code
  # Tool formatter for the +edit+ tool: renders its +ToolCall+ as the
  # before/after diff of +old_string+ → +new_string+ instead of the
  # default +Edit(path)+ / summary pair.
  #
  # The diff is self-contained — the +ToolCall+ event already carries both
  # strings, so no file read is needed (nothing blocks the UI thread on
  # IO). Implements the {Shared::ConversationTextView} +tool_formatters+
  # protocol: {#render_call} on the +ToolCall+, {#render_result} on the
  # paired +ToolResult+.
  class EditFormatter
    # @return [Logger]
    LOG = Pikuri.logger_for('formatter')
    private_constant :LOG

    # Render the diff block for an +edit+ call.
    #
    # @param arguments [Hash] the tool-call arguments
    #   (+path+ / +old_string+ / +new_string+; keys may be String or Symbol).
    # @param width [Integer] the conversation pane's render width.
    # @param theme [Tuile::Theme] the active theme.
    # @return [String, nil] the rendered diff block, or +nil+ to fall back
    #   to the listener's default tool-call line (on a rendering failure —
    #   pikuri-tui catches library exceptions and degrades, +D_tui_degrades_not_crashes+).
    def render_call(arguments:, width:, theme:)
      args = arguments.transform_keys(&:to_s)
      DiffToolFormatting.render_call(
        verb: 'Edit',
        path: args['path'],
        old: args['old_string'].to_s,
        new: args['new_string'].to_s,
        width: width,
        theme: theme
      )
    rescue StandardError => e
      LOG.warn("EditFormatter.render_call failed (#{e.class}: #{e.message}); falling back to default")
      nil
    end

    # @param summary [String] the +edit+ tool's own one-line status.
    # @param theme [Tuile::Theme] the active theme.
    # @return [String, nil] error line, or +nil+ to suppress on success.
    def render_result(summary:, theme:)
      DiffToolFormatting.render_result(summary: summary, theme: theme)
    end
  end
end
