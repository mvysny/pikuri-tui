# frozen_string_literal: true

RSpec.describe PikuriTui::Code::App do
  # Minimal +Pikuri::Agent+ stand-in — same shape as the chat spec's, but
  # the Code::App build block yields THREE args (listener, confirmer,
  # task_listener), so StubAgent ignores the confirmer and task listener
  # (the real agent's tools / ListenerList would take them).
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
    described_class.new do |listener, confirmer, task_listener|
      @listener = listener
      @confirmer = confirmer
      @task_listener = task_listener
      StubAgent.new(listener)
    end
  end

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  it 'mounts a Code::Layout as the screen content with all four panes' do
    layout = app.screen.pane.content
    assert_kind_of PikuriTui::Code::Layout, layout
    assert_kind_of Tuile::Component::Window, layout.conversation
    assert_kind_of Tuile::Component::Window, layout.input
    assert_kind_of Tuile::Component::Window, layout.tasks
    assert_kind_of Tuile::Component::Window, layout.git
  end

  it 'hands the TaskListener to the build block as the third arg' do
    app # force construction
    assert_kind_of PikuriTui::Code::TaskListener, @task_listener
  end

  it 'focuses the input TextArea on boot so the user can start typing immediately' do
    assert_kind_of PikuriTui::Code::Input, app.screen.focused
  end

  it 'eager-constructs the LogWindow (Pikuri.log_io routes through it from boot)' do
    assert_kind_of Tuile::Component::LogWindow, app.log_window
  end

  it 'hands the TuileListener to the build block as the first arg' do
    app # force construction
    assert_kind_of PikuriTui::TuileListener, @listener
  end

  it 'hands a ConfirmerPopup to the build block as the second arg' do
    app # force construction
    assert_kind_of PikuriTui::Code::ConfirmerPopup, @confirmer
  end

  it 'exposes the ConfirmerPopup at #confirmer, bound to this app screen' do
    assert_kind_of PikuriTui::Code::ConfirmerPopup, app.confirmer
    assert_same app.confirmer, @confirmer
    assert_same app.screen, app.confirmer.instance_variable_get(:@screen)
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

  it 'cancels the in-flight turn when Ctrl+C arrives mid-turn' do
    agent = app.agent
    agent.block_turns!
    app.send(:submit_message, 'work')
    wait_until { agent.messages.size == 1 }

    press_ctrl_c
    assert agent.cancellable.cancelled?
  ensure
    agent.finish_turn!
    wait_until { !app.instance_variable_get(:@turn_in_progress) }
  end

  it 'drops focus on Ctrl+C when idle and the input is focused (first press)' do
    app
    assert_kind_of PikuriTui::Code::Input, app.screen.focused
    press_ctrl_c
    assert_nil app.screen.focused
  end

  it 'stops the event loop on Ctrl+C when idle and nothing is focused (second press)' do
    app
    app.screen.focused = nil
    stopped = spy_on_stop
    press_ctrl_c
    assert stopped.call, 'expected the event loop to be stopped'
  end

  it 'leaves Ctrl+C to an open popup (over_popups: false) instead of cancelling/quitting' do
    app
    app.instance_variable_get(:@log_popup).open
    stopped = spy_on_stop

    press_ctrl_c

    assert app.instance_variable_get(:@log_popup).open?, 'popup should stay open'
    refute stopped.call, 'the event loop must not stop while a popup is open'
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

  it 'clears the hint counter when the log popup is dismissed' do
    app
    Tuile.logger.error('boom')
    assert_includes status_bar_text, '^L ⚠ logs (1)'

    log_popup = app.instance_variable_get(:@log_popup)
    log_popup.open
    log_popup.close
    assert_includes status_bar_text, '^L logs'
    refute_includes status_bar_text, '⚠'
  end

  it 'opens the git diff popup on Ctrl+G' do
    popup = app.instance_variable_get(:@git_diff_popup)
    refute popup.open?
    app.screen.send(:handle_key, Tuile::Keys::CTRL_G)
    assert popup.open?, 'Ctrl+G should open the git diff popup'
  end

  it 'advertises the ^G diff hint in the status bar' do
    app
    assert_includes status_bar_text, '^G'
  end

  it 'mounts a FooterLabel as the conversation Window footer' do
    app
    assert_kind_of PikuriTui::Code::FooterLabel, app.screen.pane.content.conversation.footer
  end

  it 'sizes the footer wrap_content so the unused border stays drawn' do
    app
    assert_equal Tuile::Sizing::WRAP_CONTENT, app.screen.pane.content.conversation.footer_sizing
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
    agent.finish_turn!
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
    agent.finish_turn!
    wait_until { !app.instance_variable_get(:@turn_in_progress) }
  end

  it 'drops a mid-turn submission with a warn when the agent has no interloper wired' do
    no_interloper_app = described_class.new do |listener, _confirmer|
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

  it 'routes pikuri-side log lines through the LogWindow (Pikuri.log_io rewired at boot)' do
    app
    Pikuri.logger_for('TestSubsystem').info('pikuri-side message')
    rendered = app.log_window.content.lines.map(&:to_s).join("\n")
    assert_includes rendered, 'pikuri-side message'
  end

  it 'raises without a build block (no agent → no app)' do
    assert_raises(LocalJumpError) { described_class.new }
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

  # Dispatch Ctrl+C through the screen's real key handler (private in the
  # release gem) so the test exercises the full chain: global-shortcut
  # lookup, the +over_popups: false+ gate, then {Code::App#on_interrupt}.
  def press_ctrl_c
    app.screen.send(:handle_key, Tuile::Keys::CTRL_C)
  end

  # Replaces the (no-op) FakeEventQueue#stop with a recorder and returns a
  # callable that reports whether it has fired — the only observable effect
  # of the quit branch, since the fake queue runs no loop to actually stop.
  def spy_on_stop
    stopped = false
    app.screen.event_queue.define_singleton_method(:stop) { stopped = true }
    -> { stopped }
  end

  def wait_until(timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise 'timed out waiting for condition' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.005
    end
  end
end
