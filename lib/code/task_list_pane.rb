# frozen_string_literal: true

require 'pikuri-core'
require 'tuile'

module Code
  # The sidebar's task pane as one cohesive domain component: a borderless
  # {Tuile::Component::Layout::Vertical} stacking a {Shared::PaneCaptionLabel}
  # over a task list it renders itself - a status glyph per item, a placeholder
  # when empty, per-status tone - exposing the UI verb {#items=}. The pikuri
  # seam lives in the nested {Listener}, which translates the agent's
  # {Pikuri::Tasks::ListChanged} stream into {#items=} calls; {WorkspaceSidebar}
  # composes the pane and folds {#listener} into the agent's +ListenerList+:
  #
  #   tasks = Code::TaskListPane.new
  #   config.add_listener(tasks.listener)   # into the agent's ListenerList
  #   # …later, on the UI thread:
  #   tasks.items = list                    # rewrites the pane
  #
  # Stateless w.r.t. the list: each {#items=} rewrites the whole pane from the
  # given snapshot (last-wins - a batch +task_create+ emits one event per item,
  # each carrying the full list, and the final one leaves the pane correct).
  #
  # Sits on the sidebar's +:pane_bg+ tint, inherited from {WorkspaceSidebar} —
  # this pane sets no background of its own.
  #
  # Coding-shell-only — the chat / computer shells carry no sidebar.
  #
  # UI-thread-confined (the nested {Listener} marshals the stream onto the UI
  # thread before calling {#items=}).
  class TaskListPane < Tuile::Component::Layout::Vertical
    # Shown in the (otherwise empty) pane before the agent has created any
    # tasks. Painted in the +:detail+ tone so it reads as placeholder chrome,
    # not a task.
    #
    # @return [String]
    PLACEHOLDER = '(no tasks)'

    # Per-status line marker. The status strings are {Pikuri::Tasks::STATUSES}.
    #
    # @return [Hash{String => String}]
    GLYPHS = {
      'pending'     => '○',
      'in_progress' => '▸',
      'completed'   => '✓'
    }.freeze

    # The pane's caption row.
    #
    # @return [String]
    CAPTION = 'Tasks'

    # Stacks a "Tasks" caption row over a fresh scrollable text view and builds
    # the nested {Listener} bound to +self+, reaching for the installed
    # +Tuile::Screen+ singleton (fake-able in tests) for its +event_queue+.
    def initialize
      super()
      @view = Tuile::Component::TextView.new
      # No scrollbar: nothing in the sidebar takes focus, so there is no key
      # that could drive one — inside a frame it read as chrome, but on the
      # borderless tint a full-height inoperable bar is just noise (tuile#10,
      # https://github.com/mvysny/tuile/issues/10, on why the bar is as loud
      # as it is). Even a toned bar stays inoperable here, so this stays
      # +:gone+ unless the pane becomes focusable.
      add(Shared::PaneCaptionLabel.new(CAPTION), Fixed[1])
      add(@view, Expand[1])
      @listener = Listener.new(pane: self, screen: screen)
    end

    # @return [Tuile::Component::TextView] the content view under the caption;
    #   exposed for tests, production drives it through {#items=} / {#listener}.
    attr_reader :view

    # @return [Listener] the task-stream adapter; fold it into the agent's
    #   +ListenerList+.
    attr_reader :listener

    # Rewrite the whole pane from a task snapshot: the {PLACEHOLDER} when empty,
    # else one styled line per item. Must run on the UI thread (the {Listener}
    # marshals it there).
    #
    # @param items [Array<Pikuri::Tasks::Item>] a frozen snapshot.
    # @return [void]
    def items=(items)
      @view.text =
        if items.empty?
          screen.theme.detail(PLACEHOLDER)
        else
          items.map { |item| render_item(item) }.join("\n")
        end
    end

    private

    # One task as a styled line: a status glyph + the content, toned by
    # status — +in_progress+ in the +:notice+ accent (the one active item),
    # +completed+ dimmed to +:detail+, +pending+ left in the default
    # foreground. An unrecognized status degrades to a +?+ glyph and the
    # default tone rather than raising — it's upstream data, not our state.
    #
    # @param item [Pikuri::Tasks::Item]
    # @return [String]
    def render_item(item)
      line = "#{GLYPHS.fetch(item.status, '?')} #{item.content}"
      case item.status
      when 'in_progress' then screen.theme.notice(line)
      when 'completed'   then screen.theme.detail(line)
      else line
      end
    end

    # Translates the agent's {Pikuri::Tasks::ListChanged} stream into
    # {TaskListPane#items=} calls; ignores every other event. Fires on the
    # agent's worker thread and marshals the rewrite onto the event-loop thread
    # via +screen.event_queue.submit+ (the queue is FIFO, so a batch's events
    # still land in order and the last snapshot wins). The companion to
    # {Shared::ConversationTextView::Listener} — same marshaling, a tiny slice of
    # the stream, and NOT rate-limited (task mutations are rare and each snapshot
    # is authoritative).
    class Listener < Pikuri::Agent::Listener::Base
      # @param pane [TaskListPane] the pane to drive. Lifetime owned by the
      #   pane; the listener neither constructs nor destroys it.
      # @param screen [Tuile::Screen] the screen whose +event_queue+ marshals
      #   the rewrite back from the worker thread. Passed explicitly so the
      #   listener can be unit-tested with a {Tuile::FakeScreen}.
      def initialize(pane:, screen:)
        super()
        @pane = pane
        @screen = screen
      end

      # @param event [Pikuri::Agent::Event::Base] any agent event; only
      #   {Pikuri::Tasks::ListChanged} is acted on.
      # @return [void]
      def on_event(event)
        return unless event.is_a?(Pikuri::Tasks::ListChanged)

        items = event.items
        @screen.event_queue.submit { @pane.items = items }
      end

      # @return [String] label used by +Pikuri::Agent#to_s+ when this listener
      #   is in its +ListenerList+.
      def to_s = 'TaskListener'
    end
  end
end
