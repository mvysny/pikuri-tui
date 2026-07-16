# frozen_string_literal: true

require 'open3'
require 'pikuri-core'
require 'tuile'

module Code
  # Polls git on a background thread and feeds two panes with *data*: a per-file
  # change summary for the sidebar {GitSummaryTextView} and the raw working-tree
  # diff for the {GitDiffTextView} inside {GitDiffPopup} (leader menu +d+).
  # Those panes own how the data is drawn; this watcher owns only polling, data
  # production, and change detection — the model half of the data-in split (see
  # the `cop` skill).
  #
  # Unlike {Shared::ConversationTextView::Listener} / {TaskListTextView::Listener}
  # — which ride the agent's event stream — the working tree changes for reasons
  # the agent never announces (the user editing files, an external build, a
  # +git+ command in a shell tool), so there is no event to subscribe to. A
  # periodic poll is the honest model: every {POLL_INTERVAL} seconds capture the
  # current state and, only when it differs from the last capture, push it to
  # the panes.
  #
  # == Why two panes
  #
  # A real unified diff is far too wide for a 40%-width sidebar. So the sidebar
  # shows only the {PORCELAIN_COMMAND} file list (the +git status+ short codes)
  # annotated with {NUMSTAT_COMMAND} +/- line counts, and the hunks themselves
  # go to a near-fullscreen popup.
  #
  # == What the diff covers
  #
  # {TRACKED_COMMAND} diffs the working tree against +HEAD+ (staged + unstaged).
  # Brand-new (untracked) files would be invisible to +git diff+; rather than
  # +git add -N+ them into the index (a read-only pane must not mutate the
  # user's repo), each is diffed against +/dev/null+ with +diff --no-index+
  # ({#untracked_diff}), rendering it as a synthetic "new file" addition. In the
  # summary, untracked files show their whole line count as additions
  # ({#count_lines}), since +numstat+ ignores them.
  #
  # == Threading
  #
  # The poll runs on its own thread (started by {#start}, stopped by {#stop});
  # {#capture} runs the git commands and parses them there. Like the agent
  # worker it must not touch the UI directly, so each push is marshaled onto the
  # event-loop thread via +screen.event_queue.submit+, where the panes render.
  # Rendering — including re-rendering the diff at a new width on resize — is the
  # panes' job, not this watcher's: it asks git for *plain* (uncolored) output
  # ({#run}) and hands it over verbatim. The wait between polls is a timed
  # +Thread::Queue#pop+ on the stop signal, so {#stop} interrupts a sleeping
  # poll immediately instead of blocking up to {POLL_INTERVAL} seconds.
  class GitWatcher
    # One captured poll result as *data*: the +changes+ (an
    # +Array<GitSummaryTextView::Change>+), the raw plain +diff_text+, and an
    # +error+ (nil on success, a "git unavailable" notice when git could not be
    # launched). A value object so {#poll_once} can detect "nothing changed"
    # with a plain +==+ and skip the push.
    Snapshot = Data.define(:changes, :diff_text, :error)

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
    # + unstaged diff since the last commit. Plain (uncolored) — the
    # {GitDiffTextView} paints it via {GitDiffRenderer}.
    #
    # @return [Array<String>]
    TRACKED_COMMAND = %w[git diff HEAD].freeze

    # Diffs one file against +/dev/null+ without consulting the index, so
    # an untracked file shows as an all-additions "new file" diff. The
    # +--+, +/dev/null+, and path are appended per-file by {#untracked_diff}.
    #
    # @return [Array<String>]
    NO_INDEX_COMMAND = %w[git diff --no-index].freeze

    # The two-letter porcelain code for an untracked file.
    #
    # @return [String]
    UNTRACKED_CODE = '??'

    LOG = Pikuri.logger_for('git')
    private_constant :LOG

    # @param summary_view [GitSummaryTextView] the sidebar pane; fed via
    #   {GitSummaryTextView#changes=}. Owned by the host ({Code::App}); the
    #   watcher neither builds nor destroys it.
    # @param diff_view [GitDiffTextView] the pane inside {GitDiffPopup}; fed via
    #   {GitDiffTextView#diff=}, kept current on every poll whether or not the
    #   popup is open. Same ownership.
    # @param screen [Tuile::Screen] the screen whose +event_queue+ marshals each
    #   push back from the poll thread. Passed explicitly (not via the
    #   singleton) so tests can inject a {Tuile::FakeScreen}.
    # @param interval [Integer] seconds between polls (default {POLL_INTERVAL});
    #   lowered by tests.
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

    # Spawn the poll thread. Captures and pushes an initial state right away
    # (the first poll runs before the first wait), then re-polls every
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

    # One poll step: capture the current state and, only when it differs from
    # the previous capture, marshal a push of the data to both panes onto the UI
    # thread. Exposed (and returning whether it pushed) so specs can drive a
    # single step and assert change-detection without a thread.
    #
    # @return [Boolean] +true+ if anything changed and a push was submitted,
    #   +false+ if unchanged and the panes left as-is.
    def poll_once
      snapshot = capture
      return false if snapshot == @last

      @last = snapshot
      @screen.event_queue.submit { push(snapshot) }
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

    # Push a snapshot's data to the panes. Runs on the event-loop thread via
    # {#poll_once}'s +submit+: the degraded notice when git could not be
    # launched, else the summary changes and the raw diff. The panes render.
    #
    # @param snapshot [Snapshot]
    # @return [void]
    def push(snapshot)
      if snapshot.error
        @summary_view.notice = snapshot.error
        @diff_view.notice = snapshot.error
      else
        @summary_view.changes = snapshot.changes
        @diff_view.diff = snapshot.diff_text
      end
    end

    # Capture the current state in one pass: the per-file {GitSummaryTextView::Change}
    # list and the raw combined diff. Each git invocation's combined stdout+stderr
    # is taken verbatim — a non-zero exit (e.g. "not a git repository", or
    # +diff --no-index+'s by-design exit-1 when files differ) still yields useful
    # text. Only a failure to launch git at all (missing binary, bad +cwd+, …) is
    # caught, logged, and surfaced as an +error+ notice, per the "library/external
    # breakage is logged, we degrade" rule.
    #
    # @return [Snapshot]
    def capture
      entries = parse_porcelain(run(PORCELAIN_COMMAND))
      counts = numstat_counts
      untracked = entries.select { |e| e.code == UNTRACKED_CODE }.map(&:path)
      changes = entries.map { |entry| build_change(entry, counts) }
      diff_text = [tracked_diff, *untracked.map { |p| untracked_diff(p) }].reject(&:empty?).join
      Snapshot.new(changes: changes, diff_text: diff_text, error: nil)
    rescue StandardError => e
      LOG.error("git poll failed: #{e.class}: #{e.message}")
      Snapshot.new(changes: [], diff_text: '', error: "git unavailable: #{e.message}")
    end

    # @param entry [Entry] a parsed porcelain row.
    # @param counts [Hash{String => Array(Integer, Integer)}] tracked path =>
    #   [added, deleted] from {#numstat_counts}.
    # @return [GitSummaryTextView::Change] the enriched summary datum: untracked
    #   files count their whole length as additions, tracked files use numstat.
    def build_change(entry, counts)
      added, deleted =
        if entry.code == UNTRACKED_CODE
          [count_lines(entry.path), 0]
        else
          counts.fetch(entry.path, [0, 0])
        end
      GitSummaryTextView::Change.new(code: entry.code, path: entry.path, added: added, deleted: deleted)
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
