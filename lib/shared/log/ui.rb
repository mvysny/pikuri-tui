# frozen_string_literal: true

require 'logger'
require 'pikuri-core'
require 'tuile'

# The diagnostic-log subsystem shared by all three shells: the eager
# {Shared::Log::Dialog}, the {Shared::Log::CountingIO} that routes every
# pikuri / Tuile log line into it, the unread-error
# tally, and the +Ctrl+K+ leader-menu global shortcut whose status-bar hint
# carries that tally. Wired in two phases:
#
#   log_ui = Shared::Log::UI.new(screen: screen, status_bar: bar)
#   log_ui.wire!                                  # early: route logs here (pre-agent)
#   # ... build the agent and the leader menu ...
#   log_ui.install_shortcut { leader_menu.open }  # late: Ctrl+K opens the menu
#
# The +App+ supplies only the two seams that differ: *what* +Ctrl+K+ does
# (its own {Shared::LeaderMenu}) and *when* the phases fire — wire early,
# before the agent is built; install the shortcut once the menu exists.
#
# == Why the tally lives here, not in the App
#
# The error tally is surfaced *only* through the status bar's +^K+ hint — it is
# the single always-visible surface — so the counter and the block that renders
# it ({#menu_hint}, handed to the bar at construction) belong together. That
# coupling is why the +Ctrl+K+ binding lives here and not in the App's
# +register_shortcuts+ (which keeps the genuinely shell-agnostic +Ctrl+C+).
#
# UI-thread-confined, with exceptions.
class Shared::Log::UI
  # @return [Shared::Log::Dialog] the eager-constructed diagnostic log, opened
  #   by the leader menu's +l+ entry (via {#open}). Exposed so the App can
  #   re-expose it (tests, extra logger sinks).
  attr_reader :log_dialog

  # @param screen [Tuile::Screen] the (already-installed) screen this app
  #   runs on. Used for the theme (hint colors), the event queue (marshaling),
  #   and the global-shortcut registry.
  # @param status_bar [Shared::StatusBar] the shell's bottom row; this class
  #   supplies its +^K+ hint and nothing else on it.
  def initialize(screen:, status_bar:)
    @screen = screen
    @status_bar = status_bar
    @error_count = 0
    @log_dialog = Shared::Log::Dialog.new(on_dismiss: method(:reset_error_count))
    @status_bar.menu_hint(&method(:menu_hint))
  end

  # Routes every pikuri / Tuile log line — and any exception trapped
  # by {Tuile::Screen#on_error} — through a single {Shared::Log::CountingIO}
  # that both renders into {#log_dialog} and bumps the error counter
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
    io = Shared::Log::CountingIO.new(log_dialog: @log_dialog, on_error: method(:on_error_logged))
    prior = Pikuri.log_io
    Tuile.logger = Logger.new(io)
    Pikuri.log_io = io
    prior.replay_into(io) if prior.respond_to?(:replay_into)
  end

  # Registers the +Ctrl+K+ leader-menu global shortcut, once. The hint text
  # beside it is {#menu_hint}'s business, not this method's.
  #
  # @yield the +Ctrl+K+ action — opening the App's {Shared::LeaderMenu}.
  # @return [void]
  def install_shortcut(&open_menu)
    @open_menu = open_menu if open_menu
    @screen.register_global_shortcut(Tuile::Keys::CTRL_K, &@open_menu)
  end

  # Opens the log dialog (the leader menu's +l+ action). A no-op if it is
  # already open.
  #
  # @return [void]
  def open
    return if @log_dialog.open?

    @log_dialog.open
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
      @status_bar.refresh
    end
  end

  # Fires when the log dialog is dismissed (ESC / q from inside it):
  # the user has now read the diagnostics. Runs on the event-loop thread, so
  # direct mutation is safe.
  #
  # @return [void]
  def reset_error_count
    @error_count = 0
    @status_bar.refresh
  end

  # The status bar's +^K+ hint. The plain "menu" variant uses the theme's
  # +:hint+; the warning variant uses +:error+ to foreground the unread
  # tally so the user notices something broke (and that the logs behind the
  # menu are worth opening) without us writing log lines into the
  # conversation pane.
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
