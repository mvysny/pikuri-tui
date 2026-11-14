# frozen_string_literal: true

RSpec.describe Shared::FanoutListener do
  let(:first)  { Pikuri::Agent::Listener::InMemoryEventList.new }
  let(:second) { Pikuri::Agent::Listener::InMemoryEventList.new }
  let(:event)  { Pikuri::Agent::Event::Cancelled.new }

  it 'hands every event to each listener, in order' do
    order = []
    first.define_singleton_method(:on_event) { |_| order << :first }
    second.define_singleton_method(:on_event) { |_| order << :second }
    described_class.new([first, second]).on_event(event)
    assert_equal %i[first second], order
  end

  it "builds a sub-agent's fan-out from each listener's own variant, dropping those that opt out" do
    replaced = Pikuri::Agent::Listener::InMemoryEventList.new
    first.define_singleton_method(:for_sub_agent) { |**| replaced }
    second.define_singleton_method(:for_sub_agent) { |**| nil }
    shared = Pikuri::Agent::Listener::InMemoryEventList.new # no for_sub_agent: kept by reference

    described_class.new([first, second, shared]).for_sub_agent(id: 'x').on_event(event)

    assert_equal [event], replaced.events
    assert_empty first.events
    assert_empty second.events
    assert_equal [event], shared.events
  end
end
