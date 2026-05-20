# frozen_string_literal: true

require 'tuile'

module PikuriTui
  module Chat
    # A {Tuile::Component::Label} that mounts in the conversation window's
    # footer slot and surfaces two pieces of status the user otherwise has
    # no way to see: whether the agent is mid-turn (a spinner ticks while
    # +run_loop+ is on the worker thread) and the latest context-window
    # snapshot for the main agent (read straight off
    # +Pikuri::Agent::Listener::TokenLog#status_line+).
    #
    # == Why the spinner and the tokens share a slot
    #
    # Both are "what is the conversation costing me right now?" signals,
    # and the footer is the one place on screen the user already looks
    # for chrome that summarizes the pane above it. Putting them in the
    # status bar would compete with global shortcut hints; putting them
    # in the conversation pane would pollute the transcript.
    #
    # == Token source
    #
    # Reads from a +Pikuri::Agent::Listener::TokenLog+ handed in at
    # construction. The host wires the same instance into the agent's
    # +ListenerList+ so the listener accumulates per-turn snapshots and
    # this label renders the cached +status_line+ — no second event
    # subscription, no duplicated formatting. Restricting the source to
    # one instance is how "main agent only" is enforced: sub-agents get
    # their own +TokenLog+ via +#for_sub_agent+ and never write into
    # this one.
    #
    # == Threading
    #
    # The animation runs on a private background thread that submits a
    # text update through +screen.event_queue+ every {FRAME_INTERVAL_S}.
    # Per CLAUDE.md, every UI mutation lands on the event-loop thread;
    # the worker only computes the next frame index and dispatches.
    # +TokenLog#status_line+ is documented as safe to read from any
    # thread (single instance-var read), so reading it from inside the
    # submitted block on the UI thread costs nothing extra.
    #
    # {#start_animation} and {#stop_animation} themselves must be called
    # on the UI thread — they touch +@thread+ and (in +stop+) push a
    # final +submit+ to settle the label back to its idle text. The
    # host calls them from {App#start_turn} (pre-spawn) and from the
    # +ensure+ block's +event_queue.submit+ (post-loop), which is the
    # UI thread in both cases.
    class FooterLabel < Tuile::Component::Label
      # Braille-spinner frames; standard +dots+ animation. Picked over
      # ASCII +|/-\+ because the Braille glyphs stay a single column
      # wide regardless of font, so the trailing token line doesn't
      # jitter horizontally as the frame advances.
      #
      # @return [Array<String>]
      SPINNER = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

      # Seconds between spinner frame updates. 100 ms is the slowest
      # cadence at which a Braille spinner still reads as motion; any
      # slower and it looks like the UI is stuck.
      #
      # @return [Float]
      FRAME_INTERVAL_S = 0.1

      # @param screen [Tuile::Screen] screen whose +event_queue+ the
      #   animation thread submits UI mutations through.
      # @param token_log [Pikuri::Agent::Listener::TokenLog] main
      #   agent's token log; +#status_line+ is read on every refresh.
      def initialize(screen:, token_log:)
        super()
        @screen = screen
        @token_log = token_log
        @thread = nil
        self.bg = 236
        refresh
      end

      # Spawn the spinner thread (idempotent — calling twice is a
      # no-op). Each tick reads {SPINNER}'s next frame and submits a
      # +refresh(spinner_frame:)+ onto the event queue.
      #
      # Must be called on the UI thread.
      #
      # @return [void]
      def start_animation
        return if @thread&.alive?

        @thread = Thread.new { spin_loop }
      end

      # Stop the spinner thread and settle the label back to its idle
      # text (no spinner glyph). Idempotent.
      #
      # The final +refresh+ is submitted onto the event queue (rather
      # than called inline) so it queues *after* any spinner-frame
      # callbacks the running thread may have submitted before it was
      # killed — that way the visible end state is always the
      # spinner-less idle line.
      #
      # Must be called on the UI thread.
      #
      # @return [void]
      def stop_animation
        thread = @thread
        @thread = nil
        return if thread.nil?

        thread.kill
        @screen.event_queue.submit { refresh }
      end

      private

      # @return [void]
      def spin_loop
        frame = 0
        while @thread == Thread.current
          glyph = SPINNER[frame % SPINNER.length]
          @screen.event_queue.submit { refresh(spinner_frame: glyph) }
          sleep FRAME_INTERVAL_S
          frame += 1
        end
      rescue StandardError => e
        Tuile.logger.error("FooterLabel animation thread failed: #{e.class}: #{e.message}")
      end

      # @param spinner_frame [String, nil] one glyph from {SPINNER} when
      #   a turn is in progress; +nil+ when idle.
      # @return [void]
      def refresh(spinner_frame: nil)
        status = @token_log.status_line
        self.text =
          if spinner_frame.nil?
            status
          elsif status.empty?
            spinner_frame
          else
            "#{spinner_frame} #{status}"
          end
      end
    end
  end
end
