# frozen_string_literal: true

require 'pikuri-core'
require 'tuile'

module Code
  # A working-tree diff as a {Tuile::Component::TextView}, in the two-tier
  # inline form {GitDiffRenderer} produces - a themed file header over
  # +@@ line N @@+ separators over inline-colored hunk bodies, the same family as
  # the edit / write tool diffs - or a placeholder when clean:
  #
  #   view = Code::GitDiffTextView.new
  #   view.snapshot = Code::GitWatcher::Snapshot.new(
  #     changes: [], diff_text: "diff --git a/x b/x\n@@ -1 +1 @@\n-old\n+new\n", error: nil)
  #   Tuile::Component::Dialog.new('Git diff', content: view).open
  #
  # The inline bars pad to the view's wrap width, so the retained snapshot
  # re-renders whenever that moves ({#relayout}) - a resize, or a host turning
  # the scrollbar on. Degrades to the raw plain diff (logged) if
  # {GitDiffRenderer} chokes on an unexpected diff shape, per
  # +D_tui_degrades_not_crashes+ ("external breakage is logged, we degrade").
  #
  # UI-thread-confined.
  class GitDiffTextView < Tuile::Component::TextView
    # Shown when there is no diff. Toned +:detail+ as placeholder chrome.
    #
    # @return [String]
    PLACEHOLDER = '(no changes)'

    LOG = Pikuri.logger_for('git')
    private_constant :LOG

    def initialize
      super
      @snapshot = nil
      @rendered_at = nil
    end

    # Shows a git snapshot, rendered at the next {#relayout} where the width is
    # settled, and retained so a later resize re-renders it. Ignores the
    # snapshot's change list (that's the {GitSummaryPane}'s half).
    #
    # @param snapshot [GitWatcher::Snapshot]
    # @return [void]
    def snapshot=(snapshot)
      @snapshot = snapshot
      @rendered_at = nil
      invalidate_layout
    end

    protected

    # Re-renders the retained snapshot once {#render_width} has moved off the
    # width it was rendered at - before +super+, so the text it sets is wrapped
    # in this same pass.
    #
    # @return [void]
    def relayout
      rerender unless @rendered_at == render_width
      super
    end

    private

    # @return [void]
    def rerender
      @rendered_at = render_width
      self.text =
        if @snapshot&.error
          screen.theme.detail(@snapshot.error)
        elsif @snapshot.nil? || @snapshot.diff_text.empty?
          screen.theme.detail(PLACEHOLDER)
        else
          render_diff(@snapshot.diff_text)
        end
    end

    # @param raw [String] combined plain +git diff+ output.
    # @return [String] the two-tier inline ANSI diff, or the raw text on a
    #   renderer failure (logged).
    def render_diff(raw)
      GitDiffRenderer.render(raw, theme: screen.theme, max_width: render_width)
    rescue StandardError => e
      LOG.error("git diff render failed: #{e.class}: #{e.message}")
      raw
    end

    # The columns a row may fill before it wraps (TextView's +wrap_width+, which
    # already leaves the scrollbar's columns out), floored at 1 so a closed
    # dialog's zero-width view still renders.
    #
    # @return [Integer]
    def render_width = [wrap_width, 1].max
  end
end
