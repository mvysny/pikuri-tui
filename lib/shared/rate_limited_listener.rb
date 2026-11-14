# frozen_string_literal: true

require 'pikuri-core'

# Coalesces streaming deltas ({Pikuri::Agent::Event::AssistantDelta},
# {Pikuri::Agent::Event::ThinkingDelta}) into at most +fps+ events a second
# before they reach +inner+; every other event flows straight through.
#
#   listener = Shared::RateLimitedListener.new(view.listener, fps: 15)
#   # 60 deltas/s from a fast llama.cpp → 15 Markdown re-renders/s in the pane
#
# A buffered delta is dropped when its own bookend (+Assistant+ / +Thinking+)
# arrives, since the bookend carries the whole text and the inner listener
# re-renders from it; any other event — a tool call, the conversation's
# +PendingChanged+ as the user types mid-turn — first flushes what is buffered,
# so the stream reaches the pane whole and in order.
#
# == Implementation details
#
# The tick schedule is anchored at construction, not at the first delta, so
# stream-startup latency doesn't leak into the cadence; after a flush it
# advances by whole periods, so a long-idle stream doesn't backlog ticks.
# Assistant and thinking deltas buffer independently.
#
# A conversation reaches its listener from more than one thread — the turn
# thread, and the UI thread for a cancel — so every event is handled under one
# lock, +inner+'s +on_event+ included. That suits an inner listener which only
# marshals onto the UI thread and returns.
#
# Thread-safe.
class Shared::RateLimitedListener < Pikuri::Agent::Listener::Base
  # @param inner [Pikuri::Agent::Listener::Base] where the coalesced stream goes.
  # @param fps [Integer, Float] the cap on delta events a second; positive.
  # @param clock [Proc] zero-arg → monotonic seconds; a spec's seam.
  # @raise [ArgumentError] if +fps+ is not positive.
  def initialize(inner, fps:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    super()
    raise ArgumentError, "fps must be positive, got #{fps.inspect}" unless fps.positive?

    @inner = inner
    @fps = fps
    @period = 1.0 / fps
    @clock = clock
    @next_tick_at = clock.call
    @assistant_buffer = String.new
    @thinking_buffer = String.new
    @lock = Mutex.new
  end

  # @param event [Object] any agent or conversation event.
  # @return [void]
  def on_event(event)
    @lock.synchronize { handle(event) }
  end

  # Wraps the inner listener's sub-agent variant in a fresh limiter with the
  # same knobs; +nil+ when the inner one opts out.
  #
  # @param params [Hash{Symbol => Object}] forwarded to the inner's +for_sub_agent+.
  # @return [Shared::RateLimitedListener, nil]
  def for_sub_agent(**params)
    inner_sub = @inner.respond_to?(:for_sub_agent) ? @inner.for_sub_agent(**params) : @inner
    return nil if inner_sub.nil?

    self.class.new(inner_sub, fps: @fps, clock: @clock)
  end

  # @return [String] e.g. +"RateLimited(15fps, Listener)"+.
  def to_s = "RateLimited(#{@fps}fps, #{@inner})"

  private

  # @param event [Object]
  # @return [void]
  def handle(event)
    case event
    when Pikuri::Agent::Event::AssistantDelta
      @assistant_buffer << event.content
      tick
    when Pikuri::Agent::Event::ThinkingDelta
      @thinking_buffer << event.content
      tick
    when Pikuri::Agent::Event::Assistant
      flush_thinking
      @assistant_buffer.clear
      @inner.on_event(event)
    when Pikuri::Agent::Event::Thinking
      @thinking_buffer.clear
      flush_assistant
      @inner.on_event(event)
    else
      flush_thinking
      flush_assistant
      @inner.on_event(event)
    end
  end

  # @return [void]
  def tick
    now = @clock.call
    return if now < @next_tick_at

    flush_thinking
    flush_assistant
    missed = ((now - @next_tick_at) / @period).floor + 1
    @next_tick_at += missed * @period
  end

  # @return [void]
  def flush_assistant
    return if @assistant_buffer.empty?

    @inner.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: @assistant_buffer.dup))
    @assistant_buffer.clear
  end

  # @return [void]
  def flush_thinking
    return if @thinking_buffer.empty?

    @inner.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: @thinking_buffer.dup))
    @thinking_buffer.clear
  end
end
