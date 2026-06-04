# frozen_string_literal: true

require 'tuile'

module PikuriTui
  # Stateful buffer that turns a stream of Markdown deltas into in-place
  # rewrites of a +Tuile::Component::TextView::Region+. The buffer keeps
  # the region's content equal to the rendered form of the accumulated
  # source: each {#append} rerenders the currently-open block and assigns
  # the result back via +Region#text=+. The TextView's per-hard-line wrap
  # cache means only the changed tail is re-spliced, and an unchanged
  # render is short-circuited inside +Region#text=+, so per-token cost
  # stays bounded.
  #
  # The buffer is UI-unaware in the sense that it doesn't know about the
  # surrounding panes or layout — it owns one +Region+ and rewrites only
  # that region. Mutations of the region call +Tuile::Screen#check_locked+,
  # so the buffer must be driven from the UI thread (or a +FakeScreen+).
  # The listener is responsible for marshaling agent-event dispatch onto
  # the UI thread before calling into the buffer.
  #
  # == Why re-render-on-each-token
  #
  # Markdown rendering isn't streamable in any usable Ruby library:
  # {MarkdownRenderer} batches over +kramdown+, +CommonMarker+ batches over
  # +cmark+. Worse, Markdown is retroactively reformattable — a closing
  # +```+ turns earlier text into a code block; a new table row with a
  # wider cell re-pads every previous row. So the cheapest correct
  # primitive is: on each token, render the open block, assign the
  # combined committed-plus-open result to the region, and let the
  # +Region#text=+ splice do the in-place update.
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
  # never re-rendered. Per-token work shrinks from O(message-so-far) to
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
  # One buffer per assistant turn. The owner creates a fresh
  # {Tuile::Component::TextView::Region} (typically one per logical
  # block) and hands it to the buffer; the buffer rewrites only that
  # region. The owner calls {#append} for each
  # +Pikuri::Agent::Event::AssistantDelta+ payload, then {#finalize}
  # exactly once with the +Pikuri::Agent::Event::Assistant+ payload.
  # +AssistantDelta+ is documented as preview-only — pikuri makes no
  # guarantee that +deltas.join == Assistant#content+ (providers
  # normalize whitespace; Anthropic strips thinking signatures) — so
  # {#finalize} replaces the accumulated source with the authoritative
  # content and re-renders against it, leaving the region's content
  # exactly matching the authoritative render. After finalize the buffer
  # is dead: further calls raise.
  #
  # As a fast path, {#finalize} called with the buffer's own
  # +#source+ (the cancel-preserve case) skips the re-render entirely
  # — the region already matches.
  #
  # == Threading
  #
  # Not thread-safe. The region's mutators check
  # +Tuile::Screen#check_locked+, so the buffer must be driven from
  # whichever thread holds the UI lock (in practice, the UI thread; in
  # tests, any thread under +Tuile::Screen.fake+).
  class StreamingMarkdownBuffer
    # Probe marker appended after the committed source at commit time so
    # we can ask the renderer "what does committed render to, given
    # that *something* follows?" — the lines before the marker in the
    # probe output are the natural rendered form of the committed source
    # right up to the boundary with whatever block comes next. Using
    # the renderer's own answer avoids hand-coding "does this block
    # type leave a blank trailing line before that one?" rules —
    # trying to reproduce a renderer's spacing quirks by hand is a
    # losing game.
    #
    # The marker is a single Private-Use-Area Unicode codepoint
    # (+U+E000+). Unicode reserves the PUA for application-specific
    # use, so no spec assigns it a meaning, no LLM trained on natural
    # text emits it, and Markdown has nothing to do with it (an
    # earlier ASCII +_PKBND_+ marker got stripped to +PKBND+ because
    # the Markdown renderer treated the surrounding underscores as italics —
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
    # @param region [Tuile::Component::TextView::Region] the region to
    #   rewrite on every append. The buffer assumes exclusive ownership
    #   of the region for its lifetime: only the buffer should call
    #   +region.text=+ / +region.append+ / +region.replace+ between
    #   construction and {#finalize}. Surrounding content outside this
    #   region is untouched.
    def initialize(render:, region:)
      @render = render
      @region = region
      @committed_source = +''
      @committed_lines = []
      @open_source = +''
      @scan_position = 0
      @fence_state = :normal
      @finalized = false
    end

    # Feeds one streamed Markdown chunk. Concatenates onto the
    # accumulated source, advances any newly-closed block boundaries
    # into +@committed_lines+, re-renders the open block, and writes
    # the combined +(committed + open)+ result back to the region.
    # Empty / +nil+ content is a no-op (no source mutation, no region
    # write).
    #
    # @param content [String, nil] the +AssistantDelta#content+ payload.
    # @return [void]
    # @raise [RuntimeError] if called after {#finalize}.
    def append(content)
      raise 'StreamingMarkdownBuffer#append called after #finalize' if @finalized
      return if content.nil? || content.empty?

      process_for_commits(content)
      update_region
    end

    # Replaces the accumulated source with the authoritative content
    # and runs one final render. Designed to be called once per
    # assistant turn with the +Pikuri::Agent::Event::Assistant#content+
    # payload (the authoritative final Markdown, which may differ from
    # +deltas.join+). After this call the buffer is finalized — further
    # {#append} or {#finalize} calls raise.
    #
    # Fast path: if +authoritative+ equals the buffer's current
    # +#source+ (the cancel-preserve case — the host wants to commit
    # the preview as-is), the buffer just marks itself finalized and
    # returns without re-rendering. The region already shows the
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
      update_region
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
    # writes the right baseline. Returns whether the commit actually
    # happened, so the caller can decide whether to adjust
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

    # Render the open block, concatenate with the committed prefix, and
    # write the result back to the region. The committed prefix already
    # includes any natural trailing blank line the renderer produced at
    # the block boundary (see {#commit_up_to}'s sentinel probe), so we
    # just join with +\n+. On render failure the region keeps its
    # previous content — next successful render still produces a clean
    # update.
    # @return [void]
    def update_region
      open_rendered = render_lines(@open_source)
      return if open_rendered.nil?

      new_lines = @committed_lines + open_rendered
      @region.text = new_lines.join("\n")
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
  end
end
