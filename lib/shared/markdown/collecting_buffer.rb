# frozen_string_literal: true

# Accumulate-only variant of {Shared::Markdown::StreamingBuffer}: the same
# +#append+ / +#finalize+ / +#finalized?+ / +#source+ surface and the same
# one-buffer-per-turn lifecycle, but it owns no region and renders nothing —
# the source just piles up for whoever renders it later.
#
#   buffer = Shared::Markdown::CollectingBuffer.new
#   buffer.append('## Hel')
#   buffer.append("lo\n")          # nothing is drawn, nothing is rendered
#   buffer.finalize(authoritative)
#   buffer.source                  # => the Markdown, for a render on demand
#
# Use it for a block whose place in the transcript is claimed but whose content
# is deliberately not drawn yet — a hidden reasoning block, which keeps its
# region and renders only if the reader reveals it. Rendering each delta into a
# region nobody can see is the alternative it exists to avoid.
#
# Touching no region, it is the one buffer in the family that is *not*
# UI-thread-confined.
class Shared::Markdown::CollectingBuffer
  def initialize
    @source = +''
    @finalized = false
  end

  # Feeds one streamed chunk onto the accumulated source. Empty / +nil+ content
  # is a no-op.
  #
  # @param content [String, nil] the chunk to collect.
  # @return [void]
  # @raise [RuntimeError] if called after {#finalize}.
  def append(content)
    raise 'Shared::Markdown::CollectingBuffer#append called after #finalize' if @finalized
    return if content.nil? || content.empty?

    @source << content
  end

  # Replaces the accumulated source with +authoritative+ — the final content,
  # which may differ from +deltas.join+ — and closes the buffer.
  #
  # @param authoritative [String] the final content for this turn.
  # @return [void]
  # @raise [RuntimeError] if called more than once.
  def finalize(authoritative)
    raise 'Shared::Markdown::CollectingBuffer#finalize called twice' if @finalized

    @source = authoritative.to_s.dup
    @finalized = true
  end

  # @return [Boolean] +true+ after {#finalize} has run.
  def finalized? = @finalized

  # @return [String] the collected source. Same semantics as
  #   {Shared::Markdown::StreamingBuffer#source}.
  def source
    @source.dup
  end
end
