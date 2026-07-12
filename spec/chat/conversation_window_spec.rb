# frozen_string_literal: true

RSpec.describe Chat::ConversationWindow do
  let(:token_log) { Pikuri::Agent::Listener::TokenLog.new }
  let(:window)    { described_class.new(screen: Tuile::Screen.instance, token_log: token_log) }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  it 'stands up from just a screen + token_log, as a titled Tuile Window' do
    assert_kind_of Tuile::Component::Window, window
    assert_equal 'Conversation', window.caption
  end

  it 'takes a custom title (the coding shell passes its project root)' do
    titled = described_class.new(screen: Tuile::Screen.instance, token_log: token_log, title: '/srv/app')
    assert_equal '/srv/app', titled.caption
  end

  it 'owns the transcript listener it exposes for the agent ListenerList' do
    assert_kind_of Shared::TuileListener, window.listener
  end

  it 'owns the footer model-name listener it exposes for the agent ListenerList' do
    assert_kind_of Shared::Model::Listener, window.model_listener
  end

  it 'drives its Shared::StatusLabel as border chrome, leaving the Window footer slot empty' do
    assert_kind_of Shared::StatusLabel, window.status_label
    assert_nil window.footer
  end

  it 'forwards current_model= to the footer' do
    window.current_model = 'Local Qwen'
    assert_equal 'Local Qwen', window.status_label.current_model
  end

  it 'forwards interloper= to the footer for the queued-count display' do
    interloper = Pikuri::Agent::Control::Interloper.new
    window.interloper = interloper
    assert_same interloper, window.status_label.interloper
  end

  it 'forwards markdown: through to its Shared::TuileListener' do
    plain = described_class.new(screen: Tuile::Screen.instance, token_log: token_log, markdown: false)
    assert_equal false, plain.listener.instance_variable_get(:@markdown)
  end

  it 'renders a caught turn error as an error-themed transcript line' do
    window.render_turn_error(RuntimeError.new('boom'))
    assert_includes window.view.text.to_s, 'RuntimeError'
    assert_includes window.view.text.to_s, 'boom'
  end
end
