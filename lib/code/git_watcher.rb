# frozen_string_literal: true

require 'open3'
require 'pikuri-core'

module Code
  # Polls git on a background thread and emits a {Snapshot} to every registered
  # listener ({#on_change}) — a **UI-independent service**. It knows nothing
  # about how its data is shown: no views, no `Tuile`, no event loop. Consumers
  # subscribe and decide what to do with each snapshot; a consumer that drives
  # UI is the one responsible for marshaling onto the event-loop thread (see
  # {Code::App}, which wraps its listener in +screen.event_queue.submit+ and
  # projects the snapshot onto the git panes).
  #
  #   watcher = Code::GitWatcher.new
  #   watcher.on_change { |snapshot| … }   # called on the poll thread
  #   watcher.start                        # spawn the poll thread
  #   # …
  #   watcher.stop
  #
  # The working tree changes for reasons no agent announces (the user editing
  # files, an external build, a +git+ command in a shell tool), so there is no
  # event to subscribe to — unlike {Shared::ConversationTextView::Listener} /
  # {TaskListPane::Listener}, which ride the agent's event stream. A
  # periodic poll is the honest model: every {POLL_INTERVAL} seconds capture the
  # current state and, only when it differs from the last capture, emit it.
  #
  # == What the Snapshot carries
  #
  # Two renderings' worth of data, because a real unified diff is far too wide
  # for a 40%-width sidebar: a per-file change summary ({Change} list, from the
  # {PORCELAIN_COMMAND} status + {NUMSTAT_COMMAND} counts) for the sidebar, and
  # the full raw diff ({TRACKED_COMMAND}) for the near-fullscreen popup.
  # {TRACKED_COMMAND} diffs the working tree against +HEAD+ (staged + unstaged).
  # Brand-new (untracked) files would be invisible to +git diff+; rather than
  # +git add -N+ them into the index (this service must not mutate the user's
  # repo), each is diffed against +/dev/null+ with +diff --no-index+
  # ({#untracked_diff}), rendering as a synthetic "new file" addition. In the
  # summary, untracked files show their whole line count as additions
  # ({#count_lines}), since +numstat+ ignores them.
  #
  # == Threading
  #
  # The poll runs on its own thread (started by {#start}, stopped by {#stop});
  # {#capture} runs the git commands and parses them there, and listeners are
  # invoked on that same poll thread. The service does no marshaling of its own
  # — that is the listener's job, which is exactly what keeps this service
  # framework-independent. The wait between polls is a timed
  # +Thread::Queue#pop+ on the stop signal, so {#stop} interrupts a sleeping
  # poll immediately instead of blocking up to {POLL_INTERVAL} seconds.
  class GitWatcher
    # One captured poll result as *data*: the +changes+ (an +Array<Change>+),
    # the raw plain +diff_text+, and an +error+ (nil on success, a "git
    # unavailable" notice when git could not be launched). A value object so
    # {#poll_once} can detect "nothing changed" with a plain +==+ and skip the
    # emit.
    Snapshot = Data.define(:changes, :diff_text, :error)

    # One changed file's summary data: its two-letter +git status+ porcelain
    # +code+, its +path+, and the +added+ / +deleted+ line counts. The element
    # type of {Snapshot}'s +changes+; a consumer renders it however it likes.
    Change = Data.define(:code, :path, :added, :deleted)

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
    # + unstaged diff since the last commit. Plain (uncolored) — a consumer
    # paints it (the {GitDiffWindow} via {GitDiffRenderer}).
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

    # @param interval [Integer] seconds between polls (default {POLL_INTERVAL});
    #   lowered by tests.
    # @param cwd [String] directory the +git+ commands run in. Defaults to
    #   the process working directory, which +bin/pikuri-tui-code+ has
    #   already +chdir+'d to the project root.
    def initialize(interval: POLL_INTERVAL, cwd: Dir.pwd)
      @interval = interval
      @cwd = cwd
      @listeners = []
      @last = nil
      @thread = nil
    end

    # Register a listener invoked with each fresh {Snapshot} (on the poll
    # thread — see the Threading note). A UI consumer must marshal onto the
    # event loop itself.
    #
    # @yieldparam snapshot [Snapshot]
    # @return [self]
    def on_change(&block)
      @listeners << block
      self
    end

    # Spawn the poll thread. Captures and emits an initial state right away
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
    # the previous capture, emit it to every listener. Exposed (and returning
    # whether it emitted) so specs can drive a single step without a thread.
    #
    # @return [Boolean] +true+ if anything changed and listeners were called,
    #   +false+ if unchanged and nothing emitted.
    def poll_once
      snapshot = capture
      return false if snapshot == @last

      @last = snapshot
      emit(snapshot)
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

    # @param snapshot [Snapshot]
    # @return [void]
    def emit(snapshot)
      @listeners.each { |listener| listener.call(snapshot) }
    end

    # Capture the current state in one pass: the per-file {Change} list and the
    # raw combined diff. Each git invocation's combined stdout+stderr is taken
    # verbatim — a non-zero exit (e.g. "not a git repository", or
    # +diff --no-index+'s by-design exit-1 when files differ) still yields
    # useful text. Only a failure to launch git at all (missing binary, bad
    # +cwd+, …) is caught, logged, and surfaced as an +error+ snapshot, per the
    # "library/external breakage is logged, we degrade" rule.
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
    # @return [Change] the enriched summary datum: untracked files count their
    #   whole length as additions, tracked files use numstat.
    def build_change(entry, counts)
      added, deleted =
        if entry.code == UNTRACKED_CODE
          [count_lines(entry.path), 0]
        else
          counts.fetch(entry.path, [0, 0])
        end
      Change.new(code: entry.code, path: entry.path, added: added, deleted: deleted)
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
