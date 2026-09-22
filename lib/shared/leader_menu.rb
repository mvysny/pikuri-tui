# frozen_string_literal: true

require 'tuile'

# A "leader key" command menu: a modal popup listing app actions, each on
# one follow-up key, opened by a single reserved shortcut (the shells bind
# +Ctrl+K+). Register actions with {#add} (chainable) before the first
# {#open}:
#
#   menu = Shared::LeaderMenu.new(screen: screen)
#   menu.add('l', 'logs') { log_ui.open }
#   menu.add('q', 'quit') { app.quit }
#   # Ctrl+K opens the popup; "l" runs the logs action; ESC / Ctrl+C cancel
#
# The which-key pattern (lazyvim / VS Code) retargeted at Tuile: one leader
# key stands in for a fistful of global shortcuts, and the popup advertises
# every binding, so nothing has to be memorized and the terminal's scarce
# unprintable-key namespace (much of it eaten by tmux, flow control) stays
# free. Each picked callback is deferred to the next event-loop tick so the
# menu popup is fully closed *before* the action runs — an action that
# opens another popup (logs, git diff, model picker) then never stacks a
# second modal over this one.
#
# == Implementation details
#
# Built on {Tuile::Component::PickerWindow} (single-key options, a
# picked-key callback, the ESC/+q+ dismissal idiom, a self-closing popup
# wrapper). Follow-up keys are *printable* (+l+ / +d+ / +p+ / +m+ / +q+) —
# legal because the popup consumes them directly, unlike
# {Tuile::Screen#register_global_shortcut}, which rejects printable keys so
# they can't hijack typing in the input. ESC and any unbound key dismiss;
# +Ctrl+C+ dismisses too, via {CancelPopup} (it would otherwise be
# suppressed while a modal popup is open).
#
# UI-thread-confined.
class Shared::LeaderMenu
  # The default popup caption shown above the action list.
  # @return [String]
  CAPTION = 'Menu'

  # The menu's {Tuile::Component::Popup}, adding one thing over the base:
  # +Ctrl+C+ dismisses it, exactly like ESC. The key bubbles up from the
  # focused list (not an option key, so {PickerWindow} declines it first) —
  # the same path ESC / +q+-close take.
  class CancelPopup < Tuile::Component::Popup
    # @param key [String]
    # @return [Boolean] true if the key was handled.
    def handle_key?(key)
      return super unless key == Tuile::Keys::CTRL_C

      close
      true
    end
  end
  private_constant :CancelPopup

  # One menu entry: a follow-up key, its human label, and the zero-arg
  # callback run when the key is picked.
  #
  # @!attribute [r] key
  #   @return [String] the single follow-up key that runs this action.
  # @!attribute [r] label
  #   @return [String, #call] the action's label, shown after the key glyph;
  #     a callable is resolved at {#open} time.
  # @!attribute [r] callback
  #   @return [Proc, Method] the zero-arg callable run on pick.
  Action = Data.define(:key, :label, :callback) do
    # @return [String] the label as it should read right now.
    def text = label.respond_to?(:call) ? label.call : label
  end

  # @param screen [Tuile::Screen] the screen the popup mounts on and whose
  #   event queue defers each picked callback to the next tick.
  # @param caption [String] the popup's caption ({CAPTION} by default; a
  #   submenu passes its own).
  def initialize(screen:, caption: CAPTION)
    @screen = screen
    @caption = caption
    @actions = []
  end

  # Register an action. Chainable; call before the first {#open}.
  #
  # A *callable* label is resolved each time the menu opens, which is how a
  # toggle advertises its own state:
  #
  #   menu.add('t', -> { "thinking: #{pane.show_thinking ? 'shown' : 'hidden'}" }) { pane.toggle_thinking }
  #
  # @param key [String] the single follow-up key (e.g. +"l"+).
  # @param label [String, #call] the action label (e.g. +"logs"+), or a
  #   zero-arg callable returning one.
  # @yield the zero-arg action body, run on the event-loop thread (one tick
  #   after the key is picked, so the menu popup is already closed).
  # @return [self]
  # @raise [ArgumentError] if no block is given.
  def add(key, label, &callback)
    raise ArgumentError, 'block required' unless callback

    @actions << Action.new(key, label, callback)
    self
  end

  # @return [Boolean] true when no action has been registered.
  def empty? = @actions.empty?

  # @return [Array<Action>] the registered actions, in display order.
  #   Exposed for tests.
  attr_reader :actions

  # Open the menu as a modal popup listing every registered action. A
  # no-op when none are registered. Picking a key defers that action to the
  # next event-loop tick (so the menu closes first); ESC / +Ctrl+C+ / an
  # unbound key dismisses without running anything.
  #
  # Mirrors {Tuile::Component::PickerWindow.open}, but wraps the picker in a
  # {CancelPopup} (ESC *and* +Ctrl+C+ close) rather than the base popup
  # (ESC / +q+ only) — note +q+ here is a quit *action*, intercepted by the
  # picker before the popup's close handler, so cancel is ESC / +Ctrl+C+.
  #
  # @return [void]
  def open
    return if @actions.empty?

    by_key = @actions.to_h { |a| [a.key, a] }
    options = @actions.map { |a| [a.key, a.text] }
    picker = Tuile::Component::PickerWindow.new(@caption, options) do |key|
      action = by_key[key]
      @screen.event_queue.submit { action.callback.call } if action
    end
    popup = CancelPopup.new(content: picker)
    picker.on_pick { popup.close }
    popup.open
  end
end
