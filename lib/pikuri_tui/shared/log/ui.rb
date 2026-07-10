# frozen_string_literal: true

require 'logger'
require 'pikuri-core'
require 'tuile'

# The diagnostic-log subsystem shared by all three shells: the eager
# +LogWindow+, its {Shared::Log::Popup}, the {Shared::Log::CountingIO} that routes every
# pikuri / Tuile log line into that window, the unread-error tally, and
# the +Ctrl+K+ leader-menu global shortcut whose status-bar hint carries
# that tally.
#
# Extracted from the byte-identical +wire_logging+ / +menu_hint+ /
# error-counter cluster the three +App+s used to each carry. The +App+
# keeps only the two seams that genuinely differ: *what* +Ctrl+K+ does
# (its own {Shared::LeaderMenu}, supplied to {#install_shortcut}) and *when* the
# two phases fire (wire early, before the agent is built; install the
# shortcut late, once the menu exists).
#
# == Why registration lives here, not in the App
#
# The error tally is surfaced *only* through the +Ctrl+K+ hint (it is the
# single always-visible status-bar surface), and {Tuile::Screen} refreshes
# a shortcut's hint by re-registering the binding in place. So bumping the
# counter and refreshing the hint are the same act — {#on_error_logged} and
# {#reset_error_count} both re-run {#install_shortcut}. That coupling is why
# the +Ctrl+K+ registration belongs to this class and not to the App's
# +register_shortcuts+ (which keeps the genuinely shell-agnostic +Ctrl+C+).
#
# == Threading
#
# {#on_error_logged} fires on the *logging* thread (any thread), so it
# marshals the counter mutation + hint refresh onto the event-loop thread
# via +screen.event_queue.submit+. Every other method is called on the UI
# thread (construction, leader-menu dispatch, popup dismissal).
class Shared::Log::UI
  # @return [Tuile::Component::LogWindow] the eager-constructed diagnostic
  #   window. Exposed so the App can re-expose it (tests, extra logger sinks).
  attr_reader :log_window

  # @return [Shared::Log::Popup] the popup wrapping {#log_window}, opened by the
  #   leader menu's +l+ entry (via {#open}).
  attr_reader :log_popup

  # @param screen [Tuile::Screen] the (already-installed) screen this app
  #   runs on. Used for the theme (hint colors), the event queue (marshaling),
  #   and the global-shortcut registry.
  def initialize(screen:)
    @screen = screen
    @error_count = 0
    @log_window = Tuile::Component::LogWindow.new('Log')
    @log_popup = Shared::Log::Popup.new(log_window: @log_window, on_dismiss: method(:reset_error_count))
  end

  # Routes every pikuri / Tuile log line — and any exception trapped
  # by {Tuile::Screen#on_error} — through a single {Shared::Log::CountingIO}
  # that both renders into {#log_window} and bumps the error counter
  # backing the +Ctrl+K+ menu status-bar hint. Must run after
  # construction and before the agent is built (the agent's
  # construction can already log).
  #
  # If the boot sink was a {Shared::Log::BufferingIO} (the bins install one as the
  # pre-screen +Pikuri.log_io+), its retained pre-screen lines are replayed
  # through the new {Shared::Log::CountingIO} *after* the swap — so the config-file
  # reads, +chmod 600+ advisories and model-wiring lines that only hit
  # +$stderr+ at boot now appear in the diagnostic pane, error lines among
  # them bumping the counter just like a live write.
  #
  # @return [void]
  def wire!
    io = Shared::Log::CountingIO.new(log_window: @log_window, on_error: method(:on_error_logged))
    prior = Pikuri.log_io
    Tuile.logger = Logger.new(io)
    Pikuri.log_io = io
    prior.replay_into(io) if prior.respond_to?(:replay_into)
  end

  # (Re-)registers the +Ctrl+K+ leader-menu global shortcut with a
  # status-bar hint that reflects the current error count. {Tuile::Screen}
  # replaces the binding in place on re-register, so this is also how the
  # hint stays in sync with the counter — {#on_error_logged} and
  # {#reset_error_count} both call back here (without a block) after touching
  # the count.
  #
  # @yield the +Ctrl+K+ action — opening the App's {Shared::LeaderMenu}. Captured on
  #   the first call (from the App's +register_shortcuts+) and reused on every
  #   hint-refresh re-registration. Omit it to re-register with the remembered
  #   block.
  # @return [void]
  def install_shortcut(&open_menu)
    @open_menu = open_menu if open_menu
    @screen.register_global_shortcut(Tuile::Keys::CTRL_K, hint: menu_hint, &@open_menu)
  end

  # Opens the log popup (the leader menu's +l+ action). A no-op if it is
  # already open. Runs on the event-loop thread (global-shortcut dispatch).
  #
  # @return [void]
  def open
    return if @log_popup.open?

    @log_popup.open
  end

  private

  # Called by {Shared::Log::CountingIO} on every error-class log write. The callback
  # fires on the *logging* thread (any thread), so the counter mutation and
  # hint refresh are marshaled to the event-loop thread via +submit+.
  #
  # @param _line [String] the offending log line (ignored — we only need the
  #   count).
  # @return [void]
  def on_error_logged(_line)
    @screen.event_queue.submit do
      @error_count += 1
      install_shortcut
    end
  end

  # Fires when the log popup is dismissed (ESC / q from inside the popup):
  # the user has now read the diagnostics. Runs on the event-loop thread, so
  # direct mutation is safe.
  #
  # @return [void]
  def reset_error_count
    @error_count = 0
    install_shortcut
  end

  # The status-bar hint advertised for +Ctrl+K+. The plain "menu" variant
  # uses the theme's +hint_color+, matching the Tuile-supplied "q quit" /
  # "q Close" styling; the warning variant uses the theme's +:error+ token to
  # foreground the unread-error tally so the user notices something broke (and
  # that the logs behind the menu are worth opening) without us writing log
  # lines into the conversation pane.
  #
  # Pure read of the counter; all callers are on the event-loop thread.
  #
  # @return [String]
  def menu_hint
    if @error_count.zero?
      "^K #{@screen.theme.hint('menu')}"
    else
      "^K #{@screen.theme.error("⚠ menu (#{@error_count})")}"
    end
  end
end
