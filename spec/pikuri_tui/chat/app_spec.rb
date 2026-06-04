# frozen_string_literal: true

RSpec.describe PikuriTui::Chat::App do
  # Minimal +Pikuri::Agent+ stand-in: App only reaches for +run_loop+
  # (from the worker thread), +cancellable+ (from {Chat::App#cancel_turn})
  # and +interloper+ (mid-turn queueing + the FooterLabel handoff).
  # Anything else stays untouched, so we don't pay the network / RubyLLM
  # cost in a unit spec.
  #
  # +run_loop+ records each +user_message:+ into {#messages}; after
  # {#block_turns!} it additionally parks on an internal queue until the
  # spec calls {#finish_turn!}, so a spec can hold a turn open and observe
  # the mid-turn paths.
  class StubAgent
    attr_reader :cancellable, :interloper, :listener, :messages

    def initialize(listener, interloper: Pikuri::Agent::Control::Interloper.new)
      @listener = listener
      @cancellable = Pikuri::Agent::Control::Cancellable.new
      @interloper = interloper
      @messages = []
      @gate = Queue.new
      @blocking = false
    end

    def block_turns! = @blocking = true

    def finish_turn! = @gate << :done

    def run_loop(user_message:)
      @messages << user_message
      @gate.pop if @blocking
    end
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

  it 'mounts a FooterLabel as the conversation Window footer (token status + spinner slot)' do
    app
    assert_kind_of PikuriTui::Chat::FooterLabel, app.screen.pane.content.conversation.footer
  end

  it "hands the agent's interloper to the FooterLabel for the queued-count display" do
    footer = app.screen.pane.content.conversation.footer
    assert_same app.agent.interloper, footer.interloper
  end

  it 'queues a mid-turn submission into the interloper instead of starting a second run_loop' do
    agent = app.agent
    agent.block_turns!
    app.send(:submit_message, 'first')
    wait_until { agent.messages.size == 1 }

    app.send(:submit_message, 'second')
    assert_equal ['second'], agent.interloper.peek
    assert_equal ['first'], agent.messages
  ensure
    # One release for the held turn, one for the leftover-delivery turn
    # the App starts with the drained 'second'; then wait for both turns
    # to settle so no worker outlives the screen the after-hook closes.
    2.times { agent.finish_turn! }
    wait_until { agent.messages.size == 2 && !app.instance_variable_get(:@turn_in_progress) }
  end

  it 'delivers injections still queued when the turn ends as a fresh turn (in order)' do
    agent = app.agent
    agent.block_turns!
    app.send(:submit_message, 'first')
    wait_until { agent.messages.size == 1 }

    app.send(:submit_message, 'queued while busy')
    agent.finish_turn!
    wait_until { agent.messages.size == 2 }
    assert_equal ['first', 'queued while busy'], agent.messages
    assert_empty agent.interloper.peek
  ensure
    agent.finish_turn! # release the leftover-delivery turn
    wait_until { !app.instance_variable_get(:@turn_in_progress) }
  end

  it 'joins multiple leftover injections into one delivery turn, in submission order' do
    agent = app.agent
    agent.block_turns!
    app.send(:submit_message, 'first')
    wait_until { agent.messages.size == 1 }

    app.send(:submit_message, 'also this')
    app.send(:submit_message, 'and this')
    agent.finish_turn!
    wait_until { agent.messages.size == 2 }
    assert_equal ['first', "also this\n\nand this"], agent.messages
  ensure
    agent.finish_turn! # release the leftover-delivery turn
    wait_until { !app.instance_variable_get(:@turn_in_progress) }
  end

  it 'drops a mid-turn submission with a warn when the agent has no interloper wired' do
    no_interloper_app = described_class.new do |listener|
      StubAgent.new(listener, interloper: nil)
    end
    agent = no_interloper_app.agent
    agent.block_turns!
    no_interloper_app.send(:submit_message, 'first')
    wait_until { agent.messages.size == 1 }

    no_interloper_app.send(:submit_message, 'second')
    agent.finish_turn!
    wait_until { !no_interloper_app.instance_variable_get(:@turn_in_progress) }
    assert_equal ['first'], agent.messages
    rendered = no_interloper_app.log_window.content.lines.map(&:to_s).join("\n")
    assert_includes rendered, 'mid-turn message dropped'
  end

  it 'feeds the FooterLabel from the same TokenLog the host wires into the agent' do
    explicit_token_log = Pikuri::Agent::Listener::TokenLog.new
    explicit_app = described_class.new(token_log: explicit_token_log) do |listener|
      StubAgent.new(listener)
    end
    footer = explicit_app.screen.pane.content.conversation.footer
    assert_same explicit_token_log, footer.instance_variable_get(:@token_log)
  end

  it 'routes pikuri-side log lines through the LogWindow (Pikuri.log_io rewired at boot)' do
    app
    Pikuri.logger_for('TestSubsystem').info('pikuri-side message')
    rendered = app.log_window.content.lines.map(&:to_s).join("\n")
    assert_includes rendered, 'pikuri-side message'
  end

  it 'forwards markdown: true (the default) to the TuileListener' do
    app
    assert_equal true, @listener.instance_variable_get(:@markdown)
  end

  it 'forwards markdown: false to the TuileListener when wired off' do
    explicit_app = described_class.new(markdown: false) do |listener|
      @listener = listener
      StubAgent.new(listener)
    end
    explicit_app # force construction
    assert_equal false, @listener.instance_variable_get(:@markdown)
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

  # Spin until the block yields truthy. App's turn lifecycle crosses a
  # real worker thread (start_turn's Thread.new) even under FakeScreen —
  # the fake event queue runs submits inline on whichever thread calls
  # them — so specs that observe post-turn state must wait for the worker.
  def wait_until(timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise 'timed out waiting for condition' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.005
    end
  end
end
