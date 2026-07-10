# frozen_string_literal: true

RSpec.describe PikuriTui::ModelPicker do
  def model_choice(name, model, api_base: 'http://x/v1')
    PikuriTui::ModelChoice.new(
      name: name,
      transport: Pikuri::Agent::ChatTransport.new(
        model: model, provider: :openai, assume_model_exists: true,
        api_base: api_base, api_key: 'k'
      )
    )
  end

  # Swap +PickerWindow.open+ for a recorder (restored after) and return the
  # captured +[options, callback]+ so a spec can assert the option list and
  # drive selection without exercising Tuile's popup / focus machinery.
  def capture_picker
    original = Tuile::Component::PickerWindow.method(:open)
    captured_options = nil
    captured_block = nil
    Tuile::Component::PickerWindow.define_singleton_method(:open) do |_caption, options, &block|
      captured_options = options
      captured_block = block
      nil
    end
    yield
    [captured_options, captured_block]
  ensure
    Tuile::Component::PickerWindow.define_singleton_method(:open, original)
  end

  let(:choices) { [model_choice('Local', 'm1'), model_choice('Cloud', 'm2')] }
  let(:picker)  { described_class.new(models: choices) }

  describe '#multiple?' do
    it 'is true with more than one connection' do
      assert picker.multiple?
    end

    it 'is false with one or zero connections' do
      refute described_class.new(models: [choices.first]).multiple?
      refute described_class.new(models: []).multiple?
    end
  end

  describe '#names' do
    it 'maps ModelChoice.key ([model, api_base]) to the display name' do
      assert_equal({ %w[m1 http://x/v1] => 'Local', %w[m2 http://x/v1] => 'Cloud' }, picker.names)
    end
  end

  describe '#display_name' do
    it 'resolves a transport to its connection name' do
      assert_equal 'Cloud', picker.display_name(choices[1].transport)
    end

    it 'falls back to the raw model id when the pair is not in the catalog' do
      stranger = model_choice('x', 'mystery', api_base: 'http://y/v1').transport
      assert_equal 'mystery', picker.display_name(stranger)
    end
  end

  describe '#open' do
    it 'numbers entries and flags the active one with a marker' do
      options, = capture_picker { picker.open(current: choices[0].transport) }

      assert_equal '1', options[0][0]
      assert_match(/●\s*Local/, options[0][1])
      refute_match(/●/, options[1][1])
    end

    it 'stashes the picked connection transport as pending' do
      _, block = capture_picker { picker.open(current: choices[0].transport) }
      block.call('2')
      assert_equal choices[1].transport, picker.take_pending
    end

    it 'leaves nothing pending when the popup is dismissed (block never called)' do
      capture_picker { picker.open(current: choices[0].transport) }
      assert_nil picker.take_pending
    end

    # Regression: two connections on the same model id but different servers
    # must not both flag. Keyed on the model id alone, both got the marker.
    it 'flags only the active one among same-model-different-server entries' do
      pair = [model_choice('Local Qwen', 'qwen3', api_base: 'http://localhost:8080/v1'),
              model_choice('Remote Qwen', 'qwen3', api_base: 'http://mavi-fw:8080/v1')]
      picker = described_class.new(models: pair)
      options, = capture_picker { picker.open(current: pair[1].transport) }

      refute_match(/●/, options[0][1], 'the inactive same-model connection must not flag')
      assert_match(/●\s*Remote Qwen/, options[1][1])
    end
  end

  describe '#take_pending' do
    it 'returns nil when nothing is pending' do
      assert_nil picker.take_pending
    end

    it 'returns the pending transport once, then clears it' do
      _, block = capture_picker { picker.open(current: choices[0].transport) }
      block.call('1')
      assert_equal choices[0].transport, picker.take_pending
      assert_nil picker.take_pending, 'a pick applies at most once'
    end

    it 'ignores an out-of-range pick' do
      _, block = capture_picker { picker.open(current: choices[0].transport) }
      block.call('9')
      assert_nil picker.take_pending
    end
  end
end
