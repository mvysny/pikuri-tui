# frozen_string_literal: true

RSpec.describe Shared::RateLimitedListener do
  let(:inner) { Pikuri::Agent::Listener::InMemoryEventList.new }
  let(:clock_time) { [0.0] }
  let(:listener) { described_class.new(inner, fps: 10, clock: -> { clock_time[0] }) }

  def advance(seconds) = clock_time[0] += seconds
  def assistant_delta(text) = Pikuri::Agent::Event::AssistantDelta.new(content: text)
  def thinking_delta(text) = Pikuri::Agent::Event::ThinkingDelta.new(content: text)
  def contents = inner.events.map(&:content)

  it 'flushes the first delta at once, then coalesces the rest of the period into one event' do
    listener.on_event(assistant_delta('hel'))
    advance(0.05)
    listener.on_event(assistant_delta('lo'))
    assert_equal ['hel'], contents

    advance(0.06) # crosses the 0.1 s tick
    listener.on_event(assistant_delta('!'))
    assert_equal %w[hel lo!], contents
  end

  it 'buffers assistant and thinking deltas apart' do
    listener.on_event(assistant_delta('A1'))
    listener.on_event(thinking_delta('T1'))
    advance(0.1)
    listener.on_event(assistant_delta('A2'))

    assert_equal %w[A1 A2], inner.events.grep(Pikuri::Agent::Event::AssistantDelta).map(&:content)
    assert_equal %w[T1], inner.events.grep(Pikuri::Agent::Event::ThinkingDelta).map(&:content)
  end

  it 'catches up past missed ticks after a long pause instead of backlogging them' do
    advance(5.0)
    listener.on_event(assistant_delta('a'))
    advance(0.05)
    listener.on_event(assistant_delta('b'))
    assert_equal ['a'], contents
  end

  it 'drops a buffered delta when its own bookend arrives — the bookend carries the whole text' do
    listener.on_event(assistant_delta('A1'))
    listener.on_event(assistant_delta('A2'))
    listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'A1A2'))
    assert_equal %w[A1 A1A2], contents
  end

  # The conversation's own events cross the stream mid-reply — PendingChanged
  # as the user types — and must not cost the pane any streamed text.
  it 'flushes buffered deltas, in order, ahead of any other event' do
    listener.on_event(assistant_delta('A1'))
    listener.on_event(assistant_delta('A2'))
    pending = Pikuri::Conversations::Event::PendingChanged.new(count: 1)
    listener.on_event(pending)

    assert_equal [assistant_delta('A1'), assistant_delta('A2'), pending], inner.events
  end

  it 'rejects a non-positive fps' do
    assert_raises(ArgumentError) { described_class.new(inner, fps: 0) }
  end

  it "wraps the inner listener's sub-agent variant, or opts out with it" do
    sub_inner = Pikuri::Agent::Listener::InMemoryEventList.new
    inner.define_singleton_method(:for_sub_agent) { |**| sub_inner }
    sub = listener.for_sub_agent(id: 'researcher 0')
    sub.on_event(Pikuri::Agent::Event::Cancelled.new)
    assert_equal [Pikuri::Agent::Event::Cancelled.new], sub_inner.events

    inner.define_singleton_method(:for_sub_agent) { |**| nil }
    assert_nil listener.for_sub_agent
  end
end
