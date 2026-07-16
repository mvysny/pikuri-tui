# frozen_string_literal: true

require 'pikuri-core'
require 'tuile'

module Code
  # The "Git diff" pane (lives inside {GitDiffPopup}): a
  # {Tuile::Component::TextView} subclass that owns *how a working-tree diff is
  # drawn* — the two-tier inline form {GitDiffRenderer} produces (a themed file
  # header over +@@ line N @@+ separators over inline-colored hunk bodies, the
  # same family as the edit / write tool diffs), or a placeholder when clean.
  # The raw plain +git diff+ text arrives through {#diff=}; {GitWatcher} (the
  # shared poll-thread model) produces it.
  #
  #   view = Code::GitDiffTextView.new
  #   view.diff = "diff --git a/x b/x\n@@ -1 +1 @@\n-old\n+new\n"
  #
  # The view owns rendering, which includes re-rendering at the new width when
  # the pane resizes ({#on_width_changed}) — the inline bars pad to the pane
  # width, so it must retain the raw diff and redraw. Degrades to the raw plain
  # diff (logged) if {GitDiffRenderer} chokes on an unexpected diff shape, per
  # CLAUDE.md's "external breakage is logged, we degrade".
  #
  # UI-thread-confined ({GitWatcher} marshals {#diff=} / {#notice=} onto the UI
  # thread; {#on_width_changed} already fires on it).
  class GitDiffTextView < Tuile::Component::TextView
    # Shown when there is no diff. Toned +:detail+ as placeholder chrome.
    #
    # @return [String]
    PLACEHOLDER = '(no changes)'

    LOG = Pikuri.logger_for('git')
    private_constant :LOG

    def initialize
      super()
      @raw = nil
      @notice = nil
    end

    # Rewrite the pane from raw plain +git diff+ text (an empty string = clean
    # tree → {PLACEHOLDER}). The raw text is retained so a later resize can
    # re-render at the new width. Must run on the UI thread.
    #
    # @param raw [String] combined plain +git diff+ output.
    # @return [void]
    def diff=(raw)
      @notice = nil
      @raw = raw
      rerender
    end

    # Show a one-line degraded notice instead of a diff (e.g. git could not be
    # launched). Persists across resizes until the next {#diff=}.
    #
    # @param message [String]
    # @return [void]
    def notice=(message)
      @notice = message
      rerender
    end

    # Re-render the retained diff at the new pane width — the inline bars pad to
    # {#max_width}, which tracks +rect.width+.
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
        if @notice
          screen.theme.detail(@notice)
        elsif @raw.nil? || @raw.empty?
          screen.theme.detail(PLACEHOLDER)
        else
          render_diff(@raw)
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
