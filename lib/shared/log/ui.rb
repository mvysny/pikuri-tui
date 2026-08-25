# frozen_string_literal: true

require 'logger'
require 'pikuri-core'
require 'tuile'

# The diagnostic-log subsystem shared by all three shells: the eager
# +LogWindow+, its {Shared::Log::Popup}, the {Shared::Log::CountingIO} that
# routes every pikuri / Tuile log line into that window, the unread-error
# tally, and the +Ctrl+K+ leader-menu global shortcut whose status-bar segment
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
# The error tally is surfaced *only* through the +:menu+ status-bar segment —
# it is the single always-visible surface — so bumping the counter and
# rewriting that segment are the same act ({#on_error_logged} and
# {#reset_error_count} both call {#refresh_menu_segment}). That coupling is why
# the +Ctrl+K+ binding belongs to this class and not to the App's
# +register_shortcuts+ (which keeps the genuinely shell-agnostic +Ctrl+C+).
#
# The binding itself is now registered exactly *once*. Until Tuile 0.13 a
# shortcut carried its own +hint:+ and the only way to change the text was to
# re-register the binding, so a counter bump was expressed as a *dispatch*
# mutation; the status bar is the app's own component now, so the counter
# writes to it directly and the registry just runs the action.
#
# UI-thread-confined, with exceptions.
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
  # @param status_bar [Shared::StatusBar] the shell's bottom row; this class
  #   owns its +:menu+ segment and nothing else in it.
  def initialize(screen:, status_bar:)
    @screen = screen
    @status_bar = status_bar
    @error_count = 0
    @log_window = Tuile::Component::LogWindow.new('Log')
    @log_popup = Shared::Log::Popup.new(log_window: @log_window, on_dismiss: method(:reset_error_count))
    refresh_menu_segment
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

  # Registers the +Ctrl+K+ leader-menu global shortcut. The status-bar text is
  # not this method's business any more — {#refresh_menu_segment} owns the
  # +:menu+ segment and is driven by the counter, so this runs once.
  #
  # @yield the +Ctrl+K+ action — opening the App's {Shared::LeaderMenu}.
  # @return [void]
  def install_shortcut(&open_menu)
    @open_menu = open_menu if open_menu
    @screen.register_global_shortcut(Tuile::Keys::CTRL_K, &@open_menu)
  end

  # Opens the log popup (the leader menu's +l+ action). A no-op if it is
  # already open.
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
      refresh_menu_segment
    end
  end

  # Fires when the log popup is dismissed (ESC / q from inside the popup):
  # the user has now read the diagnostics. Runs on the event-loop thread, so
  # direct mutation is safe.
  #
  # @return [void]
  def reset_error_count
    @error_count = 0
    refresh_menu_segment
  end

  # Writes the current {#menu_hint} into the status bar's +:menu+ segment.
  # The sole writer of that segment, and the only thing a counter change has
  # to do. All callers are on the event-loop thread.
  #
  # @return [void]
  def refresh_menu_segment
    @status_bar[:menu] = menu_hint
  end

  # The status-bar segment advertised for +Ctrl+K+. The plain "menu" variant
  # uses the theme's +hint_color+; the warning variant uses the theme's
  # +:error+ token to foreground the unread-error tally so the user notices
  # something broke (and that the logs behind the menu are worth opening)
  # without us writing log lines into the conversation pane.
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
