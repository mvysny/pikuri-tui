# frozen_string_literal: true

module Code
  # Persistent record of which project roots the user has affirmed as
  # *git-config-trusted*, so the coding shell prompts for that trust at
  # most once per project across runs.
  #
  # The coding bin gates +Pikuri::Code::Bash::PassiveCommandDetector+'s
  # +allow_git:+ on this store: a trusted repo additionally auto-approves
  # read-only git (+status+/+diff+/+log+/+show+/…). That is sound only
  # because the user has vouched for the repo's +.git/config+ +
  # +.gitattributes+ — even a bare +git diff+ runs whatever
  # +diff.*.textconv+ / +core.fsmonitor+ the repo config directs.
  #
  # The file is a plain newline-delimited list of realpath'd project-root
  # paths under {Pikuri::Paths.state} (no TOML — the project's +tomlrb+ is
  # parse-only). Realpath normalization on both read and write collapses
  # symlink aliases and trailing slashes, so the list stays canonical and
  # human-auditable.
  #
  # == Residuals (consciously accepted, not bugs)
  #
  # * *Path-only trust.* A grant is keyed to the project-root path, never to
  #   a fingerprint of +.git/config+. A repo that turns hostile *after* it
  #   was trusted — e.g. a merged PR that adds a malicious +textconv+ — is
  #   NOT re-prompted. Config-fingerprinting was deliberately deferred (it
  #   re-prompts on every benign +.gitattributes+ edit). The trust prompt
  #   warns the user that trusting executes repo git config on every
  #   read-only git call.
  # * *No write lock.* Two instances trusting the same fresh repo
  #   concurrently could each append a line; the duplicate is harmless
  #   because {#trusted?} dedupes on read. Append-only (never rewrite) avoids
  #   the worse race of clobbering a concurrent writer.
  class TrustStore
    LOG = Pikuri.logger_for('trust')
    private_constant :LOG

    # @param path [Pathname, String] the trust-list file. Defaults to
    #   +trusted-projects+ under {Pikuri::Paths.state} (which auto-creates
    #   its directory). Injectable for specs.
    def initialize(path: Pikuri::Paths.state.join('trusted-projects'))
      @path = path.to_s
    end

    # @param project_root [Pathname, String] a project-root path; must
    #   exist (it is the chdir target at call time).
    # @return [Boolean] whether +project_root+ has been trusted. +false+
    #   when the file is missing/empty, when +project_root+ can't be
    #   resolved, or on any filesystem error (degrade to untrusted).
    def trusted?(project_root)
      target = realpath(project_root)
      return false if target.nil?

      trusted_paths.include?(target)
    end

    # Records +project_root+ as trusted (idempotent). Appends one canonical
    # line; a failed write degrades to untrusted-this-run (logged, never
    # raised) so a boot-time persistence failure can't tear down the
    # session.
    #
    # @param project_root [Pathname, String] the project root to trust.
    # @return [void]
    def trust!(project_root)
      target = realpath(project_root)
      return if target.nil? || trusted_paths.include?(target)

      File.write(@path, "#{target}\n", mode: 'a', perm: 0o600)
    rescue SystemCallError => e
      LOG.error("could not persist trust for #{@path}: #{e.message}")
    end

    private

    # @return [Set<String>] the realpath-normalized stored entries. A
    #   stored line that no longer resolves (deleted/moved repo) is skipped,
    #   not fatal — so one stale entry never poisons the lookup.
    def trusted_paths
      require 'set'
      lines =
        begin
          File.readlines(@path, chomp: true)
        rescue Errno::ENOENT
          []
        rescue SystemCallError => e
          LOG.error("could not read trust list #{@path}: #{e.message}")
          []
        end
      lines.each_with_object(Set.new) do |line, set|
        next if line.strip.empty?

        resolved = realpath(line)
        set << resolved if resolved
      end
    end

    # @param path [Pathname, String]
    # @return [String, nil] the canonical absolute path, or +nil+ if it
    #   can't be resolved (nonexistent / unreadable component).
    def realpath(path)
      File.realpath(path.to_s)
    rescue SystemCallError
      nil
    end
  end
end
