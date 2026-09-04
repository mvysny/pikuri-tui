# frozen_string_literal: true

require 'pikuri-core'
require 'tuile'

module Code
  # The sidebar "Changes" pane: a borderless
  # {Tuile::Component::Layout::Vertical} stacking a {Shared::PaneCaptionLabel}
  # over a git change summary it renders itself - one +"XY path  +A -D"+ line
  # per changed file, the label toned by change kind (new green, deleted red,
  # modified yellow) and the +/- markers green/red, a degraded notice when git
  # failed, a placeholder when the tree is clean. A {GitWatcher::Snapshot}
  # arrives through {#snapshot=} (produced by the {GitWatcher} service); the
  # pane owns rendering, the service owns polling and data - the data-in split
  # (see the `cop` skill).
  #
  #   pane = Code::GitSummaryPane.new
  #   pane.snapshot = Code::GitWatcher::Snapshot.new(
  #     changes: [Code::GitWatcher::Change.new(code: 'M', path: 'a.rb', added: 2, deleted: 1)],
  #     diff_text: '…', error: nil)
  #   # => renders "M a.rb  +2 -1"  (themed) under a "Changes" caption
  #
  # A domain component built by subclassing a generic Tuile container and
  # rendering into its own content view: the coding shell's git-changes pane is
  # one unit, not a render-only view hand-captioned by its host. Sits on the
  # sidebar's +:pane_bg+ tint, inherited from {WorkspaceSidebar}.
  #
  # UI-thread-confined (the {WorkspaceSidebar} subscription marshals {#snapshot=}
  # onto the UI thread before calling it).
  class GitSummaryPane < Tuile::Component::Layout::Vertical
    # Shown when the working tree matches HEAD. Toned +:detail+ as placeholder chrome.
    #
    # @return [String]
    PLACEHOLDER = '(no changes)'

    # The two-letter porcelain code for an untracked file (its coloring cue).
    #
    # @return [String]
    UNTRACKED_CODE = '??'

    # The pane's caption row.
    #
    # @return [String]
    CAPTION = 'Changes'

    # Stacks a "Changes" caption row over a fresh scrollable text view.
    def initialize
      super()
      @view = Shared::PassiveTextView.new
      # No scrollbar — see the note in {TaskListPane}: nothing in the sidebar
      # takes focus, so a bar here would be inoperable decoration.
      add(Shared::PaneCaptionLabel.new(CAPTION), Fixed[1])
      add(@view, Expand[1])
    end

    # @return [Shared::PassiveTextView] the content view under the caption;
    #   exposed for tests, production drives it through {#snapshot=}.
    attr_reader :view

    # Rewrite the pane from a git snapshot: the degraded notice when git failed,
    # the {PLACEHOLDER} when the tree is clean, else one styled line per changed
    # file. Ignores the snapshot's diff (that's the {GitDiffWindow}'s half). Must
    # run on the UI thread.
    #
    # @param snapshot [GitWatcher::Snapshot]
    # @return [void]
    def snapshot=(snapshot)
      @view.text =
        if snapshot.error
          screen.theme.detail(snapshot.error)
        elsif snapshot.changes.empty?
          screen.theme.detail(PLACEHOLDER)
        else
          snapshot.changes.map { |change| summary_line(change) }.join("\n")
        end
    end

    private

    # @param change [Change]
    # @return [String] +"XY path  +A -D"+ with a themed label and +/- markers.
    def summary_line(change)
      markers = []
      markers << screen.theme.added("+#{change.added}") if change.added.positive?
      markers << screen.theme.removed("-#{change.deleted}") if change.deleted.positive?
      label = colorize_label("#{change.code} #{change.path}", change.code)
      markers.empty? ? label : "#{label}  #{markers.join(' ')}"
    end

    # Tones the +"XY path"+ label by change kind so the list scans at a glance:
    # a +D+ in either column is a deletion (red), an +A+ or the untracked +??+
    # is new (green), everything else (+M+, +MM+, …) is a modification (yellow).
    #
    # @param label [String] the +"XY path"+ text to color.
    # @param code [String] the two-letter porcelain status code.
    # @return [String]
    def colorize_label(label, code)
      if code.include?('D')
        screen.theme.removed(label)
      elsif code == UNTRACKED_CODE || code.include?('A')
        screen.theme.added(label)
      else
        screen.theme.notice(label)
      end
    end
  end
end
