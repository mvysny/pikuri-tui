# frozen_string_literal: true

require 'pikuri-core'
require 'tuile'

module Code
  # Tool formatter for the +write+ tool: renders its +ToolCall+ as the diff
  # of the file's current contents against the +content+ being written,
  # instead of the default +→ write(path=…, content=…)+ dump.
  #
  # Unlike {EditFormatter}, the +ToolCall+ event carries only the new
  # +content+, so the "before" side is read from disk through the captured
  # +filesystem+. A missing file renders as an all-added "create"; an
  # unreadable / out-of-workspace / binary path falls back to the
  # listener's default line (a +nil+ return). The read happens
  # synchronously on the UI thread (the listener marshals the whole
  # dispatch there) — acceptable for the file sizes the model writes;
  # revisit if a large file ever stutters the paint.
  class WriteFormatter
    LOG = Pikuri.logger_for('formatter')
    private_constant :LOG

    # @param filesystem [Pikuri::Workspace::Filesystem] resolves the path
    #   and bounds the read to the workspace (same handle the +Write+ tool
    #   uses).
    def initialize(filesystem:)
      @filesystem = filesystem
    end

    # Render the diff block for a +write+ call.
    #
    # @param arguments [Hash] the tool-call arguments (+path+ / +content+;
    #   keys may be String or Symbol).
    # @param width [Integer] the conversation pane's render width.
    # @param theme [Tuile::Theme] the active theme.
    # @return [String, nil] the rendered diff block, or +nil+ to fall back
    #   to the default tool-call line (file unreadable, outside the
    #   workspace, binary, or a rendering failure).
    def render_call(arguments:, width:, theme:)
      args = arguments.transform_keys(&:to_s)
      path = args['path']
      old = read_existing(path)
      return nil if old.nil?

      DiffToolFormatting.render_call(
        verb: old.empty? ? 'create' : 'write',
        path: path,
        old: old,
        new: args['content'].to_s,
        width: width,
        theme: theme
      )
    rescue StandardError => e
      LOG.warn("WriteFormatter.render_call failed (#{e.class}: #{e.message}); falling back to default")
      nil
    end

    # @param content [String] the +write+ tool observation.
    # @param theme [Tuile::Theme] the active theme.
    # @return [String, nil] error line, or +nil+ to suppress on success.
    def render_result(content:, theme:)
      DiffToolFormatting.render_result(content: content, theme: theme)
    end

    private

    # Read the existing file as UTF-8 text for the diff's "before" side.
    # Returns +""+ for a not-yet-existing file (an all-added create) and
    # +nil+ when there's nothing sensible to diff against — the path is
    # outside the workspace, unreadable, or binary — so the caller can fall
    # back to the default tool-call line.
    #
    # @param path [String] raw path from the tool call.
    # @return [String, nil]
    def read_existing(path)
      resolved = @filesystem.resolve_for_write(path)
      return '' unless resolved.exist?
      return nil if resolved.directory?

      bytes = resolved.binread.dup.force_encoding('UTF-8')
      bytes.valid_encoding? ? bytes : nil
    end
  end
end
