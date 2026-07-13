# frozen_string_literal: true

require 'tuile'
require 'pikuri-core'

# Keeps the conversation window's footer text
# ({Tuile::Component::Window#footer_text}) current. A busy footer reads:
#
#   ⠹ ‖ Plan Mode · Local Qwen 3.6 · 2 queued · 25k/60k
#   ⠹ <plan mode?>   <model>       <queued>   <context stats>
#
# Empty segments drop out (chat never lights the badge; an idle agent shows
# no spinner). During a long sub-agent delegation the token slot shows the
# delegate's own line instead, e.g. +⤷ researcher  8k/60k+, so the readout
# doesn't freeze while the main agent blocks in the +agent+ tool.
#
# Drive it with the setters and the spinner controls, plus the nested
# {ModelListener} (folded into the agent's +ListenerList+) which re-points
# {#current_model} whenever a +run_loop+ switch lands:
#
#   footer = Shared::StatusFooterUpdater.new(screen:, window:, token_log:)
#   footer.current_model = 'Local Qwen 3.6'  # boot model
#   footer.interloper = agent.interloper     # enables the "N queued" segment
#   footer.plan_active = true                # lights the badge
#   footer.start_animation                   # spinner on for a turn; stop_animation after
#
# +token_log+ must be the *same* {Pikuri::Agent::Listener::TokenLog}
# instance wired into the agent — the footer reads its cached +status_line+
# rather than subscribing to events itself.
#
# == Implementation details
#
# The setters and {#start_animation}/{#stop_animation} must run on the UI
# thread. The one off-thread entry is the +token_log.on_status_line+ push
# (claimed at construction); {#on_status_line} marshals its refresh via
# +event_queue.submit+.
class Shared::StatusFooterUpdater
  # Braille dots: single-column-wide in every font, so the trailing token
  # line doesn't jitter as frames advance — ASCII +|/-\+ would.
  #
  # @return [Array<String>]
  SPINNER = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

  # Seconds between spinner frames. 100 ms is the slowest cadence that
  # still reads as motion; slower looks like the UI is stuck.
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
  # {Shared::StatusFooterUpdater::ModelListener} each time a +run_loop(transport:)+ switch lands — so
  # it tracks the model the agent is *actually* on, never an optimistic
  # guess. +nil+/empty renders no model segment. Assigning re-runs
  # {#refresh}; must be set on the UI thread (the {Shared::StatusFooterUpdater::ModelListener}
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

  # On a +run_loop+ model switch ({Pikuri::Agent::Event::ModelSwitched}),
  # pushes the switched-to model's friendly name onto the footer's
  # {#current_model}; ignores every other event. Fold it into the agent's
  # +ListenerList+.
  #
  # +names+ resolves a transport to its display name. It's keyed on the
  # +[model, api_base]+ pair ({Shared::Model::Choice.key}), not the model id
  # alone — two connections can run the same model on different servers, so
  # the id can't tell +"Local Qwen 3.6"+ from +"mavi-fw Qwen 3.6"+. A
  # transport absent from the map falls back to its raw model id.
  #
  # == Implementation details
  #
  # {#on_event} fires on the agent's worker thread and marshals the footer
  # mutation onto the event-loop thread via +screen.event_queue.submit+.
  class ModelListener < Pikuri::Agent::Listener::Base
    # @param footer [#current_model=] the conversation-window footer to
    #   update (a {Shared::StatusFooterUpdater}). Lifetime is owned by the
    #   host +App+.
    # @param screen [Tuile::Screen] the screen whose +event_queue+ marshals
    #   the update back from the worker thread. Passed explicitly (not the
    #   singleton) so tests can inject a {Tuile::FakeScreen}.
    # @param names [Hash{Array(String, String) => String}]
    #   {Shared::Model::Choice.key} ([model, api_base]) → display name;
    #   transports absent from the map render as their raw model id.
    def initialize(footer:, screen:, names: {})
      super()
      @footer = footer
      @screen = screen
      @names = names
    end

    # Pushes the switched-to model's display name onto the footer; ignores
    # every other event. Called from the agent's worker thread — the footer
    # mutation is marshaled onto the event-loop thread.
    #
    # @param event [Pikuri::Agent::Event::Base] any agent event; only
    #   {Pikuri::Agent::Event::ModelSwitched} is acted on.
    # @return [void]
    def on_event(event)
      return unless event.is_a?(Pikuri::Agent::Event::ModelSwitched)

      name = display_name(event.to)
      @screen.event_queue.submit { @footer.current_model = name }
    end

    # @return [String] short label used by +Pikuri::Agent#to_s+ when this
    #   listener is in its +ListenerList+.
    def to_s = 'Shared::StatusFooterUpdater::ModelListener'

    # Resolve a transport to its friendly connection name, falling back to
    # the raw model id when the +[model, api_base]+ pair isn't in the map.
    #
    # @param transport [Pikuri::Agent::ChatTransport] the landed transport
    #   (typically a {Pikuri::Agent::Event::ModelSwitched}'s +to:+).
    # @return [String]
    def display_name(transport)
      @names.fetch(Shared::Model::Choice.key(transport), transport.model)
    end
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
