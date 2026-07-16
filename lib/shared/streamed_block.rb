# frozen_string_literal: true

# A single open streamed block: a {Tuile::Component::TextView::Region} plus the
# streaming buffer writing into it, opened lazily on the first {#append} and then
# closed one of three ways - {#finalize} (commit the authoritative text),
# {#wipe} (drop the region and its content), or {#preserve} (drop the handle,
# keep the content on screen). The assistant answer and the reasoning pane are
# each one of these; they differ only in which buffer builder opens them, which
# is exactly what the +open+ factory captures.
#
#   block = Shared::StreamedBlock.new do
#     region = view.create_region
#     [region, view.build_assistant_buffer(region, indent: 0)]
#   end
#   block.append(delta)     # opens the region + buffer on the first call
#   block.finalize(full)    # commit the final text, then close
#   # …or, on an event that interrupts the stream:
#   block.wipe              # a ToolCall arrived mid-answer -> remove the preview
#   block.preserve          # a cancel -> keep what streamed, drop the handle
#
# After any close ({#finalize} / {#wipe} / {#preserve}) the block is reusable: the
# next {#append} opens a fresh region + buffer. {#wipe} / {#preserve} / {#finalize}
# are no-ops while closed, so a caller can fire them unconditionally on an
# interrupting event without first checking {#open?}.
#
# UI-thread-confined: every region / buffer mutation it makes must run on the UI
# thread (the caller marshals the driving event stream there).
class Shared::StreamedBlock
  # @yieldreturn [Array(Tuile::Component::TextView::Region, #append)] a fresh
  #   +[region, buffer]+ pair; called once, on the first {#append}, to open the
  #   block lazily. The buffer must respond to +#append+ / +#finalize+.
  def initialize(&open)
    @open = open
    @region = nil
    @buffer = nil
  end

  # @return [Boolean] whether the block is currently open (holds an unfinalized
  #   buffer).
  def open? = !@buffer.nil?

  # Append a streamed delta, opening the region + buffer on the first call.
  #
  # @param content [String] the delta text.
  # @return [void]
  def append(content)
    @region, @buffer = @open.call unless @buffer
    @buffer.append(content)
  end

  # Commit the authoritative full text (which may replace a truncated preview)
  # and close. A no-op when not open.
  #
  # @param content [String] the final text.
  # @return [void]
  def finalize(content)
    return unless @buffer

    @buffer.finalize(content)
    close
  end

  # Remove the region and its rendered content, then close - for an event that
  # interrupts an unfinished stream (e.g. a tool call mid-answer). A no-op when
  # not open.
  #
  # @return [void]
  def wipe
    return unless @buffer

    @region.remove
    close
  end

  # Drop the region / buffer handles but leave the rendered content on screen -
  # for a stream that should stay (a cancel, or handing off to a non-streamed
  # bookend). A no-op when not open.
  #
  # @return [void]
  def preserve = close

  private

  # @return [void]
  def close
    @region = nil
    @buffer = nil
  end
end
