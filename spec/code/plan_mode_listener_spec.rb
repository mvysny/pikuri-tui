# frozen_string_literal: true

RSpec.describe Code::PlanModeListener do
  # Minimal footer stand-in: the listener only touches +plan_active=+.
  let(:footer)   { Struct.new(:plan_active).new }
  let(:listener) { described_class.new(footer: footer, screen: Tuile::Screen.instance) }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  it 'pushes the new posture (true) onto the footer' do
    listener.on_event(Pikuri::Code::PlanModeChanged.new(active: true))
    assert_equal true, footer.plan_active
  end

  it 'pushes the new posture (false) onto the footer' do
    footer.plan_active = true
    listener.on_event(Pikuri::Code::PlanModeChanged.new(active: false))
    assert_equal false, footer.plan_active
  end

  it 'ignores every non-PlanModeChanged event' do
    listener.on_event(Pikuri::Agent::Event::ToolResult.new(content: 'noise'))
    assert_nil footer.plan_active
  end
end
