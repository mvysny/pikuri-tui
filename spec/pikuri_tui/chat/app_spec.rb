# frozen_string_literal: true

RSpec.describe PikuriTui::Chat::App do
  # Minimal +Pikuri::Agent+ stand-in: App only reaches for +run_loop+
  # (from the worker thread, which we never trigger here) and +cancellable+
  # (from {Chat::App#cancel_turn}). Anything else stays untouched, so we
  # don't pay the network / RubyLLM cost in a unit spec.
  class StubAgent
    attr_reader :cancellable, :listener

    def initialize(listener)
      @listener = listener
      @cancellable = Pikuri::Agent::Control::Cancellable.new
    end

    def run_loop(user_message:); end
  end

  let(:app) do
    described_class.new do |listener|
      @listener = listener
      StubAgent.new(listener)
    end
  end

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  it 'mounts a Chat::Layout as the screen content with conversation + input panes' do
    layout = app.screen.pane.content
    assert_kind_of PikuriTui::Chat::Layout, layout
    assert_kind_of Tuile::Component::Window, layout.conversation
    assert_kind_of Tuile::Component::Window, layout.input
  end

  it 'focuses the input TextArea on boot so the user can start typing immediately' do
    assert_kind_of PikuriTui::Chat::Input, app.screen.focused
  end

  it 'eager-constructs the LogWindow (Pikuri.log_io routes through it from boot)' do
    assert_kind_of Tuile::Component::LogWindow, app.log_window
  end

  it 'hands the TuileListener to the build block (so the agent sees the conversation pane)' do
    app # force construction
    assert_kind_of PikuriTui::TuileListener, @listener
  end

  it 'starts with no errors logged and a discoverable "^L logs" status-bar hint' do
    app
    assert_includes status_bar_text, '^L logs'
    refute_includes status_bar_text, '⚠'
  end

  it 'also exposes the cancel intent as a "^C cancel" status-bar hint' do
    app
    assert_includes status_bar_text, '^C cancel'
  end

  it 'shows "^L ⚠ logs (N)" when an error is logged through Tuile.logger' do
    app
    Tuile.logger.error('boom')
    assert_includes status_bar_text, '^L ⚠ logs (1)'
  end

  it 'increments the hint counter once per error (not once per log line)' do
    app
    Tuile.logger.error('one')
    Tuile.logger.info('two')   # info shouldn't bump
    Tuile.logger.warn('three') # warn shouldn't bump either
    Tuile.logger.fatal('four') # fatal does (same bracket as error)
    assert_includes status_bar_text, '^L ⚠ logs (2)'
  end

  it 'clears the hint counter when the log popup is dismissed (user has now read the diagnostics)' do
    app
    Tuile.logger.error('boom')
    assert_includes status_bar_text, '^L ⚠ logs (1)'

    # Open the popup directly — same dispatch path as pressing Ctrl+L.
    log_popup = app.instance_variable_get(:@log_popup)
    log_popup.open
    log_popup.close
    assert_includes status_bar_text, '^L logs'
    refute_includes status_bar_text, '⚠'
  end

  it 'leaves the conversation Window without a footer (status moved to the status bar)' do
    app
    assert_nil app.screen.pane.content.conversation.footer
  end

  it 'routes pikuri-side log lines through the LogWindow (Pikuri.log_io rewired at boot)' do
    app
    Pikuri.logger_for('TestSubsystem').info('pikuri-side message')
    rendered = app.log_window.content.lines.map(&:to_s).join("\n")
    assert_includes rendered, 'pikuri-side message'
  end

  it 'installs an on_error handler that funnels uncaught exceptions to Tuile.logger' do
    app
    captured = StringIO.new
    Tuile.logger = Logger.new(captured)
    app.screen.on_error.call(RuntimeError.new('oops'))
    assert_includes captured.string, 'RuntimeError'
    assert_includes captured.string, 'oops'
  end

  private

  def status_bar_text
    app.screen.pane.status_bar.text.to_s
  end
end
