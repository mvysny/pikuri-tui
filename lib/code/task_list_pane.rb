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
  # **Every task takes exactly one row**, ellipsized to the pane's width.
  # {Tuile::Component::TextView} word-wraps unconditionally and offers no
  # truncate mode, so a long task would otherwise spill onto continuation rows
  # carrying no glyph. Truncation is width-dependent, so the pane keeps the last
  # snapshot and renders it in {#relayout}, where the width is settled; a zero
  # width (unmounted, or a sidebar column {Layout} collapsed) reads as *unknown*
  # and truncates nothing until a real one lands.
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

    # Columns a row spends before its content: the status glyph and one space.
    #
    # @return [Integer]
    GLYPH_WIDTH = 2

    # Stacks a "Tasks" caption row over a fresh text view and builds the nested
    # {Listener} bound to +self+, reaching for the installed +Tuile::Screen+
    # singleton (fake-able in tests) for its +event_queue+.
    def initialize
      super()
      @items = []
      @tally = [0, 0]
      @on_tally = nil
      # Passive, so Tab stays a two-stop cycle between the transcript and the
      # prompt, and left on Tuile's default +:gone+ scrollbar — with nothing in
      # the sidebar focusable, no key could drive either one.
      @view = Shared::PassiveTextView.new
      @caption_label = Shared::PaneCaptionLabel.new(CAPTION)
      add(@caption_label, Fixed[1])
      add(@view, Expand[1])
      @listener = Listener.new(pane: self, screen: screen)
    end

    # @return [Shared::PassiveTextView] the content view under the caption;
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
    # tally itself, so a re-render at a new width fires nothing.
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
    # (the {Listener} marshals it there). {#on_tally} fires at once; the rows
    # render when the layout settles.
    #
    # @param items [Array<Pikuri::Tasks::Item>] a frozen snapshot.
    # @return [void]
    def items=(items)
      @items = items
      announce_tally(items.count { |item| item.status == 'completed' })
      invalidate_layout
    end

    protected

    # Stacks the caption over the view, then renders the rows at the width just
    # settled, which each is ellipsized to — a snapshot can land before the pass
    # that sizes this pane.
    #
    # @return [void]
    def relayout
      super
      render
    end

    private

    # Rewrites the caption tally and the rows from the held snapshot.
    #
    # @return [void]
    def render
      done, live = @items.partition { |item| item.status == 'completed' }
      @caption_label.caption = @items.empty? ? CAPTION : "#{CAPTION}: #{done.size}/#{@items.size}"
      @view.text =
        if @items.empty?
          dim(PLACEHOLDER)
        elsif live.empty?
          dim(ALL_DONE)
        else
          join(live.map { |item| render_item(item) })
        end
    end

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

    # One task as a styled row: its glyph, then the content ellipsized to
    # whatever the width leaves. +in_progress+ takes the +:notice+ accent (the
    # one active item); an unrecognized status degrades to a +?+ glyph and the
    # default tone rather than raising — it's upstream data, not our state.
    #
    # @param item [Pikuri::Tasks::Item]
    # @return [Tuile::StyledString]
    def render_item(item)
      content = Tuile::StyledString.plain(item.content)
      budget = content_width
      content = content.ellipsize(budget) if budget
      row = Tuile::StyledString.plain("#{GLYPHS.fetch(item.status, '?')} ") + content
      item.status == 'in_progress' ? row.with_fg(screen.theme[:notice]) : row
    end

    # @return [Integer, nil] columns a task's content may occupy, or +nil+ when
    #   the pane has no width yet and nothing should be truncated.
    def content_width
      return nil unless width.positive?

      [width - GLYPH_WIDTH, 1].max
    end

    # @param text [String]
    # @return [Tuile::StyledString] +text+ in the placeholder tone.
    def dim(text) = Tuile::StyledString.styled(text, fg: screen.theme[:detail])

    # @param rows [Array<Tuile::StyledString>] at least one row.
    # @return [Tuile::StyledString] the rows as one newline-separated block.
    def join(rows)
      separator = Tuile::StyledString.plain("\n")
      rows.inject { |block, row| block + separator + row }
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
