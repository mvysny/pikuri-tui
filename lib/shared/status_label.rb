# frozen_string_literal: true

require 'tuile'

# Keeps the conversation window's bottom-border chrome
# ({Tuile::Component::Window#footer_text}) current, surfacing the agent's
# status: an optional plan-mode badge
# (a leading notice-toned "‖ Plan Mode" when active), the current model's
# display name (the leading segment after any badge, updated by
# {Shared::Model::Listener} when a +run_loop+ model switch lands), whether the agent
# is mid-turn (a spinner ticks while +run_loop+ is on the worker thread),
# how many mid-turn messages are queued in the agent's
# +Pikuri::Agent::Control::Interloper+ awaiting delivery ("N queued" —
# submitting mid-turn clears the input, so without this the message would
# seem to vanish until the agent's next tool boundary echoes it), and the
# latest context-window snapshot for the main agent (read straight off
# +Pikuri::Agent::Listener::TokenLog#status_line+).
#
# Shared by all three shells (like {Shared::InputArea} / {Shared::ConversationTextView}). The chat
# shell wires no {Code::PlanModeListener}, so its footer simply never
# receives a {#plan_active=} call and the badge stays hidden — the render
# is identical to a badge-less footer. The coding and OS shells both have
# plan mode, so their +PlanModeListener+ lights the badge here.
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
# for the next spinner tick to poll it. Sub-agents derived via
# +TokenLog#for_sub_agent+ inherit the observer by reference, so
# their pushes arrive here too — with their non-empty id. Rather
# than drop them, the footer surfaces a running sub-agent's line in
# the token slot, labeled with its id (a leading "⤷") so it reads as
# the delegate's own context window, not the conversation's: during
# a long delegation (e.g. a RESEARCHER web-research turn) the main
# agent is blocked in the +agent+ tool and emits no lines of its
# own, so without this the footer's token readout would freeze. The
# sub-agent segment clears the moment the main agent resumes and
# emits its next line (see {#on_status_line}).
#
# == Theming
#
# The footer paints in the current theme's +Tuile::Theme#hint_color+ —
# its content (spinner, queued count, token status) is status-hint
# chrome, the same family as the status bar's "^K menu" hints — on the
# terminal-default background, matching Tuile's "tokens cover only
# accents; everything else inherits the terminal" strategy. {#refresh}
# bakes the color in when it rebuilds the text; the composer registers it
# as the window's +Tuile::Component#on_theme_changed=+ listener, which
# +Tuile::Screen#theme=+ fires tree-wide on OS light/dark appearance
# flips — so a baked-in color never survives a palette change. The
# plan-mode badge leads in the +:notice+ accent so it pops against the
# dim hint chrome.
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
class Shared::StatusLabel
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

  # The display name of the agent's current model, shown as the
  # footer's leading segment (after any plan-mode badge). Set by {App}
  # once after the agent is built (the boot model) and again by
  # {Shared::Model::Listener} each time a +run_loop(transport:)+ switch lands — so
  # it tracks the model the agent is *actually* on, never an optimistic
  # guess. +nil+/empty renders no model segment. Assigning re-runs
  # {#refresh}; must be set on the UI thread (the {Shared::Model::Listener}
  # marshals via +submit+).
  #
  # @return [String, nil]
  attr_reader :current_model

  # Whether the agent is currently in plan mode (a read-only posture
  # where the file-mutation tools refuse). When +true+, {#refresh}
  # leads with a notice-toned "‖ Plan Mode" badge so the posture is
  # impossible to miss against the dim hint chrome. Driven by
  # {Code::PlanModeListener} off the +Pikuri::Code::PlanModeChanged+
  # event — so it tracks the shared +Pikuri::Workspace::ReadOnly+ flag
  # whether the model or the leader menu's +p+ toggle flipped it. The
  # chat shell wires no listener and never sets this, so its footer
  # stays badge-less. Assigning re-runs {#refresh}; must be set on the
  # UI thread.
  #
  # @return [Boolean]
  attr_reader :plan_active

  # @param screen [Tuile::Screen] screen whose +event_queue+ drives
  #   the spinner ticker.
  # @param window [Tuile::Component::Window] the conversation window
  #   whose {Tuile::Component::Window#footer_text} this keeps current.
  #   Its +on_theme_changed+ listener slot is claimed so a palette flip
  #   re-bakes the chrome in the new theme's +hint_color+.
  # @param token_log [Pikuri::Agent::Listener::TokenLog] main
  #   agent's token log; +#status_line+ is read on every refresh,
  #   and its +on_status_line+ observer slot is claimed so each new
  #   line refreshes the footer immediately (see the class docs).
  def initialize(screen:, window:, token_log:)
    @screen = screen
    @window = window
    @token_log = token_log
    @interloper = nil
    @current_model = nil
    @plan_active = false
    @sub_status = nil
    @ticker = nil
    @spinner_frame = nil
    token_log.on_status_line = method(:on_status_line)
    window.on_theme_changed = method(:refresh)
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

    @ticker = @screen.event_queue.tick(FRAME_INTERVAL_S) do |tick|
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

  private

  # +TokenLog#on_status_line+ observer: a fresh status line was
  # formatted. Fires on the agent-loop thread, so the mutation +
  # {#refresh} marshal to the UI thread via +submit+.
  #
  # A main-agent line (+id+ empty) clears any transient sub-agent
  # segment and the footer reverts to the main context window (read
  # from +TokenLog#status_line+ in {#refresh}). A sub-agent line
  # (+id+ non-empty, inherited through +TokenLog#for_sub_agent+)
  # stashes the *pushed* line under {@sub_status} — the sub-agent's
  # own {TokenLog} is a different instance, so {#refresh} can't poll
  # it — and the footer shows it labeled with the id while the
  # delegation runs (e.g. a long RESEARCHER turn, during which the
  # main agent is blocked in the +agent+ tool and emits no lines of
  # its own). It reverts the moment the main agent resumes and emits
  # its next line. A sub-agent that pushes an empty line (e.g. a
  # reset) clears the segment too.
  #
  # @param id [String] owning agent's id; +""+ for the main agent.
  # @param status_line [String] the freshly formatted line (used
  #   only for the sub-agent path; the main path re-reads
  #   +TokenLog#status_line+, safe from any thread).
  # @return [void]
  def on_status_line(id, status_line)
    @screen.event_queue.submit do
      @sub_status =
        if id.empty? || status_line.empty?
          nil
        else
          "⤷ #{id}  #{status_line}"
        end
      refresh
    end
  end

  # Recompute the window's footer chrome from the plan-mode badge, the
  # current spinner frame, the interloper's pending count, and the token
  # log's status line, and assign it to
  # {Tuile::Component::Window#footer_text}. The badge is notice-toned so it
  # stands out; the rest is baked in the current theme's +hint_color+
  # (re-derived on theme flips via the window's +on_theme_changed+
  # listener). Must run on the UI thread.
  #
  # @return [void]
  def refresh
    hint = @screen.theme.hint_color
    segments = []
    segments << @current_model if @current_model && !@current_model.empty?
    pending = @interloper ? @interloper.size : 0
    segments << "#{pending} queued" if pending.positive?
    # A running sub-agent's line takes the token slot (labeled with its
    # id so it reads as the delegate's context, not the conversation's);
    # otherwise the main agent's own snapshot.
    status = @sub_status || @token_log.status_line
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
    # doesn't butt up against the border corner or the dashes filling the
    # rest of the bottom border (hint so the non-plan path stays uniformly
    # hint_color).
    pad = Tuile::StyledString.plain(' ').with_fg(hint)
    @window.footer_text = content.nil? ? Tuile::StyledString.plain('') : pad + content + pad
  end
end
