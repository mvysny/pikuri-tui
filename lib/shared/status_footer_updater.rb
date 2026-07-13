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
# == Thread-safety
#
# UI-thread-confined, with exceptions.
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

  # The agent's mid-loop input queue; its +#size+ drives the "N queued"
  # segment. +nil+ until the host wires one.
  #
  # @return [Pikuri::Agent::Control::Interloper, nil]
  attr_accessor :interloper

  # Display name shown as the footer's leading segment (after any badge);
  # +nil+/empty renders no model segment.
  #
  # @return [String, nil]
  attr_reader :current_model

  # Whether the agent is in plan mode; when +true+ the footer leads with a
  # notice-toned "‖ Plan Mode" badge.
  #
  # @return [Boolean]
  attr_reader :plan_active

  # Claims the +token_log.on_status_line+ and +window.on_theme_changed+
  # observer slots.
  #
  # @param screen [Tuile::Screen] drives the spinner ticker via its
  #   +event_queue+.
  # @param window [Tuile::Component::Window] whose +footer_text+ this keeps
  #   current.
  # @param token_log [Pikuri::Agent::Listener::TokenLog] the agent's token
  #   log; must be the *same* instance wired into the agent (see class docs).
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

  # Start the mid-turn spinner ticker; idempotent.
  #
  # @return [void]
  def start_animation
    return if @ticker

    @ticker = @screen.event_queue.tick(FRAME_INTERVAL_S) do |tick|
      @spinner_frame = SPINNER[tick % SPINNER.length]
      refresh
    end
  end

  # Stop the spinner ticker and settle the footer back to idle; idempotent.
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
  # == Thread-safety
  #
  # A listener: {#on_event} is invoked on the agent's worker thread and
  # marshals the footer update onto the UI thread via +screen.event_queue.submit+.
  class ModelListener < Pikuri::Agent::Listener::Base
    # @param footer [Shared::StatusFooterUpdater] the footer to update.
    # @param screen [Tuile::Screen] marshals the update back from the worker
    #   thread via its +event_queue+.
    # @param names [Hash{Array(String, String) => String}]
    #   {Shared::Model::Choice.key} → display name; transports absent from the
    #   map render as their raw model id.
    def initialize(footer:, screen:, names: {})
      super()
      @footer = footer
      @screen = screen
      @names = names
    end

    # Push the switched-to model's display name onto the footer; ignore
    # every other event.
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

  # Rebuild the footer text from the current state (badge, spinner, queued
  # count, token line) and assign it to {Tuile::Component::Window#footer_text}.
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
