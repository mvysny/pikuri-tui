# frozen_string_literal: true

RSpec.describe Shared::Model::Listener do
  # Minimal footer stand-in: the listener only touches +current_model=+.
  let(:footer) { Struct.new(:current_model).new }
  # Keyed on [model, api_base] (Shared::Model::Choice.key), not the model id alone.
  let(:names)  { { ['big-model', 'http://cloud/v1'] => 'Big Cloud' } }
  let(:listener) do
    described_class.new(footer: footer, screen: Tuile::Screen.instance, names: names)
  end

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  def transport(model, api_base: 'http://cloud/v1')
    Pikuri::Agent::ChatTransport.new(
      model: model, provider: :openai, assume_model_exists: true,
      api_base: api_base, api_key: 'k'
    )
  end

  def switched(to_model, api_base: 'http://cloud/v1')
    Pikuri::Agent::Event::ModelSwitched.new(
      from: Pikuri::Agent::ChatTransport.new(model: 'small'),
      to: transport(to_model, api_base: api_base)
    )
  end

  it 'pushes the switched-to model name (resolved via the names map) onto the footer' do
    listener.on_event(switched('big-model'))
    assert_equal 'Big Cloud', footer.current_model
  end

  it 'falls back to the raw model id when the names map has no entry' do
    listener.on_event(switched('mystery-model'))
    assert_equal 'mystery-model', footer.current_model
  end

  it 'distinguishes connections sharing a model id on different servers' do
    names[['big-model', 'http://other/v1']] = 'Other Cloud'
    listener.on_event(switched('big-model', api_base: 'http://other/v1'))
    assert_equal 'Other Cloud', footer.current_model
  end

  it 'ignores every non-ModelSwitched event' do
    listener.on_event(Pikuri::Agent::Event::ToolResult.new(content: 'noise'))
    assert_nil footer.current_model
  end
end
