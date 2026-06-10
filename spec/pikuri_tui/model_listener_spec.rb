# frozen_string_literal: true

RSpec.describe PikuriTui::ModelListener do
  # Minimal footer stand-in: the listener only touches +current_model=+.
  let(:footer) { Struct.new(:current_model).new }
  let(:names)  { { 'big-model' => 'Big Cloud' } }
  let(:listener) do
    described_class.new(footer: footer, screen: Tuile::Screen.instance, names: names)
  end

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  def transport(model)
    Pikuri::Agent::ChatTransport.new(
      model: model, provider: :openai, assume_model_exists: true,
      api_base: 'http://cloud/v1', api_key: 'k'
    )
  end

  def switched(to_model)
    Pikuri::Agent::Event::ModelSwitched.new(
      from: Pikuri::Agent::ChatTransport.new(model: 'small'),
      to: transport(to_model)
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

  it 'ignores every non-ModelSwitched event' do
    listener.on_event(Pikuri::Agent::Event::ToolResult.new(content: 'noise'))
    assert_nil footer.current_model
  end
end
