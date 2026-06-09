# frozen_string_literal: true

require 'tuile'

module PikuriTui
  module Code
    # {Tuile::Component::Popup} wrapping the long-lived "Git diff" window —
    # the full, scrollable working-tree diff, rendered by {GitWatcher} through
    # {GitDiffRenderer} into the same two-tier inline form as the edit / write
    # tool calls. The sidebar's {GitWatcher} summary is only a per-file
    # +"+N -N"+ tally; the actual hunks are too wide for a 40%-width sidebar,
    # so they live here, shown near-fullscreen on +Ctrl+G+ instead.
    #
    # Like {LogPopup}, the wrapped window is constructed once and kept across
    # open/close cycles: {GitWatcher} writes the latest diff into its
    # +TextView+ on every poll whether or not the popup is open, so opening
    # it always shows current content. {Tuile::Component::Popup} re-parents
    # the window on each {#open}, which is why the same instance can be
    # reopened.
    #
    # The base +Popup+ auto-sizes to its content but caps {#max_height} at 12
    # rows — far too short for a diff. Overriding it to the screen height
    # lets +update_rect+'s 4/5-of-screen clamp take over, so the popup fills
    # most of the terminal and the wrapped +TextView+ scrolls within it.
    class GitDiffPopup < Tuile::Component::Popup
      # @param diff_window [Tuile::Component::Window] the framed, scrollable
      #   "Git diff" window this popup wraps. Its +TextView+ is owned and
      #   rewritten by {GitWatcher}; the popup only shows/hides it. Its
      #   parent is set to +self+ here — do not re-parent it elsewhere.
      def initialize(diff_window:)
        super(content: diff_window)
      end

      # The full diff dwarfs the base 12-row cap; allow growth to the screen
      # height so +Tuile::Component::Popup#update_rect+'s 4/5-of-screen clamp
      # decides the final size.
      #
      # @return [Integer]
      def max_height = screen.size.height
    end
  end
end
