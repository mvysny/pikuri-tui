# frozen_string_literal: true

require 'tuile'

# API-compatible passthrough variant of {Shared::Markdown::StreamingBuffer}: same
# +#append+ / +#finalize+ / +#finalized?+ / +#source+ surface, same
# one-region-per-turn lifecycle, but no Markdown rendering and no
# block-cutter. {#append} forwards the chunk straight to
# +Region#append+ (which splits on embedded +\n+ for hard lines);
# {#finalize} assigns the authoritative content to +Region#text+.
#
# Use this where the streamed content is already in its final display
# form (plain text, pre-formatted output, ANSI from elsewhere) and the
# {Shared::Markdown::Renderer} trip through {Shared::Markdown::StreamingBuffer} would either
# corrupt the text or add unwanted styling.
#
# == Lifecycle and threading
#
# Identical to {Shared::Markdown::StreamingBuffer}: one buffer per turn, drive
# {#append} until done, then {#finalize} exactly once. Not thread-safe;
# the region's mutators check +Tuile::Screen#check_locked+, so the
# buffer must be driven from whichever thread holds the UI lock.
class Shared::Markdown::PassthroughBuffer
  # @param region [Tuile::Component::TextView::Region] the region to
  #   write into. The buffer assumes exclusive ownership for its
  #   lifetime — only the buffer should mutate the region between
  #   construction and {#finalize}.
  def initialize(region:)
    @region = region
    @source = +''
    @finalized = false
  end

  # Feeds one streamed chunk. Concatenates onto the accumulated source
  # and forwards verbatim to the region. Empty / +nil+ content is a
  # no-op.
  #
  # @param content [String, nil] the chunk to append.
  # @return [void]
  # @raise [RuntimeError] if called after {#finalize}.
  def append(content)
    raise 'Shared::Markdown::PassthroughBuffer#append called after #finalize' if @finalized
    return if content.nil? || content.empty?

    @source << content
    @region.append(content)
  end

  # Replaces the accumulated source with +authoritative+ and writes
  # it to the region. Fast path: if +authoritative+ equals {#source},
  # just mark the buffer finalized — the region already shows the
  # right thing.
  #
  # @param authoritative [String] the final content for this turn.
  # @return [void]
  # @raise [RuntimeError] if called more than once.
  def finalize(authoritative)
    raise 'Shared::Markdown::PassthroughBuffer#finalize called twice' if @finalized

    if authoritative == @source
      @finalized = true
      return
    end

    @source = authoritative.to_s.dup
    @region.text = @source
    @finalized = true
  end

  # @return [Boolean] +true+ after {#finalize} has run.
  def finalized? = @finalized

  # @return [String] the accumulated source. Same semantics as
  #   {Shared::Markdown::StreamingBuffer#source} — exposed so the owner can call
  #   +finalize(source)+ on a cancellation path to commit the preview
  #   as-is.
  def source
    @source.dup
  end
end
