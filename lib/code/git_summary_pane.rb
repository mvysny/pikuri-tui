# frozen_string_literal: true

require 'pikuri-core'
require 'tuile'

module Code
  # The sidebar "Changes" pane: a borderless
  # {Tuile::Component::Layout::Vertical} stacking a {Shared::PaneCaptionLabel}
  # over a git change summary it renders itself, grouped by directory. Six
  # changed files in a 24-column sidebar read:
  #
  #   Changes: 6; +184/-17 ───    <- file count, then the whole tree's totals
  #   design/                     <- a header wherever the directory changes
  #    ?? decisions.md     +62
  #   lib/code/
  #     M task_list_pa… +31/-8    <- porcelain code toned by kind, name plain
  #     M git_summary_… +24/-6
  #     M layout.rb     +18/-2
  #   lib/shared/
  #     M pane_caption…  +9/-1
  #   spec/code/
  #     M task_list_pa…    +40    <- counts right-aligned on one column
  #
  # A {GitWatcher::Snapshot} arrives through {#snapshot=} (produced by the
  # {GitWatcher} service); the pane owns rendering, the service owns polling and
  # data - the data-in split (see the `cop` skill).
  #
  #   pane = Code::GitSummaryPane.new
  #   pane.snapshot = Code::GitWatcher::Snapshot.new(
  #     changes: [Code::GitWatcher::Change.new(code: ' M', path: 'a.rb', added: 2, deleted: 1)],
  #     diff_text: '…', error: nil)
  #   # => a "./" header over "  M a.rb +2/-1", under a "Changes: 1; +2/-1" caption
  #
  # A degraded snapshot (git failed) renders its notice instead, a clean tree
  # the {PLACEHOLDER}, and both leave the caption bare.
  #
  # A domain component built by subclassing a generic Tuile container and
  # rendering into its own content view: the coding shell's git-changes pane is
  # one unit, not a render-only view hand-captioned by its host. Sits on the
  # sidebar's +:pane_bg+ tint, inherited from {WorkspaceSidebar}.
  #
  # == Implementation details
  #
  # **Why grouping.** One list row per file, and at a 24-column sidebar the
  # list's gutters, the code and the counts leave barely a dozen columns of
  # path, which nothing under +lib/+ fits. Stating the directory once is what buys the filename room
  # without dropping to bare basenames, where +lib/code/app.rb+,
  # +lib/chat/app.rb+ and +lib/computer/app.rb+ would all render +M app.rb+.
  #
  # **Headers are inserted, never grouped by** — which is only correct because
  # +git status --porcelain+ output is path-sorted, so a directory's files are
  # already contiguous. A +group_by+ would shuffle rows under the reader.
  #
  # **Elision direction differs by row, deliberately.** A header keeps its tail
  # (+…/shared/markdown/+ — ancestors are context); a filename keeps its head,
  # because within one directory this repo's names share suffixes and differ at
  # the front (+git_diff_wind…+ / +git_diff_popu…+ / +git_diff_rend…+), and
  # left-elision would spend three of its columns on +.rb+.
  #
  # The rows are width-dependent — names cut to a budget so the counts align,
  # headers elided from the left — so a {Shared::PassiveList} renders them
  # against the width it hands its renderer, at paint time. A zero width (no
  # rect yet) reads as *unknown* and truncates nothing. The caption degrades by
  # the pane's width too, so it is chosen in {#relayout}.
  #
  # UI-thread-confined (the {WorkspaceSidebar} subscription marshals {#snapshot=}
  # onto the UI thread before calling it).
  class GitSummaryPane < Tuile::Component::Layout::Vertical
    # Shown when the working tree matches HEAD. Toned +:detail+ as placeholder chrome.
    #
    # @return [String]
    PLACEHOLDER = '(no changes)'

    # The two-letter porcelain code for an untracked file (its coloring cue).
    #
    # @return [String]
    UNTRACKED_CODE = '??'

    # The pane's caption row, which gains a +": 6; +184/-17"+ tally whenever
    # there are changes to total.
    #
    # @return [String]
    CAPTION = 'Changes'

    # The directory header for repo-root files. They need one like every other
    # group: byte order leaves them scattered through the list (+AGENTS.md+
    # before +bin/+, +mise.toml+ after +lib/+), so a headerless run would be
    # read as belonging to whichever header preceded it.
    #
    # @return [String]
    ROOT_GROUP = './'

    # Columns the two porcelain status letters occupy. Both are kept — the X/Y
    # split is staged-vs-unstaged, which is real information — and a shorter
    # code is right-justified into them so rows stay aligned.
    #
    # @return [Integer]
    CODE_WIDTH = 2

    # Columns a file row is indented under its directory header.
    #
    # @return [Integer]
    INDENT = 1

    # Columns the caption leaves free so its hairline survives: one space and
    # at least one +─+.
    #
    # @return [Integer]
    HAIRLINE_ROOM = 2

    # A directory header row, introducing the files under it.
    Header = Data.define(:directory)

    # A file row: the change and its rendered counts.
    FileRow = Data.define(:change, :counts)

    # Stacks a "Changes" caption row over a fresh list.
    def initialize
      super()
      @snapshot = nil
      @counts_width = 0
      # Passive and scrollbar-less: nothing in the sidebar is focusable, so
      # neither a tab stop nor a bar could ever be driven.
      @view = Shared::PassiveList.new
      @view.renderer = method(:row)
      @caption_label = Shared::PaneCaptionLabel.new(CAPTION)
      add(@caption_label, Fixed[1])
      add(@view, Expand[1])
    end

    # @return [Shared::PassiveList] the content view under the caption;
    #   exposed for tests, production drives it through {#snapshot=}.
    attr_reader :view

    # @return [Shared::PaneCaptionLabel] the caption row carrying the tally;
    #   exposed for tests.
    attr_reader :caption_label

    # Rewrite the pane from a git snapshot. Ignores the snapshot's diff (that's
    # the {GitDiffWindow}'s half). Must run on the UI thread. The caption is
    # only marked, and settles with the layout.
    #
    # @param snapshot [GitWatcher::Snapshot]
    # @return [void]
    def snapshot=(snapshot)
      @snapshot = snapshot
      entries = entries_for(snapshot)
      @counts_width = entries.grep(FileRow).map { |entry| entry.counts.display_width }.max || 0
      @view.items = entries
      invalidate_layout
    end

    protected

    # Stacks the caption over the view, then picks the caption form that fits
    # the width just settled — a snapshot can land before the pass that sizes
    # this pane.
    #
    # @return [void]
    def relayout
      super
      @caption_label.caption = caption_text
    end

    # Re-renders the rows and the caption: the counts bake their tones in.
    #
    # @return [void]
    def handle_theme_changed
      super
      self.snapshot = @snapshot
    end

    private

    # The caption, degraded to the widest form that still leaves
    # {HAIRLINE_ROOM}: +"Changes: 6; +184/-17"+, then +"Changes +184/-17"+, then
    # bare {CAPTION}. Choosing here is what protects the counts — they sit at
    # the end of the string, which is the end {Shared::PaneCaptionLabel} gives
    # up first. Only the totals are toned; the prose stays unset so
    # {Shared::PaneCaptionLabel} can fill its accent under it.
    #
    # @return [Tuile::StyledString]
    def caption_text
      changes = listable_changes
      bare = Tuile::StyledString.plain(CAPTION)
      return bare if changes.empty?

      counts = counts_for(changes.sum(&:added), changes.sum(&:deleted))
      # A rename-only tree totals 0/0, which {#counts_for} renders as nothing.
      forms = if counts.display_width.zero?
                [Tuile::StyledString.plain("#{CAPTION}: #{changes.size}"), bare]
              else
                [Tuile::StyledString.plain("#{CAPTION}: #{changes.size}; ") + counts,
                 Tuile::StyledString.plain("#{CAPTION} ") + counts, bare]
              end
      return forms.first unless width.positive?

      forms.find { |form| form.display_width + HAIRLINE_ROOM <= width } || bare
    end

    # @return [Array<GitWatcher::Change>] the changes to list — empty before the
    #   first snapshot and for a degraded one, both of which render a single
    #   line instead of a list.
    def listable_changes
      return [] if @snapshot.nil? || @snapshot.error

      @snapshot.changes
    end

    # The list entries for +snapshot+: nothing before the first one, the
    # degraded notice, the {PLACEHOLDER}, or a {Header} wherever the directory
    # changes and a {FileRow} per file.
    #
    # @param snapshot [GitWatcher::Snapshot, nil]
    # @return [Array<Tuile::StyledString, Header, FileRow>]
    def entries_for(snapshot)
      return [] if snapshot.nil?
      return [dim(snapshot.error)] if snapshot.error
      return [dim(PLACEHOLDER)] if snapshot.changes.empty?

      group = nil
      snapshot.changes.flat_map do |change|
        directory = group_of(change.path)
        file = FileRow.new(change: change, counts: counts_for(change.added, change.deleted))
        next [file] if directory == group

        group = directory
        [Header.new(directory: directory), file]
      end
    end

    # One list row, laid out against +width+.
    #
    # @param entry [Tuile::StyledString, Header, FileRow]
    # @param width [Integer] the columns the list gives the row; +0+ before it
    #   has a rect, which elides nothing.
    # @return [Tuile::StyledString]
    def row(entry, width)
      case entry
      when Header then group_row(entry.directory, width)
      when FileRow then change_row(entry.change, entry.counts, width)
      else entry
      end
    end

    # @param path [String] a repo-relative path.
    # @return [String] the directory header it belongs under, {ROOT_GROUP} for a
    #   repo-root file.
    def group_of(path)
      directory = File.dirname(path)
      directory == '.' ? ROOT_GROUP : "#{directory}/"
    end

    # @param directory [String]
    # @param width [Integer] see {#row}.
    # @return [Tuile::StyledString] the header row, elided from the left and
    #   dimmed so it recedes behind the filenames it introduces.
    def group_row(directory, width)
      header = Tuile::StyledString.plain(directory)
      header = header.ellipsize(width, at: :start) if width.positive?
      header.with_fg(screen.theme[:detail])
    end

    # @param change [GitWatcher::Change]
    # @param counts [Tuile::StyledString] its rendered counts, from {#counts_for}.
    # @param width [Integer] see {#row}.
    # @return [Tuile::StyledString] +"  M task_list_pa… +31/-8"+ — every file
    #   row reserves the snapshot's widest counts, so the numbers align on one
    #   right edge. Measured rather than fixed because a single file reaches
    #   +"+184/-17"+ — 8 columns.
    def change_row(change, counts, width)
      counts_width = @counts_width
      code = Tuile::StyledString.styled(change.code.rjust(CODE_WIDTH), fg: kind_color(change.code))
      name = Tuile::StyledString.plain(File.basename(change.path))
      budget = name_width(counts_width, width)
      name = name.ellipsize(budget).ljust(budget) if budget
      counts = Tuile::StyledString.plain(' ') + counts.rjust(counts_width) if counts_width.positive?
      Tuile::StyledString.plain(' ' * INDENT) + code + Tuile::StyledString.plain(' ') + name + counts
    end

    # @param counts_width [Integer] columns the counts column reserves.
    # @param width [Integer] see {#row}.
    # @return [Integer, nil] columns a filename may occupy, or +nil+ when the
    #   row has no width yet and nothing should be elided.
    def name_width(counts_width, width)
      return nil unless width.positive?

      reserved = INDENT + CODE_WIDTH + 1 + (counts_width.positive? ? counts_width + 1 : 0)
      [width - reserved, 1].max
    end

    # @param added [Integer] lines added, by one file or by the whole tree.
    # @param deleted [Integer] lines deleted.
    # @return [Tuile::StyledString] +"+31/-8"+ — green additions, red deletions,
    #   and a dim slash binding them into one token rather than two loose
    #   numbers. A zero side is omitted; two zero sides render empty.
    def counts_for(added, deleted)
      theme = screen.theme
      parts = []
      parts << Tuile::StyledString.styled("+#{added}", fg: theme[:added]) if added.positive?
      parts << Tuile::StyledString.styled("-#{deleted}", fg: theme[:removed]) if deleted.positive?
      return Tuile::StyledString::EMPTY if parts.empty?

      separator = Tuile::StyledString.styled('/', fg: theme[:detail])
      parts.inject { |acc, part| acc + separator + part }
    end

    # Tones the porcelain code by change kind so the list scans at a glance: a
    # +D+ in either column is a deletion, an +A+ or the untracked
    # {UNTRACKED_CODE} is new, everything else (+M+, +MM+, …) a modification.
    # The code carries the kind rather than the filename — it *is* the kind,
    # and it leaves the name in the default foreground as the row's anchor.
    #
    # @param code [String] the two-letter porcelain status code.
    # @return [Tuile::Color]
    def kind_color(code)
      theme = screen.theme
      if code.include?('D')
        theme[:removed]
      elsif code == UNTRACKED_CODE || code.include?('A')
        theme[:added]
      else
        theme[:notice]
      end
    end

    # @param text [String]
    # @return [Tuile::StyledString] +text+ in the placeholder tone.
    def dim(text) = Tuile::StyledString.styled(text, fg: screen.theme[:detail])
  end
end
