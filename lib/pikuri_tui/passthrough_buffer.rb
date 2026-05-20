# frozen_string_literal: true

require 'tuile'

module PikuriTui
  # API-compatible passthrough variant of {StreamingMarkdownBuffer}: same
  # +#append+ / +#finalize+ / +#finalized?+ / +#source+ surface and the
  # same +(remove_last_n, lines_to_add)+ sink contract, but no Markdown
  # rendering and no block-cutter. The accumulated source is split on
  # +\n+ and emitted to the sink directly — what comes in goes out.
  #
  # Use this where the streamed content is already in its final display
  # form (plain text, pre-formatted output, ANSI from elsewhere) and the
  # +TTY::Markdown+ trip through {StreamingMarkdownBuffer} would either
  # corrupt the text or add unwanted styling. The diff plumbing — count
  # the common prefix against the last emission, emit the trailing
  # damage — is unchanged, so a sink wired up for {StreamingMarkdownBuffer}
  # works as-is.
  #
  # No +render:+ keyword: there's no renderer to inject. There is no
  # block-commit logic either; the diff machinery alone naturally avoids
  # re-emitting an unchanged prefix because the source-as-lines *is* the
  # rendered form.
  #
  # == Lifecycle and threading
  #
  # Identical to {StreamingMarkdownBuffer}: one buffer per turn, drive
  # {#append} until done, then {#finalize} exactly once. Not thread-safe;
  # the sink is what marshals UI mutations back to the Tuile thread.
  class PassthroughBuffer
    # @yield [remove_last_n, lines_to_add] called with each diff.
    # @yieldparam remove_last_n [Integer] number of hard lines to drop
    #   from the +TextView+'s tail.
    # @yieldparam lines_to_add [Array<String>] hard lines to append
    #   after the removal.
    # @raise [ArgumentError] if no block is given.
    def initialize(&sink)
      raise ArgumentError, 'block sink required' unless sink

      @sink = sink
      @source = +''
      @emitted_lines = []
      @finalized = false
    end

    # Feeds one streamed chunk. Concatenates onto the accumulated source,
    # splits the whole source on +\n+, diffs against the previous
    # emission, and emits the trailing damage. Empty / +nil+ content is
    # a no-op.
    #
    # @param content [String, nil] the chunk to append.
    # @return [void]
    # @raise [RuntimeError] if called after {#finalize}.
    def append(content)
      raise 'PassthroughBuffer#append called after #finalize' if @finalized
      return if content.nil? || content.empty?

      @source << content
      emit_diff
    end

    # Replaces the accumulated source with +authoritative+ and runs one
    # final diff. Fast path: if +authoritative+ equals {#source}, just
    # mark the buffer finalized — the sink has already seen everything.
    #
    # @param authoritative [String] the final content for this turn.
    # @return [void]
    # @raise [RuntimeError] if called more than once.
    def finalize(authoritative)
      raise 'PassthroughBuffer#finalize called twice' if @finalized

      if authoritative == @source
        @finalized = true
        return
      end

      @source = authoritative.to_s.dup
      emit_diff
      @finalized = true
    end

    # @return [Boolean] +true+ after {#finalize} has run.
    def finalized? = @finalized

    # @return [String] the accumulated source. Same semantics as
    #   {StreamingMarkdownBuffer#source} — exposed so the owner can call
    #   +finalize(source)+ on a cancellation path to commit the preview
    #   as-is.
    def source
      @source.dup
    end

    private

    # Split the source into hard lines, find the common prefix against
    # the previous emission, and emit the trailing damage. No-op when
    # the new line array is identical to the previous one.
    # @return [void]
    def emit_diff
      new_lines = @source.split("\n")

      prefix = common_prefix_length(@emitted_lines, new_lines)
      damage = @emitted_lines.size - prefix
      tail = new_lines[prefix..] || []

      @sink.call(damage, tail) if damage.positive? || tail.any?
      @emitted_lines = new_lines
    end

    # @param a [Array<String>]
    # @param b [Array<String>]
    # @return [Integer] length of the longest common prefix of +a+ and +b+.
    def common_prefix_length(a, b)
      limit = [a.size, b.size].min
      i = 0
      i += 1 while i < limit && a[i] == b[i]
      i
    end
  end
end
