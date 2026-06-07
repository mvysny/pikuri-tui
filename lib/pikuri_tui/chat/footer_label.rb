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
    # subscription, no duplicated formatting.
    #
    # The constructor also claims the log's +on_status_line+ observer
    # slot (it's a single-callable accessor, so the label owns it):
    # every freshly formatted line triggers a {#refresh} the moment the
    # +Tokens+ event lands, instead of waiting up to {FRAME_INTERVAL_S}
    # for the next spinner tick to poll it. "Main agent only" is
    # enforced by the observer's +id+ parameter: sub-agents derived via
    # +#for_sub_agent+ inherit the observer by reference, so their
    # pushes arrive here too — with their non-empty id — and are
    # dropped; their context windows are theirs, not the
    # conversation's.
    #
    # == Theming
    #
    # The footer paints in the current theme's
    # +Tuile::Theme#hint_color+ — its content (spinner, queued count,
    # token status) is status-hint chrome, the same family as the
    # status bar's "^L logs" hints — on the terminal-default
    # background, matching Tuile's "tokens cover only accents;
    # everything else inherits the terminal" strategy. {#refresh}
    # bakes the color in when it rebuilds the text, and
    # {#on_theme_changed} re-runs it on OS light/dark appearance
    # flips (+Tuile::Screen#theme=+ fires the hook tree-wide), so a
    # baked-in color never survives a palette change.
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
    # The +on_status_line+ push is the one off-thread entry point: the
    # observer fires on whatever thread runs the agent loop (the App's
    # worker), so {#on_status_line} marshals the {#refresh} back via
    # +event_queue.submit+ and touches nothing itself.
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
      #   agent's token log; +#status_line+ is read on every refresh,
      #   and its +on_status_line+ observer slot is claimed so each new
      #   line refreshes the footer immediately (see the class docs).
      def initialize(screen:, token_log:)
        super()
        @screen = screen
        @token_log = token_log
        @interloper = nil
        @ticker = nil
        @spinner_frame = nil
        token_log.on_status_line = method(:on_status_line)
        refresh
      end

      # Start the spinner ticker (idempotent — calling twice keeps the
      # existing ticker). Each tick advances {@spinner_frame} to
      # {SPINNER}'s next glyph and calls {#refresh} on the event-loop
      # thread. The frame lives in an ivar (rather than being passed
      # into +refresh+) so a refresh triggered between ticks — the
      # +on_status_line+ push — repaints with the current glyph instead
      # of blanking the spinner until the next frame.
      #
      # Must be called on the UI thread.
      #
      # @return [void]
      def start_animation
        return if @ticker

        @ticker = @screen.event_queue.tick(1.0 / FRAME_INTERVAL_S) do |tick|
          @spinner_frame = SPINNER[tick % SPINNER.length]
          refresh
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
        @spinner_frame = nil
        return if ticker.nil?

        ticker.cancel
        refresh
      end

      # Theme changed (+Tuile::Screen#theme=+, fired on OS light/dark
      # appearance flips, dispatches this tree-wide): re-run {#refresh}
      # so the text is re-baked in the *new* theme's +hint_color+ —
      # the baked-in color is exactly the "content styled from the old
      # theme" case this hook exists for. +super+ keeps any assigned
      # +on_theme_changed=+ listener firing, per the base-class
      # contract.
      #
      # @return [void]
      def on_theme_changed
        super
        refresh
      end

      private

      # +TokenLog#on_status_line+ observer: a fresh status line was
      # formatted. Fires on the agent-loop thread, so the actual
      # {#refresh} marshals to the UI thread via +submit+. Lines pushed
      # by sub-agent +TokenLog+s (which inherit this observer through
      # +#for_sub_agent+) arrive with a non-empty +id+ and are dropped —
      # the footer tracks the main agent's context window only.
      #
      # @param id [String] owning agent's id; +""+ for the main agent.
      # @param _status_line [String] the freshly formatted line
      #   (unused — {#refresh} re-reads +TokenLog#status_line+, which
      #   is documented as safe from any thread).
      # @return [void]
      def on_status_line(id, _status_line)
        return unless id.empty?

        @screen.event_queue.submit { refresh }
      end

      # Recompute the label text from the current spinner frame, the
      # interloper's pending count, and the token log's status line,
      # baked in the current theme's +hint_color+ (re-derived on theme
      # flips by {#on_theme_changed}). Must run on the UI thread.
      #
      # @return [void]
      def refresh
        segments = []
        pending = @interloper ? @interloper.size : 0
        segments << "#{pending} queued" if pending.positive?
        status = @token_log.status_line
        segments << status unless status.empty?
        tail = segments.join(' · ')
        plain =
          if @spinner_frame.nil?
            tail
          elsif tail.empty?
            @spinner_frame
          else
            "#{@spinner_frame} #{tail}"
          end
        self.text = Tuile::StyledString.plain(plain).with_fg(@screen.theme.hint_color)
      end
    end
  end
end
