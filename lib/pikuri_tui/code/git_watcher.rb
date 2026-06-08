# frozen_string_literal: true

require 'open3'
require 'pikuri-core'
require 'tuile'

module PikuriTui
  module Code
    # Polls git on a background thread and feeds two views: a compact change
    # summary in the sidebar (one +XY path  +N -N+ line per changed file)
    # and the full colored diff in the {GitDiffPopup} (+Ctrl+G+). Unlike
    # {TuileListener} / {TaskListener} — which ride the agent's event stream
    # — the working tree changes for reasons the agent never announces (the
    # user editing files, an external build, a +git+ command in a shell
    # tool), so there is no event to subscribe to. A periodic poll is the
    # honest model: every {POLL_INTERVAL} seconds capture both renderings
    # and, only when they differ from the last capture, rewrite the panes.
    #
    # == Why two views
    #
    # A real unified diff is far too wide for a 40%-width sidebar. So the
    # sidebar shows only the {PORCELAIN_COMMAND} file list (the same
    # +git status+ short codes the coding shell showed before) annotated
    # with {NUMSTAT_COMMAND} +/- line counts, and the hunks themselves go to
    # a near-fullscreen popup.
    #
    # == What the diff covers
    #
    # {TRACKED_COMMAND} diffs the working tree against +HEAD+ (staged +
    # unstaged). Brand-new (untracked) files would be invisible to +git
    # diff+; rather than +git add -N+ them into the index (a read-only pane
    # must not mutate the user's repo), each is diffed against +/dev/null+
    # with +diff --no-index+ ({#untracked_diff}), rendering it as a synthetic
    # "new file" addition. In the summary, untracked files show their whole
    # line count as additions ({#count_lines}), since +numstat+ ignores them.
    #
    # == Colored output
    #
    # +git+ suppresses color on a non-TTY pipe, so the diff commands force it
    # with +-c color.ui=always+; Tuile's {Tuile::Component::TextView} parses
    # the embedded ANSI ({Tuile::StyledString.parse}), so git's own diff
    # coloring carries through. That parser is strict (fg/bg/bold/italic/
    # underline only); should git emit an SGR code outside that set (e.g. the
    # reverse-video whitespace-error highlight), {#render_diff} logs and
    # falls back to ANSI-stripped plain text rather than tearing down the
    # screen — the "library breakage is logged, we degrade" rule from
    # CLAUDE.md. The summary's +/- markers are colored by us via {AppTheme}.
    #
    # == Threading
    #
    # The poll runs on its own thread (started by {#start}, stopped by
    # {#stop}); like the agent worker it must not touch the UI directly, so
    # each rewrite is marshaled onto the event-loop thread via
    # +screen.event_queue.submit+. The wait between polls is a timed
    # +Thread::Queue#pop+ on the stop signal, so {#stop} interrupts a
    # sleeping poll immediately instead of blocking up to {POLL_INTERVAL}
    # seconds.
    class GitWatcher
      # One captured poll result: the rendered sidebar +summary+ and the full
      # colored +diff+. A value object so {#poll_once} can detect "nothing
      # changed" with a plain +==+ and skip the rewrite.
      Snapshot = Data.define(:summary, :diff)

      # Seconds between captures.
      #
      # @return [Integer]
      POLL_INTERVAL = 10

      # Lists every changed path with its two-letter status, NUL-delimited
      # so paths with spaces or newlines survive the split. +--no-renames+
      # keeps each entry a single +XY path+ (a rename is shown as a delete +
      # an add), so parsing never has to handle the two-path rename form.
      #
      # @return [Array<String>]
      PORCELAIN_COMMAND = %w[git status --porcelain=v1 --no-renames -z].freeze

      # Per-file +added\tdeleted\tpath+ counts for tracked changes, keyed by
      # path into the summary. +-z+ NUL-delimits entries; binary files report
      # +-+ for both counts (parsed as 0). Tracked changes only — untracked
      # files are counted by {#count_lines}.
      #
      # @return [Array<String>]
      NUMSTAT_COMMAND = %w[git diff HEAD --numstat --no-renames -z].freeze

      # The tracked-change diff for the popup: +diff HEAD+ is the full staged
      # + unstaged diff since the last commit, colored for the pane.
      #
      # @return [Array<String>]
      TRACKED_COMMAND = %w[git -c color.ui=always diff HEAD].freeze

      # Diffs one file against +/dev/null+ without consulting the index, so
      # an untracked file shows as an all-additions "new file" diff. The
      # +--+, +/dev/null+, and path are appended per-file by {#untracked_diff}.
      #
      # @return [Array<String>]
      NO_INDEX_COMMAND = %w[git -c color.ui=always diff --no-index].freeze

      # The two-letter porcelain code for an untracked file.
      #
      # @return [String]
      UNTRACKED_CODE = '??'

      # Shown in both panes when nothing has changed (no tracked diff,
      # nothing untracked). Toned +:detail+ so it reads as placeholder chrome.
      #
      # @return [String]
      PLACEHOLDER = '(no changes)'

      # @param summary_view [Tuile::Component::TextView] the sidebar pane the
      #   per-file change summary is rendered into. Owned by the host
      #   ({Code::App}); the watcher neither builds nor destroys it.
      # @param diff_view [Tuile::Component::TextView] the pane inside the
      #   {GitDiffPopup} the full colored diff is rendered into. Kept current
      #   on every poll whether or not the popup is open. Same ownership.
      # @param screen [Tuile::Screen] the screen whose +event_queue+ marshals
      #   the rewrite back from the poll thread and whose +theme+ colors the
      #   summary. Passed explicitly (not via the singleton) so tests can
      #   inject a {Tuile::FakeScreen}.
      # @param interval [Integer] seconds between polls (default
      #   {POLL_INTERVAL}); lowered by tests.
      # @param cwd [String] directory the +git+ commands run in. Defaults to
      #   the process working directory, which +bin/pikuri-tui-code+ has
      #   already +chdir+'d to the project root.
      def initialize(summary_view:, diff_view:, screen:, interval: POLL_INTERVAL, cwd: Dir.pwd)
        @summary_view = summary_view
        @diff_view = diff_view
        @screen = screen
        @interval = interval
        @cwd = cwd
        @last = nil
        @thread = nil
      end

      # Spawn the poll thread. Renders an initial capture right away (the
      # first poll runs before the first wait), then re-polls every
      # {@interval} seconds until {#stop}. Idempotent: a second call while
      # the thread is alive is a no-op.
      #
      # @return [void]
      def start
        return if @thread

        @stop = Thread::Queue.new
        @thread = Thread.new { poll_loop }
      end

      # Signal the poll thread to exit and wait for it. Wakes a thread
      # sleeping between polls immediately via the stop queue, so this
      # returns within one in-flight git invocation at worst. Idempotent: a
      # no-op when not started.
      #
      # @return [void]
      def stop
        return unless @thread

        @stop.push(:stop)
        @thread.join
        @thread = nil
      end

      # One poll step: capture the summary + diff and, only when the pair
      # differs from the previous capture, marshal a rewrite of both panes
      # onto the UI thread. Exposed (and returning whether it rendered) so
      # specs can drive a single step and assert the change-detection without
      # a thread.
      #
      # @return [Boolean] +true+ if anything changed and a rewrite was
      #   submitted, +false+ if unchanged and the panes left as-is.
      def poll_once
        snapshot = capture
        return false if snapshot == @last

        @last = snapshot
        @screen.event_queue.submit { render(snapshot) }
        true
      end

      # @return [String] short label for diagnostics.
      def to_s = 'GitWatcher'

      private

      # @return [void]
      def poll_loop
        loop do
          poll_once
          break if @stop.pop(timeout: @interval)
        end
      end

      # Capture both renderings in one pass. Each git invocation's combined
      # stdout+stderr is taken verbatim — a non-zero exit (e.g. "not a git
      # repository", or +diff --no-index+'s by-design exit-1 when files
      # differ) still yields useful text. Only a failure to launch git at all
      # (missing binary, …) is caught, logged, and surfaced as a one-line
      # notice in both panes, per the "library/external breakage is logged,
      # we degrade" rule.
      #
      # @return [Snapshot]
      def capture
        entries = parse_porcelain(run(PORCELAIN_COMMAND))
        untracked = entries.select { |e| e.code == UNTRACKED_CODE }.map(&:path)
        diff = [tracked_diff, *untracked.map { |p| untracked_diff(p) }].reject(&:empty?).join
        Snapshot.new(summary: render_summary(entries), diff: diff)
      rescue StandardError => e
        Tuile.logger.error("git poll failed: #{e.class}: #{e.message}")
        notice = "git unavailable: #{e.message}"
        Snapshot.new(summary: notice, diff: notice)
      end

      # Rewrite both panes from a snapshot. Runs on the event-loop thread via
      # {#poll_once}'s +submit+, so the +text=+ calls are under the UI lock.
      #
      # @param snapshot [Snapshot]
      # @return [void]
      def render(snapshot)
        @summary_view.text = snapshot.summary
        render_diff(snapshot.diff)
      end

      # The full colored diff into the popup pane, falling back to
      # ANSI-stripped plain text if git emitted an SGR code the strict
      # {Tuile::StyledString} parser rejects.
      #
      # @param diff [String]
      # @return [void]
      def render_diff(diff)
        @diff_view.text = diff.empty? ? @screen.theme.detail(PLACEHOLDER) : diff
      rescue Tuile::StyledString::ParseError => e
        Tuile.logger.warn("git diff had unsupported ANSI, showing plain: #{e.message}")
        @diff_view.text = diff.gsub(/\e\[[0-9;]*m/, '')
      end

      # The sidebar summary: one line per changed file, +"XY path  +A -D"+,
      # with the counts colored via {AppTheme}. The {PLACEHOLDER} when
      # nothing changed.
      #
      # @param entries [Array<Entry>]
      # @return [String]
      def render_summary(entries)
        return @screen.theme.detail(PLACEHOLDER) if entries.empty?

        counts = numstat_counts
        entries.map { |entry| summary_line(entry, counts) }.join("\n")
      end

      # @param entry [Entry]
      # @param counts [Hash{String => Array(Integer, Integer)}] tracked
      #   path => [added, deleted] from {#numstat_counts}.
      # @return [String]
      def summary_line(entry, counts)
        added, deleted =
          if entry.code == UNTRACKED_CODE
            [count_lines(entry.path), 0]
          else
            counts.fetch(entry.path, [0, 0])
          end

        markers = []
        markers << @screen.theme.added("+#{added}") if added.positive?
        markers << @screen.theme.removed("-#{deleted}") if deleted.positive?
        line = "#{entry.code} #{entry.path}"
        markers.empty? ? line : "#{line}  #{markers.join(' ')}"
      end

      # @return [Hash{String => Array(Integer, Integer)}] tracked path =>
      #   [added, deleted].
      def numstat_counts
        run(NUMSTAT_COMMAND).split("\x00").reject(&:empty?).each_with_object({}) do |entry, acc|
          added, deleted, path = entry.split("\t", 3)
          acc[path] = [added.to_i, deleted.to_i]
        end
      end

      # @param raw [String] NUL-delimited +git status --porcelain=v1+ output.
      # @return [Array<Entry>] one per changed path, in git's order.
      def parse_porcelain(raw)
        raw.split("\x00").reject(&:empty?).map { |entry| Entry.new(code: entry[0, 2], path: entry[3..]) }
      end

      # @return [String] diff of tracked changes (staged + unstaged) vs HEAD.
      def tracked_diff = run(TRACKED_COMMAND)

      # @param path [String] repo-relative path of an untracked file.
      # @return [String] +diff --no-index+ of +/dev/null+ vs +path+ — the
      #   file rendered as an all-additions new-file diff.
      def untracked_diff(path) = run(NO_INDEX_COMMAND, '--', File::NULL, path)

      # @param path [String] repo-relative path of an untracked file.
      # @return [Integer] its line count (the additions shown in the
      #   summary), or +0+ if it vanished between listing and reading.
      def count_lines(path)
        File.foreach(File.join(@cwd, path)).count
      rescue StandardError
        0
      end

      # @param command [Array<String>] argv to run in {@cwd}.
      # @param extra [Array<String>] extra argv appended after +command+.
      # @return [String] combined stdout+stderr.
      def run(command, *extra)
        out, = Open3.capture2e(*command, *extra, chdir: @cwd)
        out
      end

      # One parsed +git status --porcelain+ row: the two-letter status code
      # and the path it applies to.
      Entry = Data.define(:code, :path)
    end
  end
end
