# frozen_string_literal: true

RSpec.describe Computer::App do
  # App builds its *real* Pikuri::Agent (real default_build_agent listener /
  # tool / extension wiring — Os, Thunderbird, sub-agent research) on a
  # fake_transport, so these specs exercise the actual wiring without a
  # server. Computer's agent is streaming: true, so scripted turns use
  # `llm.stream(...)` (SSE).
  #
  # The extensions probe the host at build, so each is steered off it: an
  # empty Thunderbird profile dir (no Gloda ⇒ no inbound mail tools, and never
  # the dev machine's real mail), config.sandbox false (no bwrap probe), and a
  # stubbed Os::SystemInfo (no `inxi` spawn on every agent build).

  let(:config) { computer_config }
  # Empty by default: the production default scans $HOME, and a spec asserting
  # the palette must not depend on what the host has in ~/.claude/commands.
  let(:command_registry) { Pikuri::Command::Registry.new(search_bases: []) }
  let(:app) { build_app }

  before do
    Tuile::Screen.fake
    @profile_dir = Dir.mktmpdir('pikuri-tui-computer-profile')
    machine = Struct.new(:prompt_section).new("# This machine\n\n- OS: spec host")
    Pikuri::Os::SystemInfo.define_singleton_method(:new) { |*| machine }
  end

  after do
    Tuile::Screen.close
    Pikuri::Os::SystemInfo.singleton_class.remove_method(:new)
    FileUtils.rm_rf(@profile_dir)
  end

  # Build a Computer::App on a fake_transport impersonating a config connection
  # (default model / api_base match the default one-connection config so the
  # footer resolves its name). A +gate+ holds turns open; the block scripts the
  # conversation (default: a single streamed reply, enough for
  # construction-only specs that never run a turn).
  def build_app(config: self.config, model: 'stub-model', api_base: 'http://x/v1', gate: nil, &script)
    script ||= ->(llm) { llm.stream('ok') }
    transport = Pikuri::Testing.fake_transport(model: model, api_base: api_base, gate: gate, &script)
    described_class.new(config: config, profile_dir: @profile_dir, command_registry: command_registry,
                        transport: transport)
  end

  # Replace +agent.run_loop+ with a recorder of +[user_message, transport]+
  # pairs, so a spec observes what a turn was handed without scripting it.
  def spy_on_run_loop(agent)
    seen = []
    agent.define_singleton_method(:run_loop) { |user_message:, transport: nil| seen << [user_message, transport] }
    seen
  end

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
      seen = spy_on_run_loop(app.agent)
      app.instance_variable_get(:@slash_menu).submit('/wh swingai')
      wait_until { seen.map(&:first) == ['Weekly log for swingai.'] }
    end
  end

  it 'builds a real Pikuri::Agent (not a stub) with the OS and Thunderbird tools wired' do
    assert_kind_of Pikuri::Agent, app.agent
    tool_names = app.agent.tools.map(&:name)
    assert_includes tool_names, 'calculator'
    assert_includes tool_names, 'bash'
    assert_includes tool_names, 'thunderbird_mail_compose'
    refute_includes tool_names, 'web_search', 'web tools belong to the quarantined researcher only'
  end

  it 'renders a real streamed turn in the conversation pane' do
    turn_app = build_app { |llm| llm.stream('Hello ', 'from ', 'the ', 'fake') }
    turn_app.session.submit('hi')
    wait_until { !turn_app.session.turn_in_progress? }
    wait_until { turn_app.conversation.text.to_s.include?('Hello from the fake') }

    assert_includes turn_app.conversation.text.to_s, 'Hello from the fake'
  end

  it 'eager-constructs the LogDialog (Pikuri.log_io routes through it from boot)' do
    assert_kind_of Shared::Log::Dialog, app.log_dialog
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
    gate = Pikuri::Testing::Gate.new
    turn_app = build_app(gate: gate) { |llm| llm.stream('done') }
    gate.block!
    turn_app.session.submit('work')
    wait_until { turn_app.session.turn_in_progress? }

    turn_app.screen.key(Tuile::Keys::CTRL_C)
    assert turn_app.agent.cancellable.cancelled?
  ensure
    gate.release!
    wait_until { !turn_app.session.turn_in_progress? }
  end

  it 'leaves Ctrl+C to an open popup (over_modal: false) instead of cancelling/quitting' do
    app
    app.instance_variable_get(:@log_ui).log_dialog.open
    stopped = spy_on_stop

    press_ctrl_c

    assert app.instance_variable_get(:@log_ui).log_dialog.open?, 'popup should stay open'
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

    log_dialog = app.instance_variable_get(:@log_ui).log_dialog
    log_dialog.open
    log_dialog.close
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

  it 'routes pikuri-side log lines through the LogDialog (Pikuri.log_io rewired at boot)' do
    app
    Pikuri.logger_for('TestSubsystem').info('pikuri-side message')
    Tuile::Testing.loop # LogDialog#log submits
    rendered = app.log_dialog.content.text.to_s
    assert_includes rendered, 'pikuri-side message'
  end

  it 'installs an on_error handler that funnels uncaught exceptions to the pikuri log' do
    app
    error = Tuile::EventQueue::ErrorEvent.new(error: RuntimeError.new('oops'))
    log = capture_log { app.screen.on_error.fire(error) }
    assert_includes log, 'RuntimeError'
    assert_includes log, 'oops'
  end

  describe 'model picker' do
    let(:llms) { [llm('Local', 'm1'), llm('Cloud', 'm2')] }
    let(:picker_app) { build_app(config: computer_config(llms: llms), model: 'm1') }

    it 'seeds the footer with the boot model display name' do
      footer = picker_app.status_rule
      assert_equal 'Local', footer.current_model
    end

    # Integration: a pick made through the app's Shared::Model::Picker reaches
    # the next run_loop and is consumed once. run_loop is spied (not a network
    # call) so the picked *real* transport is observed without dialing it; the
    # picker's own option/marker/keying behavior is unit-tested in
    # model_picker_spec.
    it 'applies the picked transport to the next run_loop, then clears it' do
      agent = picker_app.agent
      seen = spy_on_run_loop(agent)
      cloud_transport = picker_app.instance_variable_get(:@models)[1].transport
      picker = picker_app.instance_variable_get(:@model_picker)
      _, block = capture_picker { picker.open(current: agent.transport) }
      block.call('2') # pick 'Cloud'

      picker_app.session.submit('go')
      wait_until { seen.size == 1 }
      assert_equal cloud_transport, seen[0][1]

      picker_app.session.submit('again')
      wait_until { seen.size == 2 }
      assert_nil seen[1][1], 'a switch must apply at most once'
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
      picker_app = build_app(config: computer_config(llms: [llm('Local', 'm1'), llm('Cloud', 'm2')]), model: 'm1')
      keys = picker_app.instance_variable_get(:@leader_menu).actions.map(&:key)
      assert_equal %w[l p u m c q], keys
    end

    it "picking 'c' clears the agent's conversation" do
      cleared = 0
      app.agent.define_singleton_method(:clear_conversation) { cleared += 1 }
      app.screen.key(Tuile::Keys::CTRL_K)
      app.screen.key('c')
      assert_equal 1, cleared
    end

    it "picking 'p' toggles plan mode" do
      app.screen.key(Tuile::Keys::CTRL_K)
      app.screen.key('p')
      assert app.instance_variable_get(:@plan_mode).active?
    end

    it "picking 'q' stops the event loop" do
      app
      stopped = spy_on_stop
      app.screen.key(Tuile::Keys::CTRL_K)
      app.screen.key('q')
      assert stopped.call, 'expected the leader menu quit action to stop the loop'
    end

    it 'closes the menu on Ctrl+C, like ESC' do
      app.screen.key(Tuile::Keys::CTRL_K)
      refute_nil app.screen.pane.modal_overlay
      app.screen.key(Tuile::Keys::CTRL_C)
      assert_nil app.screen.pane.modal_overlay, 'Ctrl+C should cancel the menu'
    end
  end

  private

  # A Shared::Config carrying the given connections (defaults to one matching
  # build_app's default fake transport, so the footer resolves it). App
  # derives its @models from config.llms via Shared::Model::Choice.from_llm.
  # sandbox: false keeps the FullFsNoNet bwrap probe out of the spec.
  def computer_config(llms: [llm('Local', 'stub-model')])
    Shared::Config.new(
      llms: llms,
      search: Shared::Config::Search.new(brave_key: nil, exa_key: nil),
      sandbox: false, confirm: true, mcp: []
    )
  end

  # One [[llm]] connection. +server+ is the base URL (no /v1); from_llm
  # appends /v1, so server 'http://x' yields transport api_base 'http://x/v1'
  # — matching build_app's default fake api_base.
  def llm(name, model, server: 'http://x')
    Shared::Config::Llm.new(name: name, server: server, model: model, api_key: nil, context_window: nil)
  end

  # Swap +PickerDialog.new+ for a recorder whose popup never opens (restored
  # after), run the block that triggers it, and return the captured
  # +[options, callback]+ so a spec can assert the option list and drive
  # selection without exercising Tuile's popup/focus machinery.
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

  def status_bar_text
    Tuile::Testing.loop
    app.status_bar.text.to_s
  end

  # Dispatch Ctrl+C through the screen's real key handler (private in the
  # release gem) so the test exercises the full chain: global-shortcut
  # lookup, the +over_modal: false+ gate, then {Shared::AgentSession#interrupt}.
  def press_ctrl_c
    app.screen.key(Tuile::Keys::CTRL_C)
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
