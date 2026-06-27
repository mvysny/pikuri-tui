# frozen_string_literal: true

require 'tuile'

module PikuriTui
  # A "leader key" command menu: a modal popup listing app actions, each
  # bound to a single follow-up key, opened by one reserved leader shortcut
  # (the bins bind +Ctrl+K+). The lazyvim / VS-Code "which-key" pattern
  # retargeted at Tuile — one leader key stands in for a fistful of
  # per-action global shortcuts, and the popup advertises every binding, so
  # nothing has to be memorized and the terminal's scarce unprintable-key
  # namespace (much of it eaten by tmux, flow control, etc.) is freed.
  #
  # Actions are registered with {#add} (chainable) before the menu is first
  # opened; {#open} renders them through a {Tuile::Component::PickerWindow}
  # popup keyed by each action's follow-up key. A matching key runs that
  # action's callback; ESC and +Ctrl+C+ both cancel the menu (the latter via
  # the {CancelPopup} wrapper), as does any unbound key bubbling to the
  # popup — none run anything.
  #
  # Built on {Tuile::Component::PickerWindow} rather than reimplemented: it
  # already gives single-key options, a callback with the picked key, the
  # ESC/+q+ dismissal idiom, and a self-closing popup wrapper. The follow-up
  # keys are *printable* (+l+ / +d+ / +p+ / +m+ / +q+) — legal here because a
  # popup consumes them directly, unlike {Tuile::Screen#register_global_shortcut}
  # which rejects printable keys so they can't hijack typing in the input.
  #
  # Each picked callback is deferred to the next event-loop tick (via
  # +screen.event_queue.submit+) so the menu popup is fully closed *before*
  # the action runs — an action that opens another popup (logs, git diff,
  # model picker) then never stacks a second modal popup over this one.
  #
  # Shared by both shells (like {LogPopup}); each {Chat::App} / {Code::App}
  # builds one with its own action set — the chat shell wires +logs+ /
  # +switch model+ / +quit+, the coding shell adds +git diff+ / +plan mode+.
  class LeaderMenu
    # The popup caption shown above the action list.
    # @return [String]
    CAPTION = 'Menu'

    # The {Tuile::Component::Popup} wrapping the menu's {PickerWindow}, with
    # one addition over the base: +Ctrl+C+ dismisses it, exactly like ESC.
    #
    # +Ctrl+C+ is otherwise an app-level global shortcut (cancel turn / quit)
    # that {Tuile::Screen} suppresses while a modal popup is open, so without
    # this it would do nothing here. Folding it in makes the user's universal
    # "get me out" key cancel the menu like it cancels everything else. The
    # key reaches this override by bubbling up from the focused list (it is
    # not an option key, so {PickerWindow} declines it first) — the same path
    # ESC and +q+-close take.
    class CancelPopup < Tuile::Component::Popup
      # @param key [String]
      # @return [Boolean] true if the key was handled.
      def handle_key(key)
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
    #   @return [String] the action's label, shown after the key glyph.
    # @!attribute [r] callback
    #   @return [Proc, Method] the zero-arg callable run on pick.
    Action = Data.define(:key, :label, :callback)

    # @param screen [Tuile::Screen] the screen the popup mounts on and whose
    #   event queue defers each picked callback to the next tick.
    def initialize(screen:)
      @screen = screen
      @actions = []
    end

    # Register an action. Chainable; call before the first {#open}.
    #
    # @param key [String] the single follow-up key (e.g. +"l"+).
    # @param label [String] the action label (e.g. +"logs"+).
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
      options = @actions.map { |a| [a.key, a.label] }
      picker = Tuile::Component::PickerWindow.new(CAPTION, options) do |key|
        action = by_key[key]
        @screen.event_queue.submit { action.callback.call } if action
      end
      popup = CancelPopup.new(content: picker)
      picker.on_pick = -> { popup.close }
      popup.open
    end
  end
end
