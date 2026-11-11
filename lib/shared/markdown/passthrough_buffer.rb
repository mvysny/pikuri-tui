# frozen_string_literal: true

require 'tuile'

# API-compatible passthrough variant of {Shared::Markdown::StreamingBuffer}: same
# +#append+ / +#finalize+ / +#finalized?+ / +#source+ surface, same
# one-region-per-turn lifecycle, but no Markdown: each chunk goes straight to
# +Region#append+ (embedded +\n+ become hard lines).
#
#   buf = Shared::Markdown::PassthroughBuffer.new(region: region, style: ->(text) { Grayscale.recolor(text) })
#   buf.append('**stays** ')       # shown verbatim, recolored
#   buf.finalize(authoritative)
#
# Use it where the stream is already in its display form — plain text, the
# +markdown: false+ mode — and a Markdown render would corrupt it.
#
# UI-thread-confined (the region's mutators call +Tuile::Screen#check_locked+).
class Shared::Markdown::PassthroughBuffer
  # @param region [Tuile::Component::TextView::Region] the region to write
  #   into; nothing else may write it until {#finalize}.
  # @param indent [Integer] leading spaces on the region's first line.
  # @param style [#call, nil] +String -> String+ applied to every chunk, e.g. a
  #   recolor; it must style a chunk and the whole text alike.
  def initialize(region:, indent: 0, style: nil)
    @region = region
    @pad = ' ' * indent
    @style = style || ->(text) { text }
    @source = +''
    @finalized = false
  end

  # Feeds one streamed chunk. Empty / +nil+ content is a no-op.
  #
  # @param content [String, nil] the chunk to append.
  # @return [void]
  # @raise [RuntimeError] if called after {#finalize}.
  def append(content)
    raise 'Shared::Markdown::PassthroughBuffer#append called after #finalize' if @finalized
    return if content.nil? || content.empty?

    @region.append(@style.call(@source.empty? ? @pad + content : content))
    @source << content
  end

  # Replaces the accumulated source with +authoritative+ and writes it to the
  # region, unless it equals {#source} and the region already shows it.
  #
  # @param authoritative [String] the final content for this turn.
  # @return [void]
  # @raise [RuntimeError] if called more than once.
  def finalize(authoritative)
    raise 'Shared::Markdown::PassthroughBuffer#finalize called twice' if @finalized

    @finalized = true
    return if authoritative == @source

    @source = authoritative.to_s.dup
    @region.text = @source.empty? ? @source : @style.call(@pad + @source)
  end

  # @return [Boolean] +true+ after {#finalize} has run.
  def finalized? = @finalized

  # @return [String] the accumulated source — what the owner passes to
  #   {#finalize} to keep the preview as-is.
  def source
    @source.dup
  end
end
