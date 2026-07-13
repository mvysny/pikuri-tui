# frozen_string_literal: true

require 'tuile'

module Code
  # Renders a plain (uncolored) +git diff+ into the same two-tier inline
  # format {DiffRenderer} paints for the edit / write tool calls — so the
  # leader-menu diff popup reads as one visual family with the conversation
  # pane instead of carrying git's own coloring.
  #
  #   ansi = Code::GitDiffRenderer.render(git_diff_output, theme: theme, max_width: 100)
  #
  # == How it reuses {DiffRenderer}
  #
  # A unified diff already hands us, per hunk, both sides of the change: the
  # context + removed lines are the "before", the context + added lines the
  # "after". So each hunk is reconstructed into that +(old, new)+ pair and
  # handed to {DiffRenderer.render}, which re-aligns it with
  # {Diff::LCS.sdiff} — recovering the per-line add/remove/modify split and,
  # for a modified pair, the inline character-level emphasis. We do not trust
  # git's own line pairing; the LCS re-alignment is what gives the popup the
  # identical look to the tool-call diffs. The output is assembled as a
  # themed file header ({DiffToolFormatting::GLYPH} + path) over dim
  # +@@ line N @@+ hunk separators (the +N+ is the new-side start line, read
  # straight from git's +@@+ header) over each rendered hunk body.
  #
  # == Width
  #
  # {DiffRenderer} pads its line bars to a target width. Because
  # {Tuile::Component::TextView} word-wraps lines wider than its viewport
  # (and the {GitDiffPopup} caps at 4/5 of the screen), padding past the pane
  # would wrap the padding onto extra tinted rows. So the render width is
  # +min(longest content line, max_width)+: short diffs get content-width
  # bars, wide ones cap at the caller's +max_width+ (the pane estimate) and
  # let only genuinely over-wide lines wrap — same as git's raw output would.
  #
  # == Colors and the screen
  #
  # Like {DiffToolFormatting}, this takes a {Tuile::Theme} (not a
  # {Tuile::Screen}): the {DiffRenderer::Palette} is built from its +:diff_*+
  # tokens and the header / separator tones come from its +tool+ / +detail+
  # helpers, so it renders and tests without a live screen. +color+ threads
  # into {DiffRenderer} (so the suite's +NO_COLOR+ yields the plain
  # delete + add fallback for modified lines); the themed header / separator
  # always emit SGR, which specs strip by parsing.
  class GitDiffRenderer
    # Matches a unified-diff hunk header, capturing the new-side start line
    # from the +@@ -old +new @@+ ranges.
    # @return [Regexp]
    HUNK_HEADER = /\A@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/
    private_constant :HUNK_HEADER

    # Matches the +diff --git a/path b/path+ section header, capturing the
    # b-side path. The fallback path source for sections without +---+ /
    # +++++ lines (e.g. a +Binary files … differ+ section).
    # @return [Regexp]
    DIFF_HEADER = %r{\Adiff --git a/.* b/(.+)\z}
    private_constant :DIFF_HEADER

    # Per-kind suffix appended to a file's header line.
    # @return [Hash{Symbol => String}]
    KIND_SUFFIX = { modified: '', new: ' (new file)', deleted: ' (deleted)' }.freeze
    private_constant :KIND_SUFFIX

    # The popup scrolls, so hunks render in full; this is only a runaway
    # backstop far above any real hunk.
    # @return [Integer]
    HUNK_MAX_LINES = 100_000
    private_constant :HUNK_MAX_LINES

    # One parsed file section of the diff.
    #
    # @!attribute [r] path
    #   @return [String] the working-tree path shown in the header.
    # @!attribute [r] kind
    #   @return [Symbol] +:modified+, +:new+, or +:deleted+.
    # @!attribute [r] binary
    #   @return [Boolean] +true+ for a +Binary files … differ+ section (no hunks).
    # @!attribute [r] hunks
    #   @return [Array<Hunk>] the file's hunks (empty when +binary+).
    File = Data.define(:path, :kind, :binary, :hunks)
    private_constant :File

    # One parsed hunk: the new-side start line and the reconstructed before /
    # after line arrays (markers stripped).
    #
    # @!attribute [r] new_start
    #   @return [Integer] the +@@ … +N @@+ new-side start line.
    # @!attribute [r] old
    #   @return [Array<String>] context + removed lines (the "before").
    # @!attribute [r] new
    #   @return [Array<String>] context + added lines (the "after").
    Hunk = Data.define(:new_start, :old, :new)
    private_constant :Hunk

    # Render a plain +git diff+ string to the two-tier inline ANSI form.
    #
    # @param diff_text [String] combined plain (uncolored) +git diff+ output;
    #   may concatenate several file sections.
    # @param theme [Tuile::Theme] supplies the diff palette and the header /
    #   separator tones.
    # @param max_width [Integer] the pane-width cap line bars pad up to.
    # @param color [Boolean, nil] forwarded to {DiffRenderer}; +nil+ follows
    #   +NO_COLOR+.
    # @return [String] newline-joined ANSI diff (+""+ for an empty input).
    def self.render(diff_text, theme:, max_width:, color: nil)
      new(theme: theme, max_width: max_width, color: color).render(diff_text)
    end

    # @param theme [Tuile::Theme] see {.render}.
    # @param max_width [Integer] see {.render}.
    # @param color [Boolean, nil] see {.render}.
    def initialize(theme:, max_width:, color:)
      @theme = theme
      @palette = DiffToolFormatting.palette(theme)
      @max_width = [max_width, 1].max
      @color = color
    end

    # @param diff_text [String]
    # @return [String] see {.render}.
    def render(diff_text)
      files = parse(diff_text)
      return '' if files.empty?

      width = [content_width(files), @max_width].min
      files.map { |file| render_file(file, width) }.join("\n\n")
    end

    private

    # Parse a unified diff into {File}s. Each +diff --git+ line opens a
    # section; +new file+ / +deleted file+ / +Binary files+ set the kind; the
    # +---+ / +++++ lines give the path (preferring the new side, falling
    # back to the old for a deletion); each +@@+ opens a hunk whose body
    # lines are sorted by marker into the before / after arrays.
    #
    # @param diff_text [String]
    # @return [Array<File>]
    def parse(diff_text)
      builders = []
      builder = nil
      hunk = nil
      diff_text.each_line(chomp: true) do |line|
        if line.start_with?('diff --git ')
          builder = { kind: :modified, binary: false, header_path: DIFF_HEADER.match(line)&.captures&.first,
                      old_path: nil, new_path: nil, hunks: [] }
          builders << builder
          hunk = nil
        elsif builder.nil?
          next
        elsif line.start_with?('new file mode') then builder[:kind] = :new
        elsif line.start_with?('deleted file mode') then builder[:kind] = :deleted
        elsif line.start_with?('Binary files ') then builder[:binary] = true
        elsif line.start_with?('--- ') then builder[:old_path] = strip_path(line[4..])
        elsif line.start_with?('+++ ') then builder[:new_path] = strip_path(line[4..])
        elsif (match = HUNK_HEADER.match(line))
          hunk = { new_start: match[1].to_i, old: [], new: [] }
          builder[:hunks] << hunk
        elsif hunk
          collect_hunk_line(hunk, line)
        end
      end
      builders.map { |b| build_file(b) }
    end

    # Sort one hunk body line into the before / after arrays by its leading
    # marker. Context (+' '+) goes to both, +'-'+ to the before, +'+'+ to the
    # after; the +"\ No newline at end of file"+ marker and anything else is
    # ignored.
    #
    # @param hunk [Hash] the in-progress hunk builder.
    # @param line [String] a raw hunk body line (marker included).
    # @return [void]
    def collect_hunk_line(hunk, line)
      case line[0]
      when ' ' then hunk[:old] << line[1..]; hunk[:new] << line[1..]
      when '-' then hunk[:old] << line[1..]
      when '+' then hunk[:new] << line[1..]
      end
    end

    # Finalize a parsed-file builder: pick the working-tree path (new side,
    # or the old side for a deletion) and infer the kind from the +/dev/null+
    # markers when an explicit +new file+ / +deleted file+ line was absent
    # (e.g. +diff --no-index+ for an untracked file).
    #
    # @param builder [Hash]
    # @return [File]
    def build_file(builder)
      path = builder[:new_path] || builder[:old_path] || builder[:header_path] || '(unknown)'
      kind = builder[:kind]
      kind = :new if kind == :modified && builder[:old_path].nil? && !builder[:new_path].nil?
      kind = :deleted if kind == :modified && builder[:new_path].nil? && !builder[:old_path].nil?
      File.new(path: path, kind: kind, binary: builder[:binary], hunks: build_hunks(builder[:hunks]))
    end

    # @param hunks [Array<Hash>] in-progress hunk builders.
    # @return [Array<Hunk>]
    def build_hunks(hunks)
      hunks.map { |h| Hunk.new(new_start: h[:new_start], old: h[:old], new: h[:new]) }
    end

    # Strip a +git diff+ path: +nil+ for +/dev/null+, otherwise drop the
    # +a/+ or +b/+ prefix and any trailing tab-delimited timestamp.
    #
    # @param raw [String] the text after +"--- "+ / +"+++ "+.
    # @return [String, nil]
    def strip_path(raw)
      path = raw.sub(/\t.*\z/, '')
      return nil if path == '/dev/null'

      path.sub(%r{\A[ab]/}, '')
    end

    # Render one {File}: the themed header over its hunks (or a +(binary)+
    # note). Each hunk is a dim +@@ line N @@+ separator over the
    # {DiffRenderer} body of its reconstructed before / after pair.
    #
    # @param file [File]
    # @param width [Integer] the render width line bars pad to.
    # @return [String]
    def render_file(file, width)
      lines = [@theme.tool("#{DiffToolFormatting::GLYPH} #{file.path}#{KIND_SUFFIX.fetch(file.kind)}")]
      if file.binary
        lines << @theme.detail('  (binary)')
      else
        file.hunks.each do |hunk|
          lines << @theme.detail("  @@ line #{hunk.new_start} @@")
          lines << DiffRenderer.render(hunk.old.join("\n"), hunk.new.join("\n"),
                                       width: width, palette: @palette,
                                       max_lines: HUNK_MAX_LINES, color: @color)
        end
      end
      lines.join("\n")
    end

    # The longest diff-body line across every hunk, plus the 2-column gutter
    # — the natural width the bars want before the {@max_width} cap. Binary
    # files (no body) contribute nothing.
    #
    # @param files [Array<File>]
    # @return [Integer]
    def content_width(files)
      longest = files.reject(&:binary)
                     .flat_map(&:hunks)
                     .flat_map { |hunk| hunk.old + hunk.new }
                     .map(&:length).max || 0
      longest + 2
    end
  end
end
