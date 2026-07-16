# frozen_string_literal: true

require 'pikuri-core'
require 'tuile'

module Code
  # The "Git diff" pane (lives inside {GitDiffPopup}): a
  # {Tuile::Component::TextView} subclass that owns *how a working-tree diff is
  # drawn* — the two-tier inline form {GitDiffRenderer} produces (a themed file
  # header over +@@ line N @@+ separators over inline-colored hunk bodies, the
  # same family as the edit / write tool diffs), or a placeholder when clean.
  # A {GitWatcher::Snapshot} arrives through {#snapshot=}; the {GitWatcher}
  # service produces it.
  #
  #   view = Code::GitDiffTextView.new
  #   view.snapshot = Code::GitWatcher::Snapshot.new(
  #     changes: [], diff_text: "diff --git a/x b/x\n@@ -1 +1 @@\n-old\n+new\n", error: nil)
  #
  # The view owns rendering, which includes re-rendering at the new width when
  # the pane resizes ({#on_width_changed}) — the inline bars pad to the pane
  # width, so it must retain the snapshot and redraw. Degrades to the raw plain
  # diff (logged) if {GitDiffRenderer} chokes on an unexpected diff shape, per
  # CLAUDE.md's "external breakage is logged, we degrade".
  #
  # UI-thread-confined (the {Code::App} listener marshals {#snapshot=} onto the
  # UI thread; {#on_width_changed} already fires on it).
  class GitDiffTextView < Tuile::Component::TextView
    # Shown when there is no diff. Toned +:detail+ as placeholder chrome.
    #
    # @return [String]
    PLACEHOLDER = '(no changes)'

    LOG = Pikuri.logger_for('git')
    private_constant :LOG

    def initialize
      super()
      @snapshot = nil
    end

    # Rewrite the pane from a git snapshot (retained so a later resize can
    # re-render at the new width). Ignores the snapshot's change list (that's
    # the {GitSummaryTextView}'s half). Must run on the UI thread.
    #
    # @param snapshot [GitWatcher::Snapshot]
    # @return [void]
    def snapshot=(snapshot)
      @snapshot = snapshot
      rerender
    end

    # Re-render the retained snapshot at the new pane width — the inline bars pad
    # to {#max_width}, which tracks +rect.width+.
    #
    # @return [void]
    def on_width_changed
      super
      rerender
    end

    private

    # @return [void]
    def rerender
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
      GitDiffRenderer.render(raw, theme: screen.theme, max_width: max_width)
    rescue StandardError => e
      LOG.error("git diff render failed: #{e.class}: #{e.message}")
      raw
    end

    # Pane-width cap for the rendered bars: the pane's width less the scrollbar
    # gutter, floored at 1 so a not-yet-laid-out pane (width 0, e.g. while the
    # popup is closed) still renders — {#on_width_changed} redraws at the real
    # width once the popup lays the pane out. Same idiom as
    # {Shared::ConversationTextView#buffer_width}.
    #
    # @return [Integer]
    def max_width = [rect.width - 2, 1].max
  end
end
