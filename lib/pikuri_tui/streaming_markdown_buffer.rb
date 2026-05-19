# frozen_string_literal: true

require 'tuile'

module PikuriTui
  # Stateful buffer that turns a stream of Markdown deltas into hard-line
  # edits against a +Tuile::Component::TextView+. The buffer itself is
  # UI-unaware — it accepts source chunks, hands the currently *open*
  # Markdown block to a caller-supplied render function, diffs the
  # rendered ANSI at hard-line granularity against its previous
  # emission, and calls a caller-supplied sink with the diff as
  # +(remove_last_n, lines_to_add)+. The sink is what knows about
  # +TextView+ and the Tuile UI thread; the render function is what
  # knows about +TTY::Markdown+ (or whatever swap-in renderer the caller
  # wired up — see {MarkdownRenderer}).
  #
  # == Why re-render-and-diff
  #
  # Markdown rendering isn't streamable in any usable Ruby library:
  # +TTY::Markdown+ batches over +kramdown+, +CommonMarker+ batches over
  # +cmark+. Worse, Markdown is retroactively reformattable — a closing
  # +```+ turns earlier text into a code block; a new table row with a
  # wider cell re-pads every previous row. So the cheapest correct
  # primitive is: on each token, render the source, split the rendered
  # ANSI on +\n+, compare against the previous render, and emit just
  # the trailing damage. +TextView+'s +#remove_last_n_lines+ + +#add_line+
  # pair applies the diff in place.
  #
  # == Block-cutter: bound per-token work to one block
  #
  # Rendering the *whole* accumulated source on every token is O(N²) in
  # message length and starts costing real CPU at a few KB. Mitigation:
  # split the source into a *committed* prefix and an *open* suffix.
  # A block is "committed" once we know nothing later in the stream can
  # retroactively reformat it. We commit at two clean source-level
  # boundaries: a blank line outside a fenced code block (ends a
  # paragraph / list / blockquote / table), and a closing +```+ /
  # +~~~+ (ends a fenced code block). Committed source is rendered
  # *once*, its rendered lines stashed in +@committed_lines+, and
  # never revisited. Per-token work shrinks from O(message-so-far) to
  # O(current-open-block).
  #
  # The cases this doesn't optimize — by design, because they're
  # actually retroactive:
  #
  # - *Tables* during streaming: a new wider row re-pads earlier rows.
  #   The whole table stays in +@open_source+ until a blank line ends
  #   it; per-token cost is O(table-so-far). LLM tables are small;
  #   acceptable.
  # - *Setext headings* (+\=\=\=+ / +---+ under a paragraph): we don't
  #   defer committing paragraphs to wait and see, so a paragraph that
  #   turns out to be a setext heading renders as paragraph + literal
  #   underline row. LLMs use ATX headings (+# foo+); not seen in
  #   practice.
  # - *Reference-link definitions* (+[label]: url+) and footnotes:
  #   forward references that affect earlier text. Same story — LLMs
  #   don't emit them.
  #
  # If any of these matter later, the surface to optimize is
  # +process_for_commits+ — the buffer's public API stays the same.
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
  # As a fast path, {#finalize} called with the buffer's own
  # +#source+ (the cancel-preserve case) skips the re-render entirely
  # — the TextView already matches.
  #
  # == Threading
  #
  # Not thread-safe. Designed to be driven from a single thread (in
  # practice, pikuri's agent worker via the +Pikuri::Agent::Listener+
  # dispatch). The Markdown render and diff run on whatever thread
  # calls {#append} / {#finalize}; only the sink callback needs to
  # marshal back to the Tuile UI thread (it does this with
  # +screen.event_queue.submit+ in the listener's wiring).
  class StreamingMarkdownBuffer
    # Probe marker appended after the committed source at commit time so
    # we can ask the renderer "what does committed render to, given
    # that *something* follows?" — the lines before the marker in the
    # probe output are the natural rendered form of the committed source
    # right up to the boundary with whatever block comes next. Using
    # the renderer's own answer avoids hand-coding "does this block
    # type leave a blank trailing line before that one?" rules (tty-
    # markdown notably *doesn't* put a blank between a fenced code
    # block and a following paragraph; trying to reproduce those
    # quirks by hand is a losing game).
    #
    # The marker is a single Private-Use-Area Unicode codepoint
    # (+U+E000+). Unicode reserves the PUA for application-specific
    # use, so no spec assigns it a meaning, no LLM trained on natural
    # text emits it, and Markdown has nothing to do with it (an
    # earlier ASCII +_PKBND_+ marker got stripped to +PKBND+ because
    # tty-markdown treated the surrounding underscores as italics —
    # a U+E000 has no such risk). It passes through any sane Markdown
    # renderer unchanged.
    COMMIT_PROBE_SENTINEL = ""
    private_constant :COMMIT_PROBE_SENTINEL

    # @param render [#call] callable that takes a Markdown +String+ and
    #   returns rendered ANSI +String+. The buffer treats it as an
    #   opaque function — it must be deterministic for a given input
    #   and must preserve {COMMIT_PROBE_SENTINEL} through to the output
    #   unchanged. Callers typically bake render width into the lambda
    #   at construction time (see {MarkdownRenderer}); the buffer
    #   ignores resizes during streaming, so the next message renders
    #   at the new width and looks right while an in-flight message may
    #   look slightly off if resized mid-stream.
    # @yield [remove_last_n, lines_to_add] called with each diff.
    # @yieldparam remove_last_n [Integer] number of hard lines to drop
    #   from the +TextView+'s tail (0 on the first emission and any
    #   time the previous render was a clean prefix of the new one).
    # @yieldparam lines_to_add [Array<String>] hard lines to append
    #   after the removal (may contain embedded ANSI; may be empty
    #   when the new render is a strict prefix of the previous one).
    # @raise [ArgumentError] if no block is given.
    def initialize(render:, &sink)
      raise ArgumentError, 'block sink required' unless sink

      @render = render
      @sink = sink
      @committed_source = +''
      @committed_lines = []
      @open_source = +''
      @rendered_lines = []
      @scan_position = 0
      @fence_state = :normal
      @finalized = false
    end

    # Feeds one streamed Markdown chunk. Concatenates onto the
    # accumulated source, advances any newly-closed block boundaries
    # into +@committed_lines+, re-renders the open block, diffs against
    # the previous full render, and emits the diff to the sink. Empty
    # / +nil+ content is a no-op (no source mutation, no emission).
    #
    # @param content [String, nil] the +AssistantDelta#content+ payload.
    # @return [void]
    # @raise [RuntimeError] if called after {#finalize}.
    def append(content)
      raise 'StreamingMarkdownBuffer#append called after #finalize' if @finalized
      return if content.nil? || content.empty?

      process_for_commits(content)
      rerender_and_emit
    end

    # Replaces the accumulated source with the authoritative content
    # and runs one final diff. Designed to be called once per
    # assistant turn with the +Pikuri::Agent::Event::Assistant#content+
    # payload (the authoritative final Markdown, which may differ from
    # +deltas.join+). After this call the buffer is finalized — further
    # {#append} or {#finalize} calls raise.
    #
    # Fast path: if +authoritative+ equals the buffer's current
    # +#source+ (the cancel-preserve case — the host wants to commit
    # the preview as-is), the buffer just marks itself finalized and
    # returns without re-rendering. The TextView already shows the
    # right thing.
    #
    # @param authoritative [String] the final Markdown for this turn.
    # @return [void]
    # @raise [RuntimeError] if called more than once.
    def finalize(authoritative)
      raise 'StreamingMarkdownBuffer#finalize called twice' if @finalized

      if authoritative == source
        @finalized = true
        return
      end

      @committed_source = +''
      @committed_lines = []
      @open_source = authoritative.to_s.dup
      @scan_position = 0
      @fence_state = :normal
      rerender_and_emit
      @finalized = true
    end

    # @return [Boolean] +true+ after {#finalize} has run.
    def finalized? = @finalized

    # @return [String] the accumulated Markdown source. Exposed so the
    #   owner can call +finalize(source)+ on a cancellation path to
    #   commit the preview as-is (no authoritative replacement, but no
    #   loss of streamed work either).
    def source
      @committed_source + @open_source
    end

    private

    # Walk the new content one complete line at a time, tracking fence
    # state and recording the *latest* commit point — the byte
    # position in +@open_source+ at which everything before is safely
    # closed. If we found one, commit up to it. Partial trailing lines
    # are left unscanned so we resume from there on the next append.
    # @param content [String]
    # @return [void]
    def process_for_commits(content)
      @open_source << content

      i = @scan_position
      last_commit = nil

      while i < @open_source.size
        nl = @open_source.index("\n", i)
        break if nl.nil?

        line_end = nl + 1
        line = @open_source[i...line_end]

        case @fence_state
        when :normal
          if line_starts_fence?(line)
            @fence_state = :in_fence
          elsif line.strip.empty?
            last_commit = line_end
          end
        when :in_fence
          if line_starts_fence?(line)
            @fence_state = :normal
            last_commit = line_end
          end
        end

        i = line_end
      end

      @scan_position = i

      return unless last_commit
      return unless commit_up_to(last_commit)

      @scan_position -= last_commit
    end

    # @param line [String] one complete line (with trailing +\n+).
    # @return [Boolean] +true+ if the line is a Markdown fence marker.
    #   Rough check: any line whose stripped form starts with three
    #   backticks or tildes. Doesn't validate matched fence lengths
    #   (CommonMark requires the closing fence to be at least as long
    #   as the opening); LLM output doesn't play games here.
    def line_starts_fence?(line)
      stripped = line.strip
      stripped.start_with?('```') || stripped.start_with?('~~~')
    end

    # Move +@open_source[0...idx]+ into the committed prefix. Renders
    # the *whole* committed source (old + new chunk) with a probe
    # sentinel appended, splits the result on +\n+, and takes
    # everything *before* the sentinel line as the new
    # +@committed_lines+. This lets the renderer decide whether the
    # boundary needs a trailing blank — fence-then-paragraph doesn't;
    # paragraph-then-paragraph does — instead of us guessing.
    #
    # If the commit-time render raises, leave the buffer untouched —
    # the content stays open and the next successful render still
    # diffs against the right baseline. Returns whether the commit
    # actually happened, so the caller can decide whether to adjust
    # +@scan_position+.
    # @param idx [Integer] exclusive end of the committed slice.
    # @return [Boolean] +true+ on success.
    def commit_up_to(idx)
      chunk = @open_source[0...idx]
      remaining = @open_source[idx..] || +''
      new_committed_source = @committed_source + chunk

      probe = "#{new_committed_source}\n\n#{COMMIT_PROBE_SENTINEL}"
      probe_rendered = @render.call(probe)
      lines = probe_rendered.split("\n")
      # +rindex+ rather than +find_index+ so even a hypothetical collision
      # with committed content can't fool us — the sentinel we just appended
      # is always the last occurrence.
      sentinel_idx = lines.rindex { |line| line.include?(COMMIT_PROBE_SENTINEL) }

      @committed_lines = if sentinel_idx
                           lines[0...sentinel_idx]
                         else
                           # Sentinel got mangled (very unlikely — it has no
                           # Markdown meaning). Fall back to a direct render;
                           # the boundary may pick up an extra blank but the
                           # content is still correct.
                           @render.call(new_committed_source).split("\n")
                         end
      @committed_source = new_committed_source
      @open_source = remaining
      true
    rescue StandardError => e
      Tuile.logger.warn(
        "StreamingMarkdownBuffer: commit-render failed " \
        "(#{e.class}: #{e.message}); keeping content open"
      )
      false
    end

    # Render the open block, splice with the committed prefix, diff
    # against the previous full render, and emit. The committed prefix
    # already includes any natural trailing blank line the renderer
    # produced at the block boundary (see {#commit_up_to}'s sentinel
    # probe), so we just concatenate. On render failure the open block
    # keeps its previous rendered shape — next successful render still
    # produces a clean diff.
    # @return [void]
    def rerender_and_emit
      open_rendered = render_lines(@open_source)
      return if open_rendered.nil?

      new_rendered_lines = @committed_lines + open_rendered

      prefix = common_prefix_length(@rendered_lines, new_rendered_lines)
      damage = @rendered_lines.size - prefix
      tail = new_rendered_lines[prefix..] || []

      @sink.call(damage, tail) if damage.positive? || tail.any?
      @rendered_lines = new_rendered_lines
    end

    # @param source [String]
    # @return [Array<String>, nil] hard lines of the rendered output, or
    #   +nil+ on render failure (logged, not raised).
    def render_lines(source)
      return [] if source.empty?

      rendered = @render.call(source)
      rendered.split("\n")
    rescue StandardError => e
      Tuile.logger.warn(
        "StreamingMarkdownBuffer: render failed " \
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
