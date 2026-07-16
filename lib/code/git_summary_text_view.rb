# frozen_string_literal: true

require 'pikuri-core'
require 'tuile'

module Code
  # The sidebar "Changes" pane: a {Tuile::Component::TextView} subclass that
  # owns *how a git change summary is drawn* — one +"XY path  +A -D"+ line per
  # changed file, the label toned by change kind (new green, deleted red,
  # modified yellow) and the +/- markers green/red, a degraded notice when git
  # failed, or a placeholder when the tree is clean. A {GitWatcher::Snapshot}
  # arrives through {#snapshot=}, produced by the {GitWatcher} service; the view
  # owns rendering, the service owns polling and data — the data-in split (see
  # the `cop` skill).
  #
  #   view = Code::GitSummaryTextView.new
  #   view.snapshot = Code::GitWatcher::Snapshot.new(
  #     changes: [Code::GitWatcher::Change.new(code: 'M', path: 'a.rb', added: 2, deleted: 1)],
  #     diff_text: '…', error: nil)
  #   # => "M a.rb  +2 -1"  (themed)
  #
  # Width-independent (one line per file, no reflow), so unlike
  # {GitDiffTextView} it needs no resize hook.
  #
  # UI-thread-confined (the {Code::App} listener marshals {#snapshot=} onto the
  # UI thread before calling it).
  class GitSummaryTextView < Tuile::Component::TextView
    # Shown when the working tree matches HEAD. Toned +:detail+ as placeholder chrome.
    #
    # @return [String]
    PLACEHOLDER = '(no changes)'

    # The two-letter porcelain code for an untracked file (its coloring cue).
    #
    # @return [String]
    UNTRACKED_CODE = '??'

    # Rewrite the pane from a git snapshot: the degraded notice when git failed,
    # the {PLACEHOLDER} when the tree is clean, else one styled line per changed
    # file. Ignores the snapshot's diff (that's the {GitDiffTextView}'s half).
    # Must run on the UI thread.
    #
    # @param snapshot [GitWatcher::Snapshot]
    # @return [void]
    def snapshot=(snapshot)
      self.text =
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
