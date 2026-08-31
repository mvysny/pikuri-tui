# frozen_string_literal: true

require 'tuile'

module Code
  # {Tuile::Component::Popup} wrapping the long-lived {GitDiffWindow} —
  # the full, scrollable working-tree diff, rendered into the same two-tier
  # inline form as the edit / write tool calls. The sidebar's {GitSummaryPane}
  # shows only a per-file +"+N -N"+ tally; the actual hunks are too wide for a
  # 40%-width sidebar, so they live here, shown near-fullscreen from the leader
  # menu's +d+ entry instead.
  #
  # Like {Shared::Log::Popup}, the wrapped window is constructed once and kept across
  # open/close cycles: {GitWatcher} feeds the latest diff into the
  # {GitDiffWindow} on every poll whether or not the popup is open, so
  # opening it always shows current content. {Tuile::Component::Popup}
  # re-parents the window on each {#open}, which is why the same instance can
  # be reopened.
  #
  # A diff needs room, so the popup is sized {Tuile::Fraction::FULL}
  # (fullscreen) rather than the default half-screen; the wrapped +TextView+
  # scrolls within it.
  #
  # UI-thread-confined.
  class GitDiffPopup < Tuile::Component::Popup
    # @param diff_window [GitDiffWindow] the "Git diff" pane this popup wraps,
    #   fed by {GitWatcher}; the popup only shows/hides it. Its parent is set
    #   to +self+ here — do not re-parent it elsewhere.
    def initialize(diff_window:)
      super(content: diff_window, declared_size: Tuile::Fraction::FULL)
    end
  end
end
