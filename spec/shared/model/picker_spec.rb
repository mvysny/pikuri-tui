# frozen_string_literal: true

RSpec.describe Shared::Model::Picker do
  # Stated +modalities+ (+{}+, "reports nothing") keep a pick from looking
  # them up; pass +nil+ to have it look.
  def model_choice(name, model, api_base: 'http://x/v1', params: {}, modalities: {})
    Shared::Model::Choice.new(
      name: name,
      transport: Pikuri::Agent::ChatTransport.new(
        model: model, provider: :openai, assume_model_exists: true,
        api_base: api_base, api_key: 'k', params: params, modalities: modalities
      )
    )
  end

  # A real conversation, never booted: a pick lands in +switch_model+, and
  # +status.next_model+ reads it back.
  let(:conversations) { Pikuri::Conversations.new(system_prompt: 'You are terse.') }
  let(:session) do
    conversations.open(id: 'c', transport: choices[0].transport, listener: Pikuri::Agent::Listener::Base.new,
                       boot: false)
  end

  after { conversations.shutdown(timeout: 1) }

  def next_model = session.status.next_model

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
    it 'numbers entries and flags the one the next turn runs on' do
      options, = capture_picker { picker.open(session: session) }

      assert_equal '1', options[0][0]
      assert_match(/●\s*Local/, options[0][1])
      refute_match(/●/, options[1][1])
    end

    it "switches the conversation's next turn to the picked connection" do
      _, block = capture_picker { picker.open(session: session) }
      block.call('2')
      assert_equal 'm2', next_model.model
    end

    it 'flags a pending pick when reopened' do
      _, block = capture_picker { picker.open(session: session) }
      block.call('2')
      options, = capture_picker { picker.open(session: session) }
      assert_match(/●\s*Cloud/, options[1][1])
    end

    it 'undoes a pending switch when the running model is picked' do
      _, block = capture_picker { picker.open(session: session) }
      block.call('2')
      _, block = capture_picker { picker.open(session: session) }
      block.call('1')
      assert_equal 'm1', next_model.model
    end

    it 'leaves the model alone when the popup is dismissed (block never called)' do
      capture_picker { picker.open(session: session) }
      assert_equal 'm1', next_model.model
    end

    it 'ignores an out-of-range pick' do
      _, block = capture_picker { picker.open(session: session) }
      block.call('9')
      assert_equal 'm1', next_model.model
    end

    it 'looks up which inputs a picked model takes, so a refusal is known before its turn' do
      blind = [model_choice('Local', 'm1'), model_choice('Blind', 'm2', modalities: nil)]
      picker = described_class.new(models: blind)
      Pikuri::Conversations::Probe::Detector.define_singleton_method(:detect_modalities) { |*, **| { vision: false } }
      _, block = capture_picker { picker.open(session: session) }
      block.call('2')
      wait_until { next_model.modalities }
      assert_equal({ vision: false }, next_model.modalities)
    end

    # Regression: two connections on the same model id but different servers
    # must not both flag. Keyed on the model id alone, both got the marker.
    it 'flags only the active one among same-model-different-server entries' do
      pair = [model_choice('Local Qwen', 'qwen3', api_base: 'http://localhost:8080/v1'),
              model_choice('Remote Qwen', 'qwen3', api_base: 'http://mavi-fw:8080/v1')]
      picker = described_class.new(models: pair)
      session = conversations.open(id: 'pair', transport: pair[1].transport,
                                   listener: Pikuri::Agent::Listener::Base.new, boot: false)
      options, = capture_picker { picker.open(session: session) }

      refute_match(/●/, options[0][1], 'the inactive same-model connection must not flag')
      assert_match(/●\s*Remote Qwen/, options[1][1])
    end
  end
end
