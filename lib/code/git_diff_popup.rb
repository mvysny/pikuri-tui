# frozen_string_literal: true

require 'tuile'

module Code
  # {Tuile::Component::Popup} wrapping the long-lived "Git diff" window —
  # the full, scrollable working-tree diff, rendered by {GitWatcher} through
  # {GitDiffRenderer} into the same two-tier inline form as the edit / write
  # tool calls. The sidebar's {GitWatcher} summary is only a per-file
  # +"+N -N"+ tally; the actual hunks are too wide for a 40%-width sidebar,
  # so they live here, shown near-fullscreen from the leader menu's +d+
  # entry instead.
  #
  # Like {Shared::Log::Popup}, the wrapped window is constructed once and kept across
  # open/close cycles: {GitWatcher} writes the latest diff into its
  # +TextView+ on every poll whether or not the popup is open, so opening
  # it always shows current content. {Tuile::Component::Popup} re-parents
  # the window on each {#open}, which is why the same instance can be
  # reopened.
  #
  # A diff needs room, so the popup is sized {Tuile::Fraction::FULL}
  # (fullscreen) rather than the default half-screen; the wrapped +TextView+
  # scrolls within it.
  #
  # UI-thread-confined.
  class GitDiffPopup < Tuile::Component::Popup
    # @param diff_window [Tuile::Component::Window] the framed, scrollable
    #   "Git diff" window this popup wraps. Its +TextView+ is owned and
    #   rewritten by {GitWatcher}; the popup only shows/hides it. Its
    #   parent is set to +self+ here — do not re-parent it elsewhere.
    def initialize(diff_window:)
      super(content: diff_window, size: Tuile::Fraction::FULL)
    end
  end
end
