# frozen_string_literal: true

RSpec.describe Computer::App do
  # Minimal +Pikuri::Agent+ stand-in — same shape as the chat / code specs'.
  # App only reaches for +run_loop+ (from the worker thread), +cancellable+
  # (from {Shared::AgentSession#interrupt}), +interloper+ (mid-turn queueing +
  # the Shared::StatusRuleLabel handoff), +transport+ / +clear_conversation+.
  # Anything else stays untouched, so we don't pay the network / sandbox-probe
  # cost in a unit spec. Named +ComputerStubAgent+, not +StubAgent+: three
  # spec files declaring +class StubAgent+ define one shared top-level constant,
  # reopened across files — a landmine the moment their signatures diverge.
  class ComputerStubAgent
    attr_reader :cancellable, :interloper, :messages, :transport, :transports, :clear_count

    def initialize(interloper: Pikuri::Agent::Control::Interloper.new, model: 'stub-model',
                   api_base: 'http://x/v1')
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

  let(:config) { computer_config }
  # Empty by default: the production default scans $HOME, and a spec asserting
  # the palette must not depend on what the host has in ~/.claude/commands.
  let(:command_registry) { Pikuri::Command::Registry.new(search_bases: []) }
  let(:app) do
    described_class.new(config: config, command_registry: command_registry) { ComputerStubAgent.new }
  end

  before { fake_screen }
  after  { Tuile::Screen.close }

  it 'mounts a Computer::Layout as the screen content with conversation + input panes (no sidebar)' do
    layout = app.layout
    assert_kind_of Computer::Layout, layout
    assert_kind_of Shared::ConversationTextView, layout.conversation
    assert_kind_of Shared::StatusRuleLabel, layout.status_rule
    assert_kind_of Shared::InputPane, layout.input
    refute_respond_to layout, :tasks
    refute_respond_to layout, :git
  end

  it 'focuses the input TextArea on boot so the user can start typing immediately' do
    assert_kind_of Tuile::Component::TextArea, app.screen.focused
  end

  it 'registers the computer slash commands mirroring the leader menu (single connection: no /model, no /diff)' do
    assert_equal ['/logs', '/trifecta', '/plan', '/thinking', '/tools', '/clear', '/exit', '/quit'],
                 app.send(:build_slash_commands).map(&:name)
  end

  describe 'on-disk slash commands' do
    around do |example|
      Dir.mktmpdir('pikuri-tui-computer-commands') do |dir|
        FileUtils.mkdir_p(File.join(dir, '.claude/commands'))
        File.write(File.join(dir, '.claude/commands/wh.md'), 'Weekly log for $ARGUMENTS.')
        File.write(File.join(dir, '.claude/commands/plan.md'), 'Not the read-only toggle.')
        @base = dir
        example.run
      end
    end

    let(:command_registry) { Pikuri::Command::Registry.new(search_bases: [@base]) }

    def palette = app.instance_variable_get(:@slash_menu).instance_variable_get(:@commands).map(&:name)

    it 'appends them after the built-ins, and lets a built-in win a collision' do
      assert_equal ['/logs', '/trifecta', '/plan', '/thinking', '/tools', '/clear', '/exit', '/quit', '/wh'], palette
    end

    it 'runs one as an expanded user turn' do
      app.instance_variable_get(:@slash_menu).submit('/wh swingai')
      wait_until { app.agent.messages == ['Weekly log for swingai.'] }
    end
  end

  it 'eager-constructs the LogWindow (Pikuri.log_io routes through it from boot)' do
    assert_kind_of Tuile::Component::LogWindow, app.log_window
  end

  it 'exposes #project_root (the filesystem root the bin logs), defaulting to the launch dir' do
    assert_equal Pathname.new(Dir.pwd).realpath, Pathname.new(app.project_root.to_s).realpath
  end

  it "exposes the TranscriptConfirmer at #confirmer, wired to this app's panes" do
    assert_kind_of Code::TranscriptConfirmer, app.confirmer
    assert_same app.screen, app.confirmer.instance_variable_get(:@screen)
    assert_same app.conversation, app.confirmer.instance_variable_get(:@conversation)
  end

  it 'exposes a Code::PlanModeListener at #plan_mode_listener' do
    assert_kind_of Code::PlanModeListener, app.plan_mode_listener
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
    app.session.submit('work')
    wait_until { agent.messages.size == 1 }

    press_ctrl_c
    assert agent.cancellable.cancelled?
  ensure
    agent.finish_turn!
    wait_until { !app.session.turn_in_progress? }
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

  it 'wires a Shared::StatusRuleLabel as the layout row between the panes' do
    app
    assert_kind_of Shared::StatusRuleLabel, app.status_rule
    assert_same app.status_rule, app.layout.status_rule
  end

  it "hands the agent's interloper to the Shared::StatusRuleLabel for the queued-count display" do
    app
    assert_same app.agent.interloper, app.status_rule.interloper
  end

  it 'routes pikuri-side log lines through the LogWindow (Pikuri.log_io rewired at boot)' do
    app
    Pikuri.logger_for('TestSubsystem').info('pikuri-side message')
    rendered = app.log_window.content.text.to_s
    assert_includes rendered, 'pikuri-side message'
  end

  it 'installs an on_error handler that funnels uncaught exceptions to the pikuri log' do
    app
    log = capture_log { app.screen.on_error.call(RuntimeError.new('oops')) }
    assert_includes log, 'RuntimeError'
    assert_includes log, 'oops'
  end

  describe 'model picker' do
    let(:llms) { [llm('Local', 'm1'), llm('Cloud', 'm2')] }
    let(:picker_app) do
      described_class.new(config: computer_config(llms: llms)) { ComputerStubAgent.new(model: 'm1') }
    end

    it 'seeds the footer with the boot model display name' do
      footer = picker_app.status_rule
      assert_equal 'Local', footer.current_model
    end

    # Integration: a pick made through the app's Shared::Model::Picker reaches the next
    # run_loop and is consumed once. The picker's own option/marker/keying
    # behavior is unit-tested in model_picker_spec.
    it 'applies the picked transport to the next run_loop, then clears it' do
      agent = picker_app.agent
      cloud_transport = picker_app.instance_variable_get(:@models)[1].transport
      picker = picker_app.instance_variable_get(:@model_picker)
      _, block = capture_picker { picker.open(current: agent.transport) }
      block.call('2') # pick 'Cloud'

      picker_app.session.submit('go')
      wait_until { agent.messages.size == 1 }
      assert_equal cloud_transport, agent.transports[0]

      picker_app.session.submit('again')
      wait_until { agent.messages.size == 2 }
      assert_nil agent.transports[1], 'a switch must apply at most once'
    end
  end

  describe 'plan mode' do
    it 'defaults to a control that is not in plan mode' do
      refute app.instance_variable_get(:@plan_mode).active?
    end

    it 'toggle_plan_mode flips the shared control on, then off' do
      plan_mode = app.instance_variable_get(:@plan_mode)
      app.send(:toggle_plan_mode)
      assert plan_mode.active?
      app.send(:toggle_plan_mode)
      refute plan_mode.active?
    end
  end

  describe 'leader menu (Ctrl+K)' do
    it 'advertises the ^K menu status-bar hint' do
      assert_includes app.status_bar.text.to_s, '^K menu'
    end

    it 'offers logs, plan mode, UI toggles, clear and quit for a single-model shell (no git diff)' do
      keys = app.instance_variable_get(:@leader_menu).actions.map(&:key)
      assert_equal %w[l p u c q], keys
    end

    it 'adds a switch-model action when more than one model is configured' do
      picker_app = described_class.new(config: computer_config(llms: [llm('Local', 'm1'), llm('Cloud', 'm2')])) do
        ComputerStubAgent.new(model: 'm1')
      end
      keys = picker_app.instance_variable_get(:@leader_menu).actions.map(&:key)
      assert_equal %w[l p u m c q], keys
    end

    it "picking 'c' clears the agent's conversation" do
      agent = app.agent
      app.screen.send(:handle_key?, Tuile::Keys::CTRL_K)
      app.screen.send(:handle_key?, 'c')
      assert_equal 1, agent.clear_count
    end

    it "picking 'p' toggles plan mode" do
      app.screen.send(:handle_key?, Tuile::Keys::CTRL_K)
      app.screen.send(:handle_key?, 'p')
      assert app.instance_variable_get(:@plan_mode).active?
    end

    it "picking 'q' stops the event loop" do
      app
      stopped = spy_on_stop
      app.screen.send(:handle_key?, Tuile::Keys::CTRL_K)
      app.screen.send(:handle_key?, 'q')
      assert stopped.call, 'expected the leader menu quit action to stop the loop'
    end

    it 'closes the menu on Ctrl+C, like ESC' do
      app.screen.send(:handle_key?, Tuile::Keys::CTRL_K)
      refute_nil app.screen.pane.modal_popup
      app.screen.send(:handle_key?, Tuile::Keys::CTRL_C)
      assert_nil app.screen.pane.modal_popup, 'Ctrl+C should cancel the menu'
    end
  end

  private

  # A Shared::Config carrying the given connections (defaults to one matching
  # ComputerStubAgent's default transport, so the footer resolves it). App
  # derives its @models from config.llms via Shared::Model::Choice.from_llm.
  def computer_config(llms: [llm('Local', 'stub-model')])
    Shared::Config.new(
      llms: llms,
      search: Shared::Config::Search.new(brave_key: nil, exa_key: nil),
      sandbox: true, confirm: true, mcp: []
    )
  end

  # One [[llm]] connection. +server+ is the base URL (no /v1); from_llm
  # appends /v1, so server 'http://x' yields transport api_base 'http://x/v1'
  # — matching ComputerStubAgent's default api_base.
  def llm(name, model, server: 'http://x')
    Shared::Config::Llm.new(name: name, server: server, model: model, api_key: nil, context_window: nil)
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
    app.status_bar.text.to_s
  end

  # Dispatch Ctrl+C through the screen's real key handler (private in the
  # release gem) so the test exercises the full chain: global-shortcut
  # lookup, the +over_popups: false+ gate, then {Shared::AgentSession#interrupt}.
  def press_ctrl_c
    app.screen.send(:handle_key?, Tuile::Keys::CTRL_C)
  end

  # Replaces the (no-op) FakeEventQueue#stop with a recorder and returns a
  # callable that reports whether it has fired — the only observable effect
  # of the quit branch, since the fake queue runs no loop to actually stop.
  def spy_on_stop
    stopped = false
    app.screen.event_queue.define_singleton_method(:stop) { stopped = true }
    -> { stopped }
  end

end
