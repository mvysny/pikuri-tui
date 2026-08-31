# frozen_string_literal: true

require 'tuile'
require 'pikuri-core'

# The one-row rule separating the conversation pane from the prompt, carrying
# the agent's status readout. A busy rule reads:
#
#   ── ⠹ ‖ Plan Mode · ~/work/pikuri-tui · Local Qwen 3.6 · 2 queued · 25k/60k ──
#      <spinner> <plan mode?>  <context>     <model>      <queued>  <token stats>
#
# Empty segments drop out (chat never lights the badge; an idle agent shows no
# spinner) and with nothing at all to say the row is a plain hairline. During a
# long sub-agent delegation the token slot shows the delegate's own line
# instead, e.g. +⤷ researcher  8k/60k+, so the readout doesn't freeze while the
# main agent blocks in the +agent+ tool.
#
# Drive it with the setters and the spinner controls. It also duck-types as an
# agent listener via {#on_event} — fold it into the agent's +ListenerList+ and
# it re-points {#current_model} whenever a +run_loop+ model switch lands:
#
#   rule = Shared::StatusRuleLabel.new(token_log: token_log)
#   rule.current_model = 'Local Qwen 3.6'  # boot model
#   rule.interloper = agent.interloper     # enables the "N queued" segment
#   rule.plan_active = true                # lights the badge
#   rule.start_animation                   # spinner on for a turn; stop_animation after
#   config.add_listener(rule)              # re-points current_model on a switch
#
# +token_log+ must be the *same* {Pikuri::Agent::Listener::TokenLog} instance
# wired into the agent — the rule reads its cached +status_line+ rather than
# subscribing to events itself.
#
# This is a component rather than the presenter it grew out of: with the pane
# frames gone there is no +Window#footer_text+ chrome to drive, the rule is an
# addressable row of its own, and owning the widget is what buys the
# width-aware +─+ fill (+on_width_changed+) and the light/dark re-render
# (+on_theme_changed+) for free.
#
# Shared by all three shells.
#
# UI-thread-confined, with exceptions ({#on_event} and the token-log observer
# both self-marshal).
class Shared::StatusRuleLabel < Tuile::Component::Label
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

  # Hairline columns drawn before the status text, so the readout doesn't
  # start flush against the terminal's left edge.
  #
  # @return [Integer]
  LEAD = 2

  # The agent's mid-loop input queue; its +#size+ drives the "N queued"
  # segment. +nil+ until the host wires one.
  #
  # @return [Pikuri::Agent::Control::Interloper, nil]
  attr_reader :interloper

  # Display name shown as the readout's leading segment (after any badge);
  # +nil+/empty renders no model segment.
  #
  # @return [String, nil]
  attr_reader :current_model

  # Whether the agent is in plan mode; when +true+ the readout leads with a
  # notice-toned "‖ Plan Mode" badge.
  #
  # @return [Boolean]
  attr_reader :plan_active

  # Claims the +token_log.on_status_line+ observer slot.
  #
  # @param token_log [Pikuri::Agent::Listener::TokenLog] the agent's token
  #   log; must be the *same* instance wired into the agent (see class docs).
  # @param names [Hash{Array(String, String) => String}]
  #   {Shared::Model::Choice.key} → display name, used to resolve a transport
  #   passed to {#current_model=}; transports absent from the map render as
  #   their raw model id.
  # @param context [String, nil] a static leading segment naming what the agent
  #   is pointed at — the coding shell passes its project root, the chat and
  #   computer shells nothing. Unlike every other segment it never changes, so
  #   it is a constructor argument rather than a setter.
  def initialize(token_log:, names: {}, context: nil)
    super()
    @token_log = token_log
    @names = names
    @context = context
    @interloper = nil
    @current_model = nil
    @plan_active = false
    @sub_status = nil
    @ticker = nil
    @spinner_frame = nil
    token_log.on_status_line = method(:on_status_line)
    refresh
  end

  # @param interloper [Pikuri::Agent::Control::Interloper, nil] the agent's
  #   mid-loop input queue, whose size drives the "N queued" segment.
  # @return [void]
  def interloper=(interloper)
    @interloper = interloper
    refresh
  end

  # Set the model segment, from either a ready display name or a transport
  # to resolve. A transport is keyed on the +[model, api_base]+ pair
  # ({Shared::Model::Choice.key}), not the model id alone — two connections
  # can run the same model on different servers — and falls back to its raw
  # model id when absent from the +names+ map.
  #
  #   rule.current_model = 'Local Qwen 3.6'   # a literal name (boot seed)
  #   rule.current_model = agent.transport    # resolved via names:
  #
  # @param model [String, Pikuri::Agent::ChatTransport, nil] a display name
  #   shown verbatim, a transport resolved through +names+, or +nil+ to clear
  #   the segment.
  # @return [void]
  def current_model=(model)
    @current_model =
      model.is_a?(Pikuri::Agent::ChatTransport) ? display_name(model) : model
    refresh
  end

  # @param active [Boolean] new plan-mode posture.
  # @return [void]
  def plan_active=(active)
    @plan_active = active
    refresh
  end

  # Start the mid-turn spinner ticker; idempotent.
  #
  # @return [void]
  def start_animation
    return if @ticker

    @ticker = screen.event_queue.tick(FRAME_INTERVAL_S) do |tick|
      @spinner_frame = SPINNER[tick % SPINNER.length]
      refresh
    end
  end

  # Stop the spinner ticker and settle the rule back to idle; idempotent.
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

  # Agent-listener entry point (duck-typed — the rule plays the listener role
  # without subclassing +Pikuri::Agent::Listener::Base+): on a +run_loop+ model
  # switch ({Pikuri::Agent::Event::ModelSwitched}), re-points {#current_model}
  # to the switched-to transport; ignores every other event. Fold the rule into
  # the agent's +ListenerList+ for this.
  #
  # Safe from any thread: invoked on the agent's worker thread, it marshals the
  # {#current_model=} back onto the UI thread via +screen.event_queue.submit+.
  #
  # @param event [Pikuri::Agent::Event::Base] any agent event; only
  #   {Pikuri::Agent::Event::ModelSwitched} is acted on.
  # @return [void]
  def on_event(event)
    return unless event.is_a?(Pikuri::Agent::Event::ModelSwitched)

    screen.event_queue.submit { self.current_model = event.to }
  end

  # @return [String] short label used by +Pikuri::Agent#to_s+ when the rule
  #   is in its +ListenerList+.
  def to_s = 'Shared::StatusRuleLabel'

  protected

  # Re-renders at the new width — the +─+ fill is width-derived.
  # @return [void]
  def on_width_changed
    super
    refresh
  end

  # Re-renders against the new {Tuile::Screen#theme}, already in place when
  # this fires: the hairline and every segment tone are baked into the text.
  # @return [void]
  def on_theme_changed
    super
    refresh
  end

  private

  # Resolve a transport to its friendly connection name via +names+, falling
  # back to the raw model id when the +[model, api_base]+ pair isn't mapped.
  #
  # @param transport [Pikuri::Agent::ChatTransport]
  # @return [String]
  def display_name(transport)
    @names.fetch(Shared::Model::Choice.key(transport), transport.model)
  end

  # +TokenLog#on_status_line+ observer: stash a sub-agent's pushed line
  # (+id+ non-empty) for {#refresh} to show, or clear the stash on a
  # main-agent or empty line. We stash rather than poll because a sub-agent's
  # +TokenLog+ is a separate instance {#refresh} can't reach.
  #
  # Safe from any thread: the push arrives on the agent-loop thread, so it
  # marshals the stash and {#refresh} onto the UI thread via +submit+.
  #
  # @param id [String] owning agent's id; +""+ for the main agent.
  # @param status_line [String] the freshly formatted line.
  # @return [void]
  def on_status_line(id, status_line)
    screen.event_queue.submit do
      @sub_status =
        if id.empty? || status_line.empty?
          nil
        else
          "⤷ #{id}  #{status_line}"
        end
      refresh
    end
  end

  # Rebuild the row from the current state: {LEAD} hairline columns, the
  # readout (badge, spinner, queued count, token line) padded by a space on
  # each side, then hairline out to the right edge. With an empty readout the
  # row is one unbroken hairline.
  #
  # @return [void]
  def refresh
    readout = build_readout
    lead = hairline(LEAD)
    self.text =
      if readout.nil?
        hairline(rect.width)
      else
        # The pads are hint-toned rather than uncolored so the whole readout —
        # padding included — is one uniform run on the non-plan path.
        pad = Tuile::StyledString.plain(' ').with_fg(screen.theme.hint_color)
        body = lead + pad + readout + pad
        body + hairline(rect.width - body.display_width)
      end
  end

  # @param width [Integer] how many columns to fill; non-positive yields an
  #   empty string (a rule narrower than its own readout simply stops).
  # @return [Tuile::StyledString] +width+ hairline columns in the +:frame+ tone.
  def hairline(width)
    return Tuile::StyledString::EMPTY if width <= 0

    Tuile::StyledString.styled('─' * width, fg: screen.theme[:frame])
  end

  # The status readout: the plan-mode badge (notice-toned, so it pops against
  # the dim chrome) leading a hint-toned tail of spinner / model / queue /
  # tokens. Either side may be empty.
  #
  # @return [Tuile::StyledString, nil] +nil+ when there is nothing to say.
  def build_readout
    hint = screen.theme.hint_color
    tail = tail_text
    rest = Tuile::StyledString.plain(tail).with_fg(hint) unless tail.empty?
    return rest unless @plan_active

    badge = Tuile::StyledString.plain('‖ Plan Mode').with_fg(screen.theme[:notice])
    rest ? badge + Tuile::StyledString.plain(' · ').with_fg(hint) + rest : badge
  end

  # @return [String] the plain (uncolored) spinner + segment tail.
  def tail_text
    segments = []
    segments << @context if @context && !@context.empty?
    segments << @current_model if @current_model && !@current_model.empty?
    pending = @interloper ? @interloper.size : 0
    segments << "#{pending} queued" if pending.positive?
    # A running sub-agent's line takes the token slot (labeled with its id so
    # it reads as the delegate's context, not the conversation's); otherwise
    # the main agent's own snapshot.
    status = @sub_status || @token_log.status_line
    segments << status unless status.empty?
    tail = segments.join(' · ')
    return tail if @spinner_frame.nil?

    tail.empty? ? @spinner_frame : "#{@spinner_frame} #{tail}"
  end
end
