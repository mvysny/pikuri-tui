# frozen_string_literal: true

RSpec.describe Shared::Model::Picker do
  # Stated +modalities+ (+{}+, "reports nothing") keep a pick from looking
  # them up over HTTP; pass +nil+ to have it look.
  def model_choice(name, model, api_base: 'http://x/v1', params: {}, modalities: {})
    Shared::Model::Choice.new(
      name: name,
      transport: Pikuri::Agent::ChatTransport.new(
        model: model, provider: :openai, assume_model_exists: true,
        api_base: api_base, api_key: 'k', params: params, modalities: modalities
      )
    )
  end

  # Swap +ChatTransport#with_detected_modalities+ for one answering
  # +modalities+ without HTTP once +gate+ is fed (restored after).
  def stub_detection(modalities, gate)
    klass = Pikuri::Agent::ChatTransport
    original = klass.instance_method(:with_detected_modalities)
    klass.define_method(:with_detected_modalities) do
      gate.pop
      with(modalities: modalities)
    end
    yield
  ensure
    klass.define_method(:with_detected_modalities, original)
  end

  # Swap +PickerDialog.new+ for a recorder whose popup never opens (restored
  # after) and return the captured +[options, callback]+ so a spec can assert
  # the option list and drive selection without exercising Tuile's popup /
  # focus machinery.
  def capture_picker
    original = Tuile::Component::PickerDialog.method(:new)
    captured_options = nil
    captured_block = nil
    Tuile::Component::PickerDialog.define_singleton_method(:new) do |_caption, options, &block|
      captured_options = options
      captured_block = block
      Struct.new(:open).new
    end
    yield
    [captured_options, captured_block]
  ensure
    Tuile::Component::PickerDialog.define_singleton_method(:new, original)
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
    it 'maps Shared::Model::Choice.key ([model, api_base, params]) to the display name' do
      assert_equal({ ['m1', 'http://x/v1', {}] => 'Local', ['m2', 'http://x/v1', {}] => 'Cloud' }, picker.names)
    end

    # Two entries on one model and one box, differing only in params (the
    # titler recipe): both stay in the map, so the status rule names whichever
    # is actually running rather than the last one declared.
    it 'keeps both of a pair that differs only in params' do
      pair = [model_choice('Qwen', 'm1'),
              model_choice('Qwen, no thinking', 'm1', params: { chat_template_kwargs: { enable_thinking: false } })]
      assert_equal ['Qwen', 'Qwen, no thinking'], described_class.new(models: pair).names.values
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

    it 'cancels a pending switch when the running model is picked' do
      _, block = capture_picker { picker.open(current: choices[0].transport) }
      block.call('2')
      _, block = capture_picker { picker.open(current: choices[0].transport) }
      block.call('1')
      assert_nil picker.pending
    end

    describe 'modalities lookup' do
      let(:choices) { [model_choice('Local', 'm1'), model_choice('Blind', 'm2', modalities: nil)] }
      let(:gate) { Queue.new }

      before { Tuile::Screen.fake }
      after  { Tuile::Screen.close }

      it 'makes the detected transport the pending one once the server answers' do
        stub_detection({ vision: false }, gate) do
          _, block = capture_picker { picker.open(current: choices[0].transport) }
          block.call('2')
          assert_nil picker.pending.modalities
          gate << :go
          wait_until { picker.pending.modalities }
          assert_equal({ vision: false }, picker.pending.modalities)
          assert_equal 'm2', picker.pending.model
        end
      end

      it 'drops an answer for a pick no longer pending' do
        stub_detection({ vision: false }, gate) do
          _, block = capture_picker { picker.open(current: choices[0].transport) }
          block.call('2')
          picker.take_pending
          gate << :go
          sleep 0.05
          Tuile::Testing.loop
          assert_nil picker.pending
        end
      end
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
      block.call('2')
      assert_equal choices[1].transport, picker.take_pending
      assert_nil picker.take_pending, 'a pick applies at most once'
    end

    it 'ignores an out-of-range pick' do
      _, block = capture_picker { picker.open(current: choices[0].transport) }
      block.call('9')
      assert_nil picker.take_pending
    end
  end
end
