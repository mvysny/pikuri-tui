# frozen_string_literal: true

require 'pikuri-core'

module Code
  # Renders the agent's task list into the sidebar's task window. A
  # {Pikuri::Agent::Listener::Base} subclass that consumes the
  # {Pikuri::Tasks::ListChanged} events {Pikuri::Tasks::Extension} emits
  # after every list mutation, rewriting a {Tuile::Component::TextView}
  # with the current items. The companion to {Shared::ConversationTextView::Listener}: same
  # worker-thread-to-UI-thread marshaling, a different (and much smaller)
  # slice of the event stream.
  #
  # == Why a listener, not a poll
  #
  # The {Pikuri::Tasks::List} is confined to the agent thread, so a UI
  # pane must not read it directly. {Pikuri::Tasks::ListChanged} carries
  # a frozen +items+ snapshot built for exactly this — safe to capture
  # and render from the UI thread. The event rides the agent's listener
  # stream, so the host wires this listener into the agent's
  # +ListenerList+ alongside {Shared::ConversationTextView::Listener} (it is NOT rate-limited —
  # task mutations are rare, and each is authoritative).
  #
  # == Last-wins
  #
  # A batch +task_create+ emits one event per item; each snapshot is the
  # whole list, so the listener simply rewrites the pane from the latest
  # snapshot rather than diffing — the final event of a batch leaves the
  # pane correct.
  #
  # == Threading
  #
  # {#on_event} fires on the agent's worker thread; it marshals the
  # +TextView+ rewrite onto the event-loop thread via
  # +screen.event_queue.submit+, the same rule {Shared::ConversationTextView::Listener} follows.
  class TaskListener < Pikuri::Agent::Listener::Base
    # Shown in the (otherwise empty) task pane before the agent has
    # created any tasks. Painted in the +:detail+ tone so it reads as
    # placeholder chrome, not a task.
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

    # @param text_view [Tuile::Component::TextView] the task pane to
    #   render into. Lifetime is owned by the host ({Code::App}); the
    #   listener doesn't construct or destroy it.
    # @param screen [Tuile::Screen] the screen whose +event_queue+
    #   marshals the rewrite back from the agent's worker thread and
    #   whose +theme+ supplies the status tones. Passed explicitly (not
    #   reached for via the singleton) so tests can inject a
    #   {Tuile::FakeScreen}.
    def initialize(text_view:, screen:)
      super()
      @text_view = text_view
      @screen = screen
    end

    # Rewrites the task pane from a {Pikuri::Tasks::ListChanged} snapshot;
    # ignores every other event. Called from the agent's worker thread —
    # the +TextView+ rewrite is marshaled onto the event-loop thread.
    #
    # @param event [Pikuri::Agent::Event::Base] any agent event; only
    #   {Pikuri::Tasks::ListChanged} is acted on.
    # @return [void]
    def on_event(event)
      return unless event.is_a?(Pikuri::Tasks::ListChanged)

      items = event.items
      @screen.event_queue.submit { render(items) }
    end

    # @return [String] short label used by +Pikuri::Agent#to_s+ when this
    #   listener is in its +ListenerList+.
    def to_s = 'TaskListener'

    private

    # Replace the pane's whole content with the rendered snapshot (the
    # placeholder when empty). Runs on the event-loop thread via
    # {#on_event}'s +submit+, so the +text=+ is under the UI lock.
    #
    # @param items [Array<Pikuri::Tasks::Item>] frozen snapshot
    # @return [void]
    def render(items)
      @text_view.text =
        if items.empty?
          @screen.theme.detail(PLACEHOLDER)
        else
          items.map { |item| render_item(item) }.join("\n")
        end
    end

    # One task as a styled line: a status glyph + the content, toned by
    # status — +in_progress+ in the +:notice+ accent (the one active
    # item), +completed+ dimmed to +:detail+, +pending+ left in the
    # default foreground. An unrecognized status degrades to a +?+ glyph
    # and the default tone rather than raising — it's upstream data, not
    # our state.
    #
    # @param item [Pikuri::Tasks::Item]
    # @return [String]
    def render_item(item)
      line = "#{GLYPHS.fetch(item.status, '?')} #{item.content}"
      case item.status
      when 'in_progress' then @screen.theme.notice(line)
      when 'completed'   then @screen.theme.detail(line)
      else line
      end
    end
  end
end
