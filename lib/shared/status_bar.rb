# frozen_string_literal: true

require 'tuile'

# The always-visible bottom row: the two global keys, +^C+ first. With unread
# errors behind the menu it reads
#
#   ^C cancel  ^K ⚠ menu (2)
#
# Tuile draws no status bar and reserves no row for one (its +DECISIONS.md+
# +D-status-bar+), so this is an ordinary component, placed on the last row by
# {Shared::RootLayout}. The +^K+ half is a block so it can carry a live tally:
#
#   bar.menu_hint { "^K #{screen.theme.hint('menu')}" }
#   bar.refresh   # the tally changed; re-run it
#
# A block rather than assigned text is also what makes the row survive a
# light/dark flip: +theme.hint+ / +theme.error+ bake their colors in as they
# run, so {#on_theme_changed} just runs them again.
#
# +^C cancel+ is unconditional — every shell binds +Ctrl+C+. There is
# deliberately no +q quit+ segment: Tuile's loop still quits on an *unhandled*
# +q+, but the focused input consumes it in every pikuri shell, so advertising
# it would be a lie.
#
# UI-thread-confined.
class Shared::StatusBar < Tuile::Component::Label
  # Declares how the +^K+ half renders, and renders the row.
  #
  # @yieldreturn [String, Tuile::StyledString, nil] the hint as it reads *now*
  #   — the block re-runs on every {#refresh}, so read live state (the unread
  #   error tally, the theme) inside it. +nil+ or +""+ shows no hint at all.
  # @return [void]
  def menu_hint(&render)
    @menu_hint = render
    refresh
  end

  # Re-renders the row, re-running the {#menu_hint} block. Call it after
  # changing state that block reads.
  #
  # @return [void]
  def refresh
    hint = @menu_hint&.call
    row = ["^C #{screen.theme.error('cancel')}"]
    row << hint unless hint.nil? || hint.to_s.empty?
    self.text = row.join('  ')
  end

  # Re-renders against the new {Tuile::Screen#theme}, already in place when
  # this fires.
  #
  # @return [void]
  def on_theme_changed
    super
    refresh
  end
end
