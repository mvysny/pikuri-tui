# frozen_string_literal: true

require 'pikuri-core'
require 'tuile'

module Code
  # The task-list pane: a {Tuile::Component::TextView} subclass that owns
  # *how a task list is drawn* — a status glyph per item, a placeholder when
  # empty, per-status tone — exposing the UI verb {#items=}. The pikuri seam
  # lives in the nested {Listener}, not here: it translates the agent's
  # {Pikuri::Tasks::ListChanged} stream into {#items=} calls. Same
  # widget-owns-rendering / listener-is-a-thin-adapter split as
  # {Shared::ConversationTextView}; a much smaller vocabulary.
  #
  #   view = Code::TaskListTextView.new
  #   config.add_listener(view.listener)   # into the agent's ListenerList
  #   # …later, on the UI thread:
  #   view.items = tasks                    # rewrites the pane
  #
  # Stateless w.r.t. the list: each {#items=} rewrites the whole pane from
  # the given snapshot (last-wins — a batch +task_create+ emits one event
  # per item, each carrying the full list, and the final one leaves the pane
  # correct).
  #
  # UI-thread-confined (the nested {Listener} marshals the stream onto the UI
  # thread before calling {#items=}).
  class TaskListTextView < Tuile::Component::TextView
    # Shown in the (otherwise empty) pane before the agent has created any
    # tasks. Painted in the +:detail+ tone so it reads as placeholder
    # chrome, not a task.
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

    # Builds the nested {Listener} bound to +self+, reaching for the
    # installed +Tuile::Screen+ singleton (fake-able in tests) for its
    # +event_queue+ / +theme+.
    def initialize
      super()
      @listener = Listener.new(view: self, screen: screen)
    end

    # @return [Listener] the task-stream adapter; fold it into the agent's
    #   +ListenerList+.
    attr_reader :listener

    # Rewrite the whole pane from a task snapshot: the placeholder when
    # empty, else one styled line per item. Must run on the UI thread (the
    # {Listener} marshals it there).
    #
    # @param items [Array<Pikuri::Tasks::Item>] a frozen snapshot.
    # @return [void]
    def items=(items)
      self.text =
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
    # {TaskListTextView#items=} calls; ignores every other event. Fires on
    # the agent's worker thread and marshals the rewrite onto the event-loop
    # thread via +screen.event_queue.submit+ (the queue is FIFO, so a batch's
    # events still land in order and the last snapshot wins). The companion
    # to {Shared::ConversationTextView::Listener} — same marshaling, a tiny
    # slice of the stream, and NOT rate-limited (task mutations are rare and
    # each snapshot is authoritative).
    class Listener < Pikuri::Agent::Listener::Base
      # @param view [TaskListTextView] the pane to drive. Lifetime owned by
      #   the view; the listener neither constructs nor destroys it.
      # @param screen [Tuile::Screen] the screen whose +event_queue+ marshals
      #   the rewrite back from the worker thread. Passed explicitly so the
      #   listener can be unit-tested with a {Tuile::FakeScreen}.
      def initialize(view:, screen:)
        super()
        @view = view
        @screen = screen
      end

      # @param event [Pikuri::Agent::Event::Base] any agent event; only
      #   {Pikuri::Tasks::ListChanged} is acted on.
      # @return [void]
      def on_event(event)
        return unless event.is_a?(Pikuri::Tasks::ListChanged)

        items = event.items
        @screen.event_queue.submit { @view.items = items }
      end

      # @return [String] label used by +Pikuri::Agent#to_s+ when this
      #   listener is in its +ListenerList+.
      def to_s = 'TaskListener'
    end
  end
end
