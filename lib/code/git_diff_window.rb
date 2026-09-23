# frozen_string_literal: true

require 'pikuri-core'
require 'tuile'

module Code
  # The "Git diff" pane (wrapped by {GitDiffPopup}): a {Tuile::Component::Window}
  # that renders a working-tree diff in the two-tier inline form {GitDiffRenderer}
  # produces - a themed file header over +@@ line N @@+ separators over
  # inline-colored hunk bodies, the same family as the edit / write tool diffs -
  # or a placeholder when clean. A {GitWatcher::Snapshot} arrives through
  # {#snapshot=} (produced by the {GitWatcher} service).
  #
  #   pane = Code::GitDiffWindow.new
  #   pane.snapshot = Code::GitWatcher::Snapshot.new(
  #     changes: [], diff_text: "diff --git a/x b/x\n@@ -1 +1 @@\n-old\n+new\n", error: nil)
  #
  # The inline bars pad to the pane width, so the retained snapshot re-renders at
  # the new width on resize ({#relayout}). Degrades to the raw plain diff
  # (logged) if {GitDiffRenderer} chokes on an unexpected diff shape, per
  # +D_tui_degrades_not_crashes+ ("external breakage is logged, we degrade"). A domain component built
  # by subclassing the generic {Tuile::Component::Window}.
  #
  # UI-thread-confined (the {WorkspaceSidebar} subscription marshals {#snapshot=}
  # onto the UI thread; {#relayout} already runs on it).
  class GitDiffWindow < Tuile::Component::Window
    # Shown when there is no diff. Toned +:detail+ as placeholder chrome.
    #
    # @return [String]
    PLACEHOLDER = '(no changes)'

    LOG = Pikuri.logger_for('git')
    private_constant :LOG

    # Frames a fresh scrollable text view captioned "Git diff".
    def initialize
      super('Git diff')
      @snapshot = nil
      @rendered_at = nil
      @view = Tuile::Component::TextView.new
      self.content = @view
      self.scrollbar = true
    end

    # @return [Tuile::Component::TextView] the framed content view; exposed for tests.
    attr_reader :view

    # Rewrite the pane from a git snapshot, rendered at the next {#relayout}
    # where the width is settled (and retained so a later resize can re-render
    # at the new width). Ignores the snapshot's change list (that's the
    # {GitSummaryPane}'s half). Must run on the UI thread.
    #
    # @param snapshot [GitWatcher::Snapshot]
    # @return [void]
    def snapshot=(snapshot)
      @snapshot = snapshot
      @rendered_at = nil
      invalidate_layout
    end

    protected

    # Re-render the retained snapshot once {#max_width} has moved off the width
    # it was rendered at - the inline bars pad to it. Keyed on the width because
    # this runs after every layout mark, a height-only resize included.
    #
    # @return [void]
    def relayout
      rerender unless @rendered_at == max_width
      super
    end

    private

    # @return [void]
    def rerender
      @rendered_at = max_width
      @view.text =
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
      GitDiffRenderer.render(raw, theme: screen.theme, max_width: max_width)
    rescue StandardError => e
      LOG.error("git diff render failed: #{e.class}: #{e.message}")
      raw
    end

    # Content text width for the rendered bars: the window width less its left
    # border and the two columns the scrollbar claims (it takes the right
    # border's column), floored at 1 so a not-yet-laid-out pane (width 0, e.g.
    # while the popup is closed) still renders - {#relayout} redraws at the
    # real width once the popup lays the pane out.
    #
    # @return [Integer]
    def max_width = [rect.width - 3, 1].max
  end
end
