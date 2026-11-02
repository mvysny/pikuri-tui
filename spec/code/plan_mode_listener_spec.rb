# frozen_string_literal: true

RSpec.describe Code::PlanModeListener do
  # Minimal status-rule stand-in: the listener only touches +plan_active=+.
  let(:status_rule) { Struct.new(:plan_active).new }
  let(:listener) { described_class.new(status_rule: status_rule, screen: Tuile::Screen.instance) }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  it 'pushes the new posture (true) onto the status rule' do
    listener.on_event(Pikuri::Code::PlanModeChanged.new(active: true))
    Tuile::Testing.loop
    assert_equal true, status_rule.plan_active
  end

  it 'pushes the new posture (false) onto the status rule' do
    status_rule.plan_active = true
    listener.on_event(Pikuri::Code::PlanModeChanged.new(active: false))
    Tuile::Testing.loop
    assert_equal false, status_rule.plan_active
  end

  it 'ignores every non-PlanModeChanged event' do
    listener.on_event(tool_result('noise'))
    Tuile::Testing.loop
    assert_nil status_rule.plan_active
  end
end
