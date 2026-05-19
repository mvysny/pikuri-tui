# frozen_string_literal: true

require 'tty-markdown'
require 'tuile'

module PikuriTui
  # Stateful buffer that turns a stream of Markdown deltas into hard-line
  # edits against a +Tuile::Component::TextView+. The buffer itself is
  # UI-unaware — it accepts source chunks, re-renders the accumulated
  # source to ANSI via +TTY::Markdown+, diffs the rendered output at
  # hard-line granularity against its previous emission, and calls a
  # caller-supplied sink with the diff as +(remove_last_n, lines_to_add)+.
  # The sink is what knows about +TextView+ and the Tuile UI thread.
  #
  # == Why re-render-and-diff
  #
  # Markdown rendering isn't streamable in any usable Ruby library:
  # +TTY::Markdown+ batches over +kramdown+, +CommonMarker+ batches over
  # +cmark+. Worse, Markdown is retroactively reformattable — a closing
  # +```+ turns earlier text into a code block; a new table row with a
  # wider cell re-pads every previous row. So the cheapest correct
  # primitive is: on each token, render the *whole* accumulated source,
  # split the rendered ANSI on +\n+, compare against the previous render,
  # and emit just the trailing damage. +TextView+'s
  # +#remove_last_n_lines+ + +#append+ pair applies the diff in place.
  #
  # == Lifecycle
  #
  # One buffer per assistant turn. The owner calls {#append} for each
  # +Pikuri::Agent::Event::AssistantDelta+ payload, then {#finalize}
  # exactly once with the +Pikuri::Agent::Event::Assistant+ payload.
  # +AssistantDelta+ is documented as preview-only — pikuri makes no
  # guarantee that +deltas.join == Assistant#content+ (providers
  # normalize whitespace; Anthropic strips thinking signatures) — so
  # {#finalize} replaces the accumulated source with the authoritative
  # content and runs one final diff against the preview, leaving the
  # visible region exactly matching the authoritative render. After
  # finalize the buffer is dead: further calls raise.
  #
  # == Threading
  #
  # Not thread-safe. Designed to be driven from a single thread (in
  # practice, pikuri's agent worker via the +Pikuri::Agent::Listener+
  # dispatch). The Markdown render and diff run on whatever thread
  # calls {#append} / {#finalize}; only the sink callback needs to
  # marshal back to the Tuile UI thread (it does this with
  # +screen.event_queue.submit+ in the listener's wiring).
  #
  # == Performance note
  #
  # v1 re-renders the entire accumulated source on every token. For
  # typical assistant replies at local-llama.cpp token rates (~20fps)
  # this is fine. TODO: when a long message starts costing real CPU,
  # the natural next step is either a per-token debouncer (coalesce
  # bursts to ~30fps) or a block-cutter (track closed source-level
  # block boundaries and only re-render the open tail block). Both
  # fit behind this same public API.
  class StreamingMarkdownBuffer
    # @param width [Integer] render width passed to +TTY::Markdown.parse+.
    #   Should be the +TextView+'s wrap-width at the moment the buffer
    #   is created. The buffer ignores resizes during streaming — the
    #   next message renders at the new width and looks right; the
    #   in-flight message may look slightly off if resized mid-stream.
    # @yield [remove_last_n, lines_to_add] called with each diff.
    # @yieldparam remove_last_n [Integer] number of hard lines to drop
    #   from the +TextView+'s tail (0 on the first emission and any
    #   time the previous render was a clean prefix of the new one).
    # @yieldparam lines_to_add [Array<String>] hard lines to append
    #   after the removal (may contain embedded ANSI; may be empty
    #   when the new render is a strict prefix of the previous one).
    # @raise [ArgumentError] if no block is given.
    def initialize(width:, &sink)
      raise ArgumentError, 'block sink required' unless sink

      @width = width
      @sink = sink
      @source = +''
      @rendered_lines = []
      @finalized = false
    end

    # Feeds one streamed Markdown chunk. Concatenates onto the
    # accumulated source, re-renders to ANSI, diffs against the previous
    # render, and emits the diff to the sink. Empty / +nil+ content is a
    # no-op (no source mutation, no emission).
    #
    # @param content [String, nil] the +AssistantDelta#content+ payload.
    # @return [void]
    # @raise [RuntimeError] if called after {#finalize}.
    def append(content)
      raise 'StreamingMarkdownBuffer#append called after #finalize' if @finalized
      return if content.nil? || content.empty?

      @source << content
      rerender_and_emit
    end

    # Replaces the accumulated source with the authoritative content and
    # runs one final diff against the preview. After this call the
    # buffer is finalized — further {#append} or {#finalize} calls raise.
    # Designed to be called once per assistant turn with the
    # +Pikuri::Agent::Event::Assistant#content+ payload (the
    # authoritative final Markdown, which may differ from
    # +deltas.join+).
    #
    # @param authoritative [String] the final Markdown for this turn.
    # @return [void]
    # @raise [RuntimeError] if called more than once.
    def finalize(authoritative)
      raise 'StreamingMarkdownBuffer#finalize called twice' if @finalized

      @source = authoritative.to_s.dup
      rerender_and_emit
      @finalized = true
    end

    # @return [Boolean] +true+ after {#finalize} has run.
    def finalized? = @finalized

    # @return [String] the accumulated Markdown source. Exposed so the
    #   owner can call +finalize(source)+ on a cancellation path to
    #   commit the preview as-is (no authoritative replacement, but no
    #   loss of streamed work either).
    attr_reader :source

    private

    # Render the current +@source+, compute the line-level diff against
    # +@rendered_lines+, and emit it. Updates +@rendered_lines+ on a
    # successful render. A render failure (+TTY::Markdown+ choking on
    # an in-flight token, e.g. an unclosed inline) is caught and
    # logged through {Tuile.logger}; +@source+ stays current so the
    # next token gets another chance, but +@rendered_lines+ is
    # untouched so the next successful render diffs against the last
    # *good* state.
    # @return [void]
    def rerender_and_emit
      new_lines = render_lines(@source)
      return if new_lines.nil?

      prefix = common_prefix_length(@rendered_lines, new_lines)
      damage = @rendered_lines.size - prefix
      tail = new_lines[prefix..] || []

      @sink.call(damage, tail) if damage.positive? || tail.any?
      @rendered_lines = new_lines
    end

    # @param source [String]
    # @return [Array<String>, nil] hard lines of the rendered output, or
    #   +nil+ on render failure (logged, not raised).
    def render_lines(source)
      rendered = TTY::Markdown.parse(source, width: @width)
      rendered.split("\n")
    rescue StandardError => e
      Tuile.logger.warn(
        "StreamingMarkdownBuffer: TTY::Markdown render failed " \
        "(#{e.class}: #{e.message}); keeping previous rendered state"
      )
      nil
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
