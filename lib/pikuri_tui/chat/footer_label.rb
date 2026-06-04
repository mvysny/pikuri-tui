# frozen_string_literal: true

require 'tuile'

module PikuriTui
  module Chat
    # A {Tuile::Component::Label} that mounts in the conversation window's
    # footer slot and surfaces three pieces of status the user otherwise
    # has no way to see: whether the agent is mid-turn (a spinner ticks
    # while +run_loop+ is on the worker thread), how many mid-turn
    # messages are queued in the agent's
    # +Pikuri::Agent::Control::Interloper+ awaiting delivery ("N queued" —
    # submitting mid-turn clears the input, so without this the message
    # would seem to vanish until the agent's next tool boundary echoes
    # it), and the latest context-window snapshot for the main agent
    # (read straight off +Pikuri::Agent::Listener::TokenLog#status_line+).
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
    # The animation rides Tuile's +EventQueue#tick+: every {FRAME_INTERVAL_S}
    # the queue fires a block on the event-loop thread, so the spinner
    # frame and the +status_line+ read happen on the UI thread directly —
    # no marshaling, no background thread owned by this class.
    # +TokenLog#status_line+ is documented as safe to read from any
    # thread (single instance-var read), so reading it from the tick
    # block costs nothing extra.
    #
    # {#start_animation} and {#stop_animation} themselves must be called
    # on the UI thread — they touch +@ticker+ and (in +stop+) call
    # +refresh+ inline to settle the label back to its idle text. The
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

      # The main agent's mid-loop input queue, or +nil+ when the host
      # wired none. Installed by {App} *after* the agent is built (the
      # label is constructed before the agent exists — same
      # chicken-and-egg as the listener/agent cycle documented on
      # {App#initialize}). When set, every refresh appends an
      # "N queued" segment while +#size+ reports pending injections.
      # Read only on the UI thread (the ticker block); +Interloper#size+
      # is itself documented as safe from any thread.
      #
      # @return [Pikuri::Agent::Control::Interloper, nil]
      attr_accessor :interloper

      # @param screen [Tuile::Screen] screen whose +event_queue+ drives
      #   the spinner ticker.
      # @param token_log [Pikuri::Agent::Listener::TokenLog] main
      #   agent's token log; +#status_line+ is read on every refresh.
      def initialize(screen:, token_log:)
        super()
        @screen = screen
        @token_log = token_log
        @interloper = nil
        @ticker = nil
        self.bg = 236
        refresh
      end

      # Start the spinner ticker (idempotent — calling twice keeps the
      # existing ticker). Each tick reads {SPINNER}'s next frame and
      # calls +refresh(spinner_frame:)+ on the event-loop thread.
      #
      # Must be called on the UI thread.
      #
      # @return [void]
      def start_animation
        return if @ticker

        @ticker = @screen.event_queue.tick(1.0 / FRAME_INTERVAL_S) do |tick|
          refresh(spinner_frame: SPINNER[tick % SPINNER.length])
        end
      end

      # Cancel the spinner ticker and settle the label back to its idle
      # text (no spinner glyph). Idempotent.
      #
      # The post-cancel +refresh+ runs inline because we're already on
      # the UI thread; any ticker firing that was queued mid-cancel is a
      # no-op once +Ticker#cancelled?+ flips, so this +refresh+ is the
      # last write either way.
      #
      # Must be called on the UI thread.
      #
      # @return [void]
      def stop_animation
        ticker = @ticker
        @ticker = nil
        return if ticker.nil?

        ticker.cancel
        refresh
      end

      private

      # @param spinner_frame [String, nil] one glyph from {SPINNER} when
      #   a turn is in progress; +nil+ when idle.
      # @return [void]
      def refresh(spinner_frame: nil)
        segments = []
        pending = @interloper ? @interloper.size : 0
        segments << "#{pending} queued" if pending.positive?
        status = @token_log.status_line
        segments << status unless status.empty?
        tail = segments.join(' · ')
        self.text =
          if spinner_frame.nil?
            tail
          elsif tail.empty?
            spinner_frame
          else
            "#{spinner_frame} #{tail}"
          end
      end
    end
  end
end
