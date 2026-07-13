# frozen_string_literal: true

RSpec.describe Code::App do
  # Minimal +Pikuri::Agent+ stand-in — same shape as the chat spec's, but
  # the Code::App build block yields THREE args (listener, confirmer,
  # task_listener), so StubAgent ignores the confirmer and task listener
  # (the real agent's tools / ListenerList would take them).
  class StubAgent
    attr_reader :cancellable, :interloper, :listener, :messages, :transport, :transports, :clear_count

    def initialize(listener, interloper: Pikuri::Agent::Control::Interloper.new, model: 'stub-model',
                   api_base: 'http://x/v1')
      @listener = listener
      @cancellable = Pikuri::Agent::Control::Cancellable.new
      @interloper = interloper
      @transport = Pikuri::Agent::ChatTransport.new(
        model: model, provider: :openai, assume_model_exists: true, api_base: api_base, api_key: 'k'
      )
      @messages = []
      @transports = []
      @clear_count = 0
      @gate = Queue.new
      @blocking = false
    end

    def model = @transport.model

    def block_turns! = @blocking = true

    def finish_turn! = @gate << :done

    def clear_conversation = @clear_count += 1

    def run_loop(user_message:, transport: nil)
      @messages << user_message
      @transports << transport
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
    assert_kind_of Code::Layout, layout
    assert_kind_of Tuile::Component::Window, layout.conversation
    assert_kind_of Tuile::Component::Window, layout.input
    assert_kind_of Tuile::Component::Window, layout.tasks
    assert_kind_of Tuile::Component::Window, layout.git
  end

  it 'hands the TaskListener to the build block as the third arg' do
    app # force construction
    assert_kind_of Code::TaskListener, @task_listener
  end

  it 'focuses the input TextArea on boot so the user can start typing immediately' do
    assert_kind_of Shared::InputArea, app.screen.focused
  end

  it 'eager-constructs the LogWindow (Pikuri.log_io routes through it from boot)' do
    assert_kind_of Tuile::Component::LogWindow, app.log_window
  end

  it 'hands the conversation listener to the build block as the first arg' do
    app # force construction
    assert_kind_of Shared::ConversationTextView::Listener, @listener
  end

  it 'hands a ConfirmerPopup to the build block as the second arg' do
    app # force construction
    assert_kind_of Code::ConfirmerPopup, @confirmer
  end

  it 'exposes the ConfirmerPopup at #confirmer, bound to this app screen' do
    assert_kind_of Code::ConfirmerPopup, app.confirmer
    assert_same app.confirmer, @confirmer
    assert_same app.screen, app.confirmer.instance_variable_get(:@screen)
  end

  it 'starts with no errors logged and a discoverable "^K menu" status-bar hint' do
    app
    assert_includes status_bar_text, '^K menu'
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
    assert_kind_of Shared::InputArea, app.screen.focused
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
    app.instance_variable_get(:@log_ui).log_popup.open
    stopped = spy_on_stop

    press_ctrl_c

    assert app.instance_variable_get(:@log_ui).log_popup.open?, 'popup should stay open'
    refute stopped.call, 'the event loop must not stop while a popup is open'
  end

  it 'shows "^K ⚠ menu (N)" when an error is logged through Tuile.logger' do
    app
    Tuile.logger.error('boom')
    assert_includes status_bar_text, '^K ⚠ menu (1)'
  end

  it 'increments the hint counter once per error (not once per log line)' do
    app
    Tuile.logger.error('one')
    Tuile.logger.info('two')   # info shouldn't bump
    Tuile.logger.warn('three') # warn shouldn't bump either
    Tuile.logger.fatal('four') # fatal does (same bracket as error)
    assert_includes status_bar_text, '^K ⚠ menu (2)'
  end

  it 'clears the hint counter when the log popup is dismissed' do
    app
    Tuile.logger.error('boom')
    assert_includes status_bar_text, '^K ⚠ menu (1)'

    log_popup = app.instance_variable_get(:@log_ui).log_popup
    log_popup.open
    log_popup.close
    assert_includes status_bar_text, '^K menu'
    refute_includes status_bar_text, '⚠'
  end

  it 'wires a Shared::StatusFooterUpdater that drives the conversation Window as border chrome (not a widget slot)' do
    app
    assert_kind_of Shared::StatusFooterUpdater, app.instance_variable_get(:@conversation_window).status_footer_updater
    assert_nil app.screen.pane.content.conversation.footer
  end

  it "hands the agent's interloper to the Shared::StatusFooterUpdater for the queued-count display" do
    app
    assert_same app.agent.interloper, app.instance_variable_get(:@conversation_window).status_footer_updater.interloper
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
    rendered = no_interloper_app.log_window.content.text.to_s
    assert_includes rendered, 'mid-turn message dropped'
  end

  it 'routes pikuri-side log lines through the LogWindow (Pikuri.log_io rewired at boot)' do
    app
    Pikuri.logger_for('TestSubsystem').info('pikuri-side message')
    rendered = app.log_window.content.text.to_s
    assert_includes rendered, 'pikuri-side message'
  end

  it 'raises without a build block (no agent → no app)' do
    assert_raises(LocalJumpError) { described_class.new }
  end

  it 'installs an on_error handler that funnels uncaught exceptions to the pikuri log' do
    app
    log = capture_log { app.screen.on_error.call(RuntimeError.new('oops')) }
    assert_includes log, 'RuntimeError'
    assert_includes log, 'oops'
  end

  describe 'model picker' do
    let(:choices) { [model_choice('Local', 'm1'), model_choice('Cloud', 'm2')] }
    let(:picker_app) do
      described_class.new(models: choices) do |listener, _confirmer, _task_listener, _model_listener|
        StubAgent.new(listener, model: 'm1')
      end
    end

    it 'seeds the footer with the boot model display name' do
      footer = picker_app.instance_variable_get(:@conversation_window).status_footer_updater
      assert_equal 'Local', footer.current_model
    end

    # Integration: a pick made through the app's Shared::Model::Picker reaches the next
    # run_loop and is consumed once. The picker's own option/marker/keying
    # behavior is unit-tested in model_picker_spec.
    it 'applies the picked transport to the next run_loop, then clears it' do
      agent = picker_app.agent
      picker = picker_app.instance_variable_get(:@model_picker)
      _, block = capture_picker { picker.open(current: agent.transport) }
      block.call('2') # pick 'Cloud'

      picker_app.send(:submit_message, 'go')
      wait_until { agent.messages.size == 1 }
      assert_equal choices[1].transport, agent.transports[0]

      picker_app.send(:submit_message, 'again')
      wait_until { agent.messages.size == 2 }
      assert_nil agent.transports[1], 'a switch must apply at most once'
    end
  end

  describe 'plan mode' do
    let(:plan_mode) { Pikuri::Workspace::ReadOnly.new }
    let(:plan_app) do
      described_class.new(plan_mode: plan_mode) do |listener, _confirmer, _task_listener, _model_listener, _plan_listener|
        StubAgent.new(listener)
      end
    end

    it 'defaults to a control that is not in plan mode' do
      refute app.instance_variable_get(:@plan_mode).active?
    end

    it 'toggle_plan_mode flips the shared control on, then off' do
      plan_app.send(:toggle_plan_mode)
      assert plan_mode.active?
      plan_app.send(:toggle_plan_mode)
      refute plan_mode.active?
    end
  end

  describe 'leader menu (Ctrl+K)' do
    it 'advertises the ^K menu status-bar hint' do
      assert_includes app.screen.pane.status_bar.text.to_s, '^K menu'
    end

    it 'offers logs, git diff, plan mode, clear and quit for a single-model shell' do
      keys = app.instance_variable_get(:@leader_menu).actions.map(&:key)
      assert_equal %w[l d p c q], keys
    end

    it 'adds a switch-model action when more than one model is configured' do
      picker_app = described_class.new(models: [model_choice('Local', 'm1'), model_choice('Cloud', 'm2')]) do |listener, _c, _t, _ml, _pl|
        StubAgent.new(listener, model: 'm1')
      end
      keys = picker_app.instance_variable_get(:@leader_menu).actions.map(&:key)
      assert_equal %w[l d p m c q], keys
    end

    it "picking 'c' clears the agent's conversation" do
      agent = app.agent
      app.screen.send(:handle_key, Tuile::Keys::CTRL_K)
      app.screen.send(:handle_key, 'c')
      assert_equal 1, agent.clear_count
    end

    it "picking 'd' opens the git diff popup" do
      app.screen.send(:handle_key, Tuile::Keys::CTRL_K)
      app.screen.send(:handle_key, 'd')
      assert app.instance_variable_get(:@git_diff_popup).open?
    end

    it "picking 'p' toggles plan mode" do
      app.screen.send(:handle_key, Tuile::Keys::CTRL_K)
      app.screen.send(:handle_key, 'p')
      assert app.instance_variable_get(:@plan_mode).active?
    end

    it "picking 'q' stops the event loop" do
      app
      stopped = spy_on_stop
      app.screen.send(:handle_key, Tuile::Keys::CTRL_K)
      app.screen.send(:handle_key, 'q')
      assert stopped.call, 'expected the leader menu quit action to stop the loop'
    end

    it 'closes the menu on Ctrl+C, like ESC' do
      app.screen.send(:handle_key, Tuile::Keys::CTRL_K)
      refute_nil app.screen.pane.modal_popup
      app.screen.send(:handle_key, Tuile::Keys::CTRL_C)
      assert_nil app.screen.pane.modal_popup, 'Ctrl+C should cancel the menu'
    end
  end

  private

  def model_choice(name, model)
    Shared::Model::Choice.new(
      name: name,
      transport: Pikuri::Agent::ChatTransport.new(
        model: model, provider: :openai, assume_model_exists: true,
        api_base: 'http://x/v1', api_key: 'k'
      )
    )
  end

  # Swap +PickerWindow.open+ for a recorder (restored after), run the
  # block that triggers it, and return the captured +[options, callback]+
  # so a spec can assert the option list and drive selection without
  # exercising Tuile's popup/focus machinery.
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
