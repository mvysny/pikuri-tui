# frozen_string_literal: true

module Code
  # Remembers whether a project holds private data, so the question is asked
  # once ever rather than once per launch. Ask only when there is no answer yet:
  #
  #   store  = Code::PrivacyStore.new
  #   answer = store.answer(project_root)     # nil => never asked
  #   if answer.nil? && $stdin.tty?
  #     answer = confirmer.confirm?(request: privacy_question)
  #     store.record!(project_root, private: answer)
  #   end
  #
  # The answer feeds one thing: +Pikuri::Workspace::Filesystem+'s +private:+,
  # i.e. the lethal-trifecta detector's private leg — the one leg the framework
  # cannot work out for itself, since sensitivity is a property of the data and
  # nothing distinguishes +~/work/my/pikuri+ from +~/work/client-payroll+ by
  # inspection. Nothing is *gated* on it: it changes what the +/trifecta+ report
  # says, never what the agent may do.
  #
  # The file — +private <path>+ / +public <path>+ lines under
  # {Pikuri::Paths.state}, append-only, realpath-normalized on read and write —
  # is plain text so a changed mind can be edited in.
  #
  # == Implementation details
  #
  # Deliberately not folded into {TrustStore}: that one is a set of *grants*
  # (absent means no grant) gating execution, this is a *tri-state answer*
  # gating a report, and the whole point of persisting a +no+ is to stop
  # re-asking — which a set cannot express.
  #
  # Two residuals, consciously accepted:
  #
  # * *A stale "public" stays quiet.* A project answered +public+ before it
  #   gained credentials is never re-asked, so its report keeps reading two
  #   legs. That is the cost of asking once per project rather than once per
  #   session, and the reason the file invites hand-editing.
  # * *No write lock.* Two instances answering for the same fresh project could
  #   each append a line. Harmless: {#answer} takes the last line for a path, so
  #   a later answer wins, and append-only avoids the worse race of clobbering a
  #   concurrent writer.
  class PrivacyStore
    # @return [Logger]
    LOG = Pikuri.logger_for('privacy')
    private_constant :LOG

    # @param path [Pathname, String] the answer-list file. Defaults to
    #   +private-projects+ under {Pikuri::Paths.state} (which auto-creates its
    #   directory). Injectable for specs.
    def initialize(path: Pikuri::Paths.state.join('private-projects'))
      @path = path.to_s
    end

    # @param project_root [Pathname, String] a project-root path; must exist (it
    #   is the chdir target at call time).
    # @return [Boolean, nil] the recorded answer, or +nil+ when this project has
    #   never been asked — which is also what a missing/unreadable file or an
    #   unresolvable +project_root+ degrades to, so the caller asks again rather
    #   than assuming either reading.
    def answer(project_root)
      target = realpath(project_root)
      return nil if target.nil?

      answers[target]
    end

    # Records the answer for +project_root+ (idempotent — a repeat of the
    # already-stored answer writes nothing). A failed write degrades to
    # not-persisted (logged, never raised) so a boot-time persistence failure
    # can't tear down the session; the worst case is being asked again next run.
    #
    # @param project_root [Pathname, String] the project root the answer is about.
    # @param private [Boolean] whether it holds data the user would mind leaking.
    # @return [void]
    def record!(project_root, private:)
      target = realpath(project_root)
      return if target.nil? || answers[target] == private

      File.write(@path, "#{private ? 'private' : 'public'} #{target}\n", mode: 'a', perm: 0o600)
    rescue SystemCallError => e
      LOG.error("could not persist the privacy answer to #{@path}: #{e.message}")
    end

    private

    # @return [Hash{String=>Boolean}] the realpath-normalized answers, last line
    #   winning for a repeated path. A malformed line, or one whose path no
    #   longer resolves (deleted/moved project), is skipped rather than fatal —
    #   one stale entry never poisons the lookup.
    def answers
      lines =
        begin
          File.readlines(@path, chomp: true)
        rescue Errno::ENOENT
          []
        rescue SystemCallError => e
          LOG.error("could not read the privacy list #{@path}: #{e.message}")
          []
        end
      lines.each_with_object({}) do |line, map|
        verdict, path = line.split(' ', 2)
        next unless %w[private public].include?(verdict) && path

        resolved = realpath(path)
        map[resolved] = verdict == 'private' if resolved
      end
    end

    # @param path [Pathname, String]
    # @return [String, nil] the canonical absolute path, or +nil+ if it can't be
    #   resolved (nonexistent / unreadable component).
    def realpath(path)
      File.realpath(path.to_s)
    rescue SystemCallError
      nil
    end
  end
end
