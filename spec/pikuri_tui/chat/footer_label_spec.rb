# frozen_string_literal: true

RSpec.describe PikuriTui::Chat::FooterLabel do
  let(:token_log)   { Pikuri::Agent::Listener::TokenLog.new }
  let(:event_queue) { Tuile::Screen.instance.event_queue }
  let(:label)       { described_class.new(screen: Tuile::Screen.instance, token_log: token_log) }

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
    # FooterLabel doesn't subscribe to events itself — the App drives the
    # idle text via start_animation/stop_animation; in idle mode we trigger
    # a refresh explicitly to assert the read path.
    label.send(:refresh)
    assert_includes label.text.to_s, 'msg #1: ctx=11.0k'
  end

  it 'shows a spinner glyph + status after a tick lands' do
    token_log.on_event(tokens(input: 1024, cached: 9216, output: 1024))
    label.start_animation
    event_queue.tick_once
    assert_match(/\A[#{described_class::SPINNER.join}] msg #1: ctx=11\.0k/, label.text.to_s)
  ensure
    label.stop_animation
  end

  it 'advances through SPINNER frames across successive ticks' do
    label.start_animation
    described_class::SPINNER.each do |expected_glyph|
      event_queue.tick_once
      assert_equal expected_glyph, label.text.to_s
    end
  ensure
    label.stop_animation
  end

  it 'settles back to the spinner-less status when stop_animation is called' do
    token_log.on_event(tokens(input: 1024, cached: 9216, output: 1024))
    label.start_animation
    event_queue.tick_once
    label.stop_animation
    refute_match(/\A[#{described_class::SPINNER.join}]/, label.text.to_s)
    assert_includes label.text.to_s, 'msg #1: ctx=11.0k'
  end

  it 'shows just the spinner (no token text) when running but TokenLog is still empty' do
    label.start_animation
    event_queue.tick_once
    assert_match(/\A[#{described_class::SPINNER.join}]\z/, label.text.to_s)
  ensure
    label.stop_animation
  end

  it 'appends an "N queued" segment while the interloper holds pending injections' do
    interloper = Pikuri::Agent::Control::Interloper.new
    label.interloper = interloper
    interloper.inject_user_message('hold this')
    label.start_animation
    event_queue.tick_once
    assert_match(/\A[#{described_class::SPINNER.join}] 1 queued\z/, label.text.to_s)
  ensure
    label.stop_animation
  end

  it 'joins the queued count and the token status with a separator' do
    token_log.on_event(tokens(input: 1024, cached: 9216, output: 1024))
    interloper = Pikuri::Agent::Control::Interloper.new
    label.interloper = interloper
    interloper.inject_user_message('one')
    interloper.inject_user_message('two')
    label.send(:refresh)
    assert_includes label.text.to_s, '2 queued · msg #1: ctx=11.0k'
  end

  it 'drops the queued segment once the interloper is drained' do
    interloper = Pikuri::Agent::Control::Interloper.new
    label.interloper = interloper
    interloper.inject_user_message('soon gone')
    label.send(:refresh)
    assert_includes label.text.to_s, '1 queued'

    interloper.drain!
    label.send(:refresh)
    assert_equal '', label.text.to_s
  end

  it 'renders no queued segment when no interloper was installed (host wired none)' do
    token_log.on_event(tokens(input: 1024, cached: 9216, output: 1024))
    label.send(:refresh)
    refute_includes label.text.to_s, 'queued'
  end

  it 'is idempotent: start_animation while already running keeps the same ticker' do
    label.start_animation
    first_ticker = label.instance_variable_get(:@ticker)
    label.start_animation
    assert_same first_ticker, label.instance_variable_get(:@ticker)
  ensure
    label.stop_animation
  end

  it 'cancels the ticker on stop_animation so subsequent ticks are no-ops' do
    label.start_animation
    ticker = label.instance_variable_get(:@ticker)
    label.stop_animation
    assert ticker.cancelled?
    event_queue.tick_once # no-op; would otherwise advance frame
    assert_equal '', label.text.to_s
  end
end
