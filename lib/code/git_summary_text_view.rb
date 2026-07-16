# frozen_string_literal: true

require 'pikuri-core'
require 'tuile'

module Code
  # The sidebar "Changes" pane: a {Tuile::Component::TextView} subclass that
  # owns *how a git change summary is drawn* — one +"XY path  +A -D"+ line per
  # changed file, the label toned by change kind (new green, deleted red,
  # modified yellow) and the +/- markers green/red, or a placeholder when the
  # tree is clean. Data arrives through {#changes=} as {Change} value objects;
  # {GitWatcher} (the shared poll-thread model feeding this pane and the
  # {GitDiffTextView}) produces them. The view owns rendering, the watcher owns
  # polling and data — the data-in split (see the `cop` skill).
  #
  #   view = Code::GitSummaryTextView.new
  #   view.changes = [Code::GitSummaryTextView::Change.new(code: 'M', path: 'a.rb', added: 2, deleted: 1)]
  #   # => "M a.rb  +2 -1"  (themed)
  #
  # Width-independent (one line per file, no reflow), so unlike
  # {GitDiffTextView} it needs no resize hook.
  #
  # UI-thread-confined ({GitWatcher} marshals {#changes=} / {#notice=} onto the
  # UI thread before calling them).
  class GitSummaryTextView < Tuile::Component::TextView
    # Shown when the working tree matches HEAD. Toned +:detail+ as placeholder chrome.
    #
    # @return [String]
    PLACEHOLDER = '(no changes)'

    # The two-letter porcelain code for an untracked file.
    #
    # @return [String]
    UNTRACKED_CODE = '??'

    # One changed file's summary data: its two-letter +git status+ porcelain
    # +code+, its +path+, and the +added+ / +deleted+ line counts. The data
    # contract {#changes=} accepts; {GitWatcher} produces these.
    Change = Data.define(:code, :path, :added, :deleted)

    # Rewrite the pane from a change snapshot: the {PLACEHOLDER} when empty,
    # else one styled line per file. Must run on the UI thread.
    #
    # @param changes [Array<Change>] one per changed file, in git's order.
    # @return [void]
    def changes=(changes)
      self.text =
        if changes.empty?
          screen.theme.detail(PLACEHOLDER)
        else
          changes.map { |change| summary_line(change) }.join("\n")
        end
    end

    # Show a one-line degraded notice instead of a summary (e.g. git could not
    # be launched). The message is data from {GitWatcher}; the +:detail+ tone is
    # ours.
    #
    # @param message [String]
    # @return [void]
    def notice=(message)
      self.text = screen.theme.detail(message)
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
