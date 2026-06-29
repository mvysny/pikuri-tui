# frozen_string_literal: true

require 'tuile'

module PikuriTui
  module Os
    # A {Tuile::Component::Label} that mounts in the conversation window's
    # footer slot and surfaces the agent's status: the plan-mode badge (a
    # leading notice-toned "‖ Plan Mode" when active), the current model's
    # display name (updated by {ModelListener} when a +run_loop+ model
    # switch lands), whether the agent is mid-turn (a spinner ticks while
    # +run_loop+ is on the worker thread), how many mid-turn messages are
    # queued in the agent's +Pikuri::Agent::Control::Interloper+ awaiting
    # delivery ("N queued"), and the latest context-window snapshot for the
    # main agent (read straight off
    # +Pikuri::Agent::Listener::TokenLog#status_line+). A parallel copy of
    # {Code::FooterLabel} (see {Os} for why the OS shell duplicates rather
    # than shares) — it carries the same plan-mode badge because the OS
    # agent has plan mode too.
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
    # slot: every freshly formatted line triggers a {#refresh} the moment
    # the +Tokens+ event lands, instead of waiting up to
    # {FRAME_INTERVAL_S} for the next spinner tick to poll it. "Main agent
    # only" is enforced by the observer's +id+ parameter: sub-agents
    # derived via +#for_sub_agent+ inherit the observer by reference, so
    # their pushes arrive here too — with their non-empty id — and are
    # dropped; their context windows are theirs, not the conversation's.
    # (The OS shell runs no sub-agents today, but the filter is free and
    # keeps the copy faithful to {Code::FooterLabel}.)
    #
    # == Theming
    #
    # The footer paints in the current theme's +Tuile::Theme#hint_color+ —
    # its content is status-hint chrome, the same family as the status
    # bar's "^K menu" hints. {#refresh} bakes the color in when it
    # rebuilds the text, and {#on_theme_changed} re-runs it on OS
    # light/dark appearance flips.
    #
    # == Threading
    #
    # The animation rides Tuile's +EventQueue#tick+: every
    # {FRAME_INTERVAL_S} the queue fires a block on the event-loop thread.
    # +TokenLog#status_line+ is safe to read from any thread. The
    # +on_status_line+ push fires on the agent-loop thread, so
    # {#on_status_line} marshals the {#refresh} back via
    # +event_queue.submit+. {#start_animation} / {#stop_animation} must be
    # called on the UI thread (the host does so from {App#start_turn} and
    # the worker's +ensure+ +submit+ block).
    class FooterLabel < Tuile::Component::Label
      # Braille-spinner frames; standard +dots+ animation. Picked over
      # ASCII +|/-\+ because the Braille glyphs stay a single column wide
      # regardless of font, so the trailing token line doesn't jitter
      # horizontally as the frame advances.
      #
      # @return [Array<String>]
      SPINNER = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

      # Seconds between spinner frame updates. 100 ms is the slowest
      # cadence at which a Braille spinner still reads as motion.
      #
      # @return [Float]
      FRAME_INTERVAL_S = 0.1

      # The main agent's mid-loop input queue, or +nil+ when the host
      # wired none. Installed by {App} *after* the agent is built. When
      # set, every refresh appends an "N queued" segment while +#size+
      # reports pending injections. Read only on the UI thread;
      # +Interloper#size+ is itself safe from any thread.
      #
      # @return [Pikuri::Agent::Control::Interloper, nil]
      attr_accessor :interloper

      # The display name of the agent's current model, shown as the
      # footer's leading segment (after any plan-mode badge). Set by {App}
      # once after the agent is built (the boot model) and again by
      # {ModelListener} each time a +run_loop(transport:)+ switch lands — so
      # it tracks the model the agent is *actually* on. +nil+/empty renders
      # no model segment. Assigning re-runs {#refresh}; must be set on the
      # UI thread.
      #
      # @return [String, nil]
      attr_reader :current_model

      # Whether the agent is currently in plan mode (a read-only posture
      # where the file-mutation tools refuse). When +true+, {#refresh}
      # leads with a notice-toned "‖ Plan Mode" badge so the posture is
      # impossible to miss against the dim hint chrome. Driven by
      # {Code::PlanModeListener} off the +Pikuri::Code::PlanModeChanged+
      # event — so it tracks the shared +Pikuri::Agent::Control::PlanMode+
      # flag whether the model or the leader menu's +p+ toggle flipped it.
      # Assigning re-runs {#refresh}; must be set on the UI thread.
      #
      # @return [Boolean]
      attr_reader :plan_active

      # @param screen [Tuile::Screen] screen whose +event_queue+ drives
      #   the spinner ticker.
      # @param token_log [Pikuri::Agent::Listener::TokenLog] main agent's
      #   token log; +#status_line+ is read on every refresh, and its
      #   +on_status_line+ observer slot is claimed so each new line
      #   refreshes the footer immediately (see the class docs).
      def initialize(screen:, token_log:)
        super()
        @screen = screen
        @token_log = token_log
        @interloper = nil
        @current_model = nil
        @plan_active = false
        @ticker = nil
        @spinner_frame = nil
        token_log.on_status_line = method(:on_status_line)
        refresh
      end

      # @param name [String, nil] new current-model display name.
      # @return [void]
      def current_model=(name)
        @current_model = name
        refresh
      end

      # @param active [Boolean] new plan-mode posture.
      # @return [void]
      def plan_active=(active)
        @plan_active = active
        refresh
      end

      # Start the spinner ticker (idempotent). Each tick advances
      # {@spinner_frame} to {SPINNER}'s next glyph and calls {#refresh} on
      # the event-loop thread. The frame lives in an ivar so a refresh
      # triggered between ticks (the +on_status_line+ push) repaints with
      # the current glyph instead of blanking the spinner.
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
      # text (no spinner glyph). Idempotent. The post-cancel +refresh+
      # runs inline because we're already on the UI thread.
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
      # appearance flips): re-run {#refresh} so the text is re-baked in
      # the *new* theme's +hint_color+. +super+ keeps any assigned
      # +on_theme_changed=+ listener firing, per the base-class contract.
      #
      # @return [void]
      def on_theme_changed
        super
        refresh
      end

      private

      # +TokenLog#on_status_line+ observer: a fresh status line was
      # formatted. Fires on the agent-loop thread, so the actual
      # {#refresh} marshals to the UI thread via +submit+. Lines pushed by
      # sub-agent +TokenLog+s (which inherit this observer through
      # +#for_sub_agent+) arrive with a non-empty +id+ and are dropped —
      # the footer tracks the main agent's context window only.
      #
      # @param id [String] owning agent's id; +""+ for the main agent.
      # @param _status_line [String] the freshly formatted line (unused —
      #   {#refresh} re-reads +TokenLog#status_line+).
      # @return [void]
      def on_status_line(id, _status_line)
        return unless id.empty?

        @screen.event_queue.submit { refresh }
      end

      # Recompute the label text from the plan-mode badge, the current
      # spinner frame, the interloper's pending count, and the token log's
      # status line. The badge is notice-toned so it stands out; the rest
      # is baked in the current theme's +hint_color+. Must run on the UI
      # thread.
      #
      # @return [void]
      def refresh
        hint = @screen.theme.hint_color
        segments = []
        segments << @current_model if @current_model && !@current_model.empty?
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

        # The plan-mode badge leads (notice-toned, so it pops against the
        # dim hint chrome); the spinner/model/queue/token tail follows in
        # hint_color. Either side may be empty. +theme[:notice]+ is the
        # color *value* (the badge is structured text built from spans, not
        # a plain hint string — see Tuile::Theme's helper-vs-+_color+ rule).
        rest = Tuile::StyledString.plain(plain).with_fg(hint) unless plain.empty?
        content =
          if @plan_active
            badge = Tuile::StyledString.plain('‖ Plan Mode').with_fg(@screen.theme[:notice])
            rest ? badge + Tuile::StyledString.plain(' · ').with_fg(hint) + rest : badge
          else
            rest
          end

        # Pad non-empty text with a hint-colored space on each side so it
        # doesn't butt up against the border dashes the wrap-content footer
        # sits in (hint so the non-plan path stays uniformly hint_color).
        pad = Tuile::StyledString.plain(' ').with_fg(hint)
        self.text = content.nil? ? Tuile::StyledString.plain('') : pad + content + pad
      end
    end
  end
end
