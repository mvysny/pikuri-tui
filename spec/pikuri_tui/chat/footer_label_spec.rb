# frozen_string_literal: true

RSpec.describe PikuriTui::Chat::FooterLabel do
  let(:token_log) { Pikuri::Agent::Listener::TokenLog.new }
  let(:label)     { described_class.new(screen: Tuile::Screen.instance, token_log: token_log) }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  def tokens(input: 0, output: 0, cached: 0, cache_creation: 0)
    Pikuri::Agent::Event::Tokens.new(
      input: input, output: output, cached: cached, cache_creation: cache_creation,
      thinking: 0, model_id: nil
    )
  end

  it 'starts empty before any Tokens event arrives (no spinner, no status)' do
    assert_equal '', label.text.to_s
  end

  it "reflects the TokenLog's status_line once an event has been processed" do
    token_log.on_event(tokens(input: 1024, cached: 9216, output: 1024))
    # FooterLabel doesn't subscribe to events itself — the App will call
    # +refresh+ via the animation thread; in idle mode we trigger a refresh
    # explicitly to assert the read path.
    label.send(:refresh)
    assert_includes label.text.to_s, 'msg #1: ctx=11.0k'
  end

  it 'shows a spinner glyph + status while the animation is running' do
    token_log.on_event(tokens(input: 1024, cached: 9216, output: 1024))
    label.start_animation
    # The animation thread submits frames; FakeEventQueue runs each block
    # synchronously, but the thread itself needs a moment to dispatch the
    # first one. Wait briefly, then assert.
    sleep 0.05 until label.text.to_s.match?(/\A[#{described_class::SPINNER.join}] /)
    assert_match(/\A[#{described_class::SPINNER.join}] msg #1: ctx=11\.0k/, label.text.to_s)
  ensure
    label.stop_animation
  end

  it 'settles back to the spinner-less status when stop_animation is called' do
    token_log.on_event(tokens(input: 1024, cached: 9216, output: 1024))
    label.start_animation
    label.stop_animation
    refute_match(/\A[#{described_class::SPINNER.join}]/, label.text.to_s)
    assert_includes label.text.to_s, 'msg #1: ctx=11.0k'
  end

  it 'shows just the spinner (no token text) when running but TokenLog is still empty' do
    label.start_animation
    sleep 0.05 until label.text.to_s.match?(/\A[#{described_class::SPINNER.join}]/)
    assert_match(/\A[#{described_class::SPINNER.join}]\z/, label.text.to_s)
  ensure
    label.stop_animation
  end

  it 'is idempotent: start_animation while already running does not spawn a second thread' do
    label.start_animation
    first_thread = label.instance_variable_get(:@thread)
    label.start_animation
    assert_same first_thread, label.instance_variable_get(:@thread)
  ensure
    label.stop_animation
  end
end
