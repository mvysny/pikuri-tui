# frozen_string_literal: true

require 'pikuri-core'
require 'tuile'

module Code
  # The sidebar's task pane as one cohesive domain component: a borderless
  # {Tuile::Component::Layout::Vertical} stacking a {Shared::PaneCaptionLabel}
  # over a one-row-per-task list it renders itself. Mid-way through five tasks
  # it reads:
  #
  #   Tasks: 2/5 ─────────────    <- the caption carries the done/total tally
  #   ▸ Add the s leader key …    <- in_progress, in the :notice accent
  #   ○ Put the files/tasks d…    <- pending; the two completed ones aren't listed
  #
  # The pikuri seam lives in the nested {Listener}, which translates the agent's
  # {Pikuri::Tasks::ListChanged} stream into {#items=} calls:
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
  # == Implementation details
  #
  # **Completed tasks are dropped, not dimmed.** Rows are the scarce resource
  # here — the pane is a fixed {WorkspaceSidebar::TASK_HEIGHT} tall, so a narrow
  # sidebar leaves it five — and a dimmed +✓+ row says nothing the caption's
  # tally doesn't. That is also why {ALL_DONE} exists: with those rows gone a
  # finished list renders empty, where {PLACEHOLDER} would claim the agent never
  # made any tasks.
  #
  # **Every task takes exactly one row**, which is why the view is a
  # display-only {Tuile::Component::List} and not a text view: a text view
  # word-wraps, so a long task would spill onto continuation rows carrying no
  # glyph, while the list ellipsizes each row to the width at paint time.
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

    # Shown once every task is completed, in the same +:detail+ tone.
    #
    # @return [String]
    ALL_DONE = '(all done)'

    # Per-status line marker, for the statuses that reach a row. The status
    # strings are {Pikuri::Tasks::STATUSES}; +completed+ has no entry because a
    # completed task is never listed.
    #
    # @return [Hash{String => String}]
    GLYPHS = {
      'pending'     => '○',
      'in_progress' => '▸'
    }.freeze

    # The pane's caption row, which gains a +": 2/5"+ done/total tally as soon
    # as there is anything to tally.
    #
    # @return [String]
    CAPTION = 'Tasks'

    # Stacks a "Tasks" caption row over a fresh list and builds the nested
    # {Listener} bound to +self+, reaching for the installed +Tuile::Screen+
    # singleton (fake-able in tests) for its +event_queue+.
    def initialize
      super()
      @items = []
      @tally = [0, 0]
      @on_tally = nil
      # Display-only, so Tab stays a two-stop cycle between the transcript and the
      # prompt. The bar shows only while the tasks overflow, a cue that the
      # wheel has more to scroll to, and hands its column back while they fit.
      @view = Tuile::Component::List.new
      @view.interactive = false
      @view.scrollbar_visibility = :auto
      @view.renderer = method(:row)
      @view.items = [PLACEHOLDER]
      @caption_label = Shared::PaneCaptionLabel.new(CAPTION)
      add(@caption_label, Fixed[1])
      add(@view, Expand[1])
      @listener = Listener.new(pane: self, screen: screen)
    end

    # @return [Tuile::Component::List] the content view under the caption;
    #   exposed for tests, production drives it through {#items=} / {#listener}.
    attr_reader :view

    # @return [Shared::PaneCaptionLabel] the caption row carrying the tally;
    #   exposed for tests.
    attr_reader :caption_label

    # @return [Listener] the task-stream adapter; fold it into the agent's
    #   +ListenerList+.
    attr_reader :listener

    # @return [Array(Integer, Integer)] +[completed, total]+ for the current
    #   list — the same tally the caption shows.
    attr_reader :tally

    # Registers a callback fired when {#tally} changes, so a host can carry the
    # count somewhere else while this pane is off screen. Edge-triggered on the
    # tally itself, so a snapshot that leaves the count alone fires nothing.
    #
    #   pane.on_tally { |done, total| … }
    #
    # One callback; a second registration replaces the first.
    #
    # @yieldparam done [Integer]
    # @yieldparam total [Integer]
    # @return [void]
    def on_tally(&block)
      @on_tally = block
    end

    # Rewrite the whole pane from a task snapshot. Must run on the UI thread
    # (the {Listener} marshals it there).
    #
    # @param items [Array<Pikuri::Tasks::Item>] a frozen snapshot.
    # @return [void]
    def items=(items)
      @items = items
      done, live = items.partition { |item| item.status == 'completed' }
      @caption_label.caption = items.empty? ? CAPTION : "#{CAPTION}: #{done.size}/#{items.size}"
      @view.items =
        if items.empty? then [PLACEHOLDER]
        elsif live.empty? then [ALL_DONE]
        else live
        end
      announce_tally(done.size)
    end

    protected

    # Re-renders the rows, whose tones the list has cached.
    #
    # @return [void]
    def handle_theme_changed
      super
      @view.refresh_rows
    end

    private

    # Fires {#on_tally} when the count has actually moved.
    #
    # @param done [Integer]
    # @return [void]
    def announce_tally(done)
      tally = [done, @items.size]
      return if tally == @tally

      @tally = tally
      @on_tally&.call(*tally)
    end

    # One list row: a placeholder in the +:detail+ tone, or a task as its glyph
    # then its content (the list ellipsizes it to the width). +in_progress+
    # takes the +:notice+ accent (the one active item); an unrecognized status
    # degrades to a +?+ glyph and the default tone rather than raising — it's
    # upstream data, not our state.
    #
    # @param entry [Pikuri::Tasks::Item, String] a live task, or {PLACEHOLDER} /
    #   {ALL_DONE}.
    # @param _width [Integer] the columns the list gives the row, unused — the
    #   list's own trailing ellipsis is the cut a task wants.
    # @return [Tuile::StyledString]
    def row(entry, _width)
      return Tuile::StyledString.styled(entry, fg: screen.theme[:detail]) if entry.is_a?(String)

      row = Tuile::StyledString.plain("#{GLYPHS.fetch(entry.status, '?')} #{entry.content}")
      entry.status == 'in_progress' ? row.with_fg(screen.theme[:notice]) : row
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

      # @param event [Data] any agent event; only
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
