# frozen_string_literal: true

RSpec.describe Shared::StatusFooterUpdater::ModelListener do
  # Minimal footer stand-in: the listener only touches +current_model=+. It
  # now hands the raw transport straight through — name resolution lives on
  # the real footer's +current_model=+ (see status_footer_updater_spec).
  let(:footer) { Struct.new(:current_model).new }
  let(:listener) do
    described_class.new(footer: footer, screen: Tuile::Screen.instance)
  end

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  def switched(to_model)
    Pikuri::Agent::Event::ModelSwitched.new(
      from: Pikuri::Agent::ChatTransport.new(model: 'small'),
      to: Pikuri::Agent::ChatTransport.new(
        model: to_model, provider: :openai, assume_model_exists: true,
        api_base: 'http://cloud/v1', api_key: 'k'
      )
    )
  end

  it 'passes the switched-to transport onto the footer' do
    event = switched('big-model')
    listener.on_event(event)
    assert_same event.to, footer.current_model
  end

  it 'ignores every non-ModelSwitched event' do
    listener.on_event(Pikuri::Agent::Event::ToolResult.new(content: 'noise'))
    assert_nil footer.current_model
  end
end
