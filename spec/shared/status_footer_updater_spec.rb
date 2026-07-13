# frozen_string_literal: true

RSpec.describe Shared::StatusFooterUpdater do
  let(:token_log)   { Pikuri::Agent::Listener::TokenLog.new }
  let(:event_queue) { Tuile::Screen.instance.event_queue }
  let(:window)      { Tuile::Component::Window.new }
  let(:label)       { described_class.new(screen: Tuile::Screen.instance, window: window, token_log: token_log) }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  def tokens(input: 0, output: 0, cached: 0, cache_creation: 0)
    Pikuri::Agent::Event::Tokens.new(
      input: input, output: output, cached: cached, cache_creation: cache_creation,
      thinking: 0, model_id: nil
    )
  end

  # The chrome the composer keeps current on the window's bottom border.
  def footer_text
    window.footer_text
  end

  it 'starts empty before any Tokens event arrives (no spinner, no status)' do
    label
    assert_equal '', footer_text.to_s
  end

  it 'renders the current model name as the leading segment once set' do
    label.current_model = 'Local Qwen'
    assert_equal ' Local Qwen ', footer_text.to_s
  end

  it 'puts the model name ahead of the token status' do
    label.current_model = 'Local Qwen'
    token_log.on_event(tokens(input: 1024, cached: 9216, output: 1024))
    label.send(:refresh)
    assert_match(/\A Local Qwen · msg #1: ctx=11.0k/, footer_text.to_s)
  end

  it 'drops the model segment when set back to nil' do
    label.current_model = 'Local Qwen'
    label.current_model = nil
    assert_equal '', footer_text.to_s
  end

  describe 'a transport handed to #current_model=' do
    # Keyed on [model, api_base] (Shared::Model::Choice.key), not the model id alone.
    let(:names) { { ['big-model', 'http://cloud/v1'] => 'Big Cloud' } }
    let(:label) do
      described_class.new(screen: Tuile::Screen.instance, window: window, token_log: token_log, names: names)
    end

    def transport(model, api_base: 'http://cloud/v1')
      Pikuri::Agent::ChatTransport.new(
        model: model, provider: :openai, assume_model_exists: true,
        api_base: api_base, api_key: 'k'
      )
    end

    it 'resolves to the display name from the names map' do
      label.current_model = transport('big-model')
      assert_equal ' Big Cloud ', footer_text.to_s
    end

    it 'falls back to the raw model id when the names map has no entry' do
      label.current_model = transport('mystery-model')
      assert_equal ' mystery-model ', footer_text.to_s
    end

    it 'distinguishes connections sharing a model id on different servers' do
      names[['big-model', 'http://other/v1']] = 'Other Cloud'
      label.current_model = transport('big-model', api_base: 'http://other/v1')
      assert_equal ' Other Cloud ', footer_text.to_s
    end

    # The footer duck-types as an agent listener: a ModelSwitched event
    # re-points current_model to the switched-to transport (resolved via
    # names); every other event is ignored.
    it 're-points the model on a ModelSwitched event (#on_event)' do
      switched = Pikuri::Agent::Event::ModelSwitched.new(
        from: Pikuri::Agent::ChatTransport.new(model: 'small'),
        to: transport('big-model')
      )
      label.on_event(switched)
      assert_equal ' Big Cloud ', footer_text.to_s
    end

    it 'ignores non-ModelSwitched events (#on_event)' do
      label.on_event(Pikuri::Agent::Event::ToolResult.new(content: 'noise'))
      assert_equal '', footer_text.to_s
    end
  end

  it 'renders the plan-mode badge when active (even with nothing else set)' do
    label.plan_active = true
    assert_equal ' ‖ Plan Mode ', footer_text.to_s
  end

  it 'leads with the plan-mode badge, ahead of the model name' do
    label.current_model = 'Local Qwen'
    label.plan_active = true
    assert_equal ' ‖ Plan Mode · Local Qwen ', footer_text.to_s
  end

  it 'drops the plan-mode badge when cleared' do
    label.current_model = 'Local Qwen'
    label.plan_active = true
    label.plan_active = false
    assert_equal ' Local Qwen ', footer_text.to_s
  end

  it "reflects the TokenLog's status_line once an event has been processed" do
    # Event fired before the label exists (the lazy let hasn't constructed
    # it, so the on_status_line observer isn't installed yet) — asserts
    # the poll path: refresh reads TokenLog#status_line directly.
    token_log.on_event(tokens(input: 1024, cached: 9216, output: 1024))
    label.send(:refresh)
    assert_includes footer_text.to_s, 'msg #1: ctx=11.0k'
  end

  it 'pads non-empty text with one space on each side (breathing room against the border)' do
    token_log.on_event(tokens(input: 1024, cached: 9216, output: 1024))
    label.send(:refresh)
    assert_match(/\A \S.*\S \z/, footer_text.to_s)
  end

  it 'refreshes immediately when the TokenLog pushes a new status line (no tick needed)' do
    label # construct first so the on_status_line observer is installed
    token_log.on_event(tokens(input: 1024, cached: 9216, output: 1024))
    assert_includes footer_text.to_s, 'msg #1: ctx=11.0k'
  end

  it 'keeps the current spinner glyph when a push lands between ticks' do
    label.start_animation
    event_queue.tick_once
    glyph = footer_text.to_s.strip
    token_log.on_event(tokens(input: 1024, cached: 9216, output: 1024))
    assert_equal " #{glyph} msg #1: ctx=11.0k  Δ+11.0k  ↑1.0k  ↓1.0k ", footer_text.to_s
  ensure
    label.stop_animation
  end

  it 'surfaces a sub-agent push in the token slot, labeled with its id' do
    label # construct first so the on_status_line observer is installed
    sub_log = token_log.for_sub_agent(id: 'researcher 0')
    sub_log.on_event(tokens(input: 1024, cached: 3072, output: 1024))
    assert_includes footer_text.to_s, '⤷ researcher 0  msg #1: ctx=5.0k'
  end

  it 'reverts to the main agent line once the main agent emits its next push' do
    label
    sub_log = token_log.for_sub_agent(id: 'researcher 0')
    sub_log.on_event(tokens(input: 1024, cached: 3072, output: 1024))
    token_log.on_event(tokens(input: 1024, cached: 9216, output: 1024))
    text = footer_text.to_s
    assert_includes text, 'msg #1: ctx=11.0k'
    refute_includes text, 'researcher 0'
  end

  it 'shows a spinner glyph + status after a tick lands' do
    token_log.on_event(tokens(input: 1024, cached: 9216, output: 1024))
    label.start_animation
    event_queue.tick_once
    assert_match(/\A [#{described_class::SPINNER.join}] msg #1: ctx=11\.0k/, footer_text.to_s)
  ensure
    label.stop_animation
  end

  it 'advances through SPINNER frames across successive ticks' do
    label.start_animation
    described_class::SPINNER.each do |expected_glyph|
      event_queue.tick_once
      assert_equal " #{expected_glyph} ", footer_text.to_s
    end
  ensure
    label.stop_animation
  end

  it 'settles back to the spinner-less status when stop_animation is called' do
    token_log.on_event(tokens(input: 1024, cached: 9216, output: 1024))
    label.start_animation
    event_queue.tick_once
    label.stop_animation
    refute_match(/[#{described_class::SPINNER.join}]/, footer_text.to_s)
    assert_includes footer_text.to_s, 'msg #1: ctx=11.0k'
  end

  it 'shows just the spinner (no token text) when running but TokenLog is still empty' do
    label.start_animation
    event_queue.tick_once
    assert_match(/\A [#{described_class::SPINNER.join}] \z/, footer_text.to_s)
  ensure
    label.stop_animation
  end

  it 'appends an "N queued" segment while the interloper holds pending injections' do
    interloper = Pikuri::Agent::Control::Interloper.new
    label.interloper = interloper
    interloper.inject_user_message('hold this')
    label.start_animation
    event_queue.tick_once
    assert_match(/\A [#{described_class::SPINNER.join}] 1 queued \z/, footer_text.to_s)
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
    assert_includes footer_text.to_s, '2 queued · msg #1: ctx=11.0k'
  end

  it 'drops the queued segment once the interloper is drained' do
    interloper = Pikuri::Agent::Control::Interloper.new
    label.interloper = interloper
    interloper.inject_user_message('soon gone')
    label.send(:refresh)
    assert_includes footer_text.to_s, '1 queued'

    interloper.drain!
    label.send(:refresh)
    assert_equal '', footer_text.to_s
  end

  it 'renders no queued segment when no interloper was installed (host wired none)' do
    token_log.on_event(tokens(input: 1024, cached: 9216, output: 1024))
    label.send(:refresh)
    refute_includes footer_text.to_s, 'queued'
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
    assert_equal '', footer_text.to_s
  end

  it 'bakes the current theme hint_color into the text (footer text is status-hint chrome)' do
    token_log.on_event(tokens(input: 1024, cached: 9216, output: 1024))
    label.send(:refresh)
    hint = Tuile::Screen.instance.theme.hint_color
    refute_empty footer_text.spans
    assert(footer_text.spans.all? { |span| span.style.fg == hint })
  end

  it 'restyles when the window on_theme_changed listener fires after a theme flip' do
    label # construct first: refresh bakes the FakeScreen default (DARK) hint color in, and
    # claims the window's on_theme_changed listener slot.
    token_log.on_event(tokens(input: 1024, cached: 9216, output: 1024))

    Tuile::Screen.instance.theme = Tuile::Theme::LIGHT
    window.on_theme_changed # Screen#theme= fires this tree-wide; here we drive it directly
    assert(footer_text.spans.all? { |span| span.style.fg == Tuile::Theme::LIGHT.hint_color })
  end

  it 'paints on the terminal-default background (no hardcoded bar)' do
    token_log.on_event(tokens(input: 1024, cached: 9216, output: 1024))
    label.send(:refresh)
    assert(footer_text.spans.all? { |span| span.style.bg.nil? })
  end
end
