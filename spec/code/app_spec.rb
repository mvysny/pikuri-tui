# frozen_string_literal: true

RSpec.describe Code::App do
  # App builds its *real* Pikuri::Agent (real default_build_agent listener /
  # tool / extension wiring — workspace, sandbox, MCP, sub-agents, tasks,
  # skills) on a fake_transport, so these specs exercise the actual wiring
  # without a server. The old whole-agent CodeStubAgent is gone; see
  # spec_helper's `require 'pikuri/testing'`. Code's agent is streaming: true,
  # so scripted turns use `llm.stream(...)` (SSE).

  let(:app) { code_app }

  before { fake_screen }
  after  { Tuile::Screen.close }

  it 'mounts a Code::Layout as the screen content with its panes and sidebar' do
    layout = app.screen.pane.content
    assert_kind_of Code::Layout, layout
    assert_kind_of Tuile::Component::Window, layout.conversation
    assert_kind_of Tuile::Component::Window, layout.input
    assert_kind_of Code::WorkspaceSidebar, layout.sidebar
    assert_same layout.sidebar, app.sidebar
  end

  it 'exposes the task-pane listener at #task_listener' do
    assert_kind_of Code::TaskListWindow::Listener, app.task_listener
  end

  it 'focuses the input TextArea on boot so the user can start typing immediately' do
    assert_kind_of Tuile::Component::TextArea, app.screen.focused
  end

  it 'registers the coding slash commands mirroring the leader menu (single connection: no /model)' do
    assert_equal ['/logs', '/trifecta', '/diff', '/plan', '/clear', '/exit', '/quit'],
                 app.send(:build_slash_commands).map(&:name)
  end

  describe '/trifecta' do
    def trifecta_output(target = app)
      target.send(:build_slash_commands).find { |c| c.name == '/trifecta' }.callback.call('')
    end

    it 'echoes the real agent\'s own report — advisory first, then the wired tool map' do
      output = trifecta_output
      assert_includes output, app.agent.trifecta.advisory
      assert_includes output.lines(chomp: true), '  bash [:untrusted_hard, :egress]'
    end

    # The bin's startup question sets exactly this, and nothing else: the
    # workspace's private: declaration, which the file tools' legs inherit.
    it 'counts the private leg iff the workspace was declared private' do
      refute_includes trifecta_output, ':private'
      private_app = code_app(
        filesystem: Pikuri::Workspace::Filesystem::AllowAll.new(project_root: Dir.pwd, private: true)
      )
      assert_includes trifecta_output(private_app), ':private'
    end
  end

  describe 'skill slash commands (one per catalog skill)' do
    let(:app) do
      code_app(skill_catalog: StubCatalog.new([skill('writing-rdoc', 'writing rdoc docs'),
                                               skill('plan', 'a skill that collides with /plan')]))
    end

    it 'appends a /<name> per catalog skill, after the built-in commands, with the skill description as the hint' do
      commands = app.send(:build_slash_commands)
      rdoc = commands.find { |c| c.name == '/writing-rdoc' }
      refute_nil rdoc
      assert_equal 'writing rdoc docs', rdoc.description
      assert_equal '/writing-rdoc', commands.map(&:name).last # after the built-ins
    end

    it 'lets a built-in command win a name collision: the skill is skipped, not a duplicate /plan' do
      names = app.send(:build_slash_commands).map(&:name)
      assert_equal 1, names.count('/plan'), 'the /plan skill must not shadow or duplicate the built-in'
    end

    it 'drives a turn from a skill command: schedules the skill, then submits the rest of the line' do
      loaded = []
      submitted = []
      app.instance_variable_set(:@skill_ext, Class.new do
        define_method(:schedule_load_skill) { |name| loaded << name }
      end.new)
      app.instance_variable_set(:@session, Class.new do
        define_method(:submit) { |msg| submitted << msg }
      end.new)

      rdoc = app.send(:build_slash_commands).find { |c| c.name == '/writing-rdoc' }
      assert_nil rdoc.callback.call('polish the docs') # no echo; the turn is the record
      assert_equal ['writing-rdoc'], loaded
      assert_equal ['polish the docs'], submitted
    end
  end

  it 'eager-constructs the LogWindow (Pikuri.log_io routes through it from boot)' do
    assert_kind_of Tuile::Component::LogWindow, app.log_window
  end

  it 'exposes #project_root (the filesystem root the bin logs)' do
    assert_equal Pathname.new(Dir.pwd).realpath, Pathname.new(app.project_root.to_s).realpath
  end

  it 'exposes the ConfirmerPopup at #confirmer, bound to this app screen' do
    assert_kind_of Code::ConfirmerPopup, app.confirmer
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

  it 'builds a real Pikuri::Agent (not a stub) with the coding tool set wired' do
    assert_kind_of Pikuri::Agent, app.agent
    tool_names = app.agent.tools.map(&:name)
    assert_includes tool_names, 'bash'  # Code::Extension
    assert_includes tool_names, 'read'  # Workspace::Extension
    assert_includes tool_names, 'calculator'
  end

  # The headline capability the fake backend unlocks: a real turn runs through
  # the real agent + real ruby_llm streaming loop + real listener wiring
  # (including the full coding extension stack), and the streamed answer lands
  # in the conversation pane. The whole-agent stub could never assert this.
  it 'renders a real streamed turn in the conversation pane' do
    turn_app = code_app { |llm| llm.stream('Patch ', 'applied.') }
    turn_app.session.submit('do it')
    wait_until { !turn_app.session.turn_in_progress? }
    wait_until { turn_app.conversation_view.text.to_s.include?('Patch applied.') }

    assert_includes turn_app.conversation_view.text.to_s, 'Patch applied.'
  end

  it 'cancels the in-flight turn when Ctrl+C arrives mid-turn' do
    gate = Pikuri::Testing::Gate.new
    turn_app = code_app(gate: gate) { |llm| llm.stream('done') }
    gate.block!
    turn_app.session.submit('work')
    wait_until { turn_app.session.turn_in_progress? }

    press_ctrl_c(turn_app)
    assert turn_app.agent.cancellable.cancelled?
  ensure
    gate.release!
    wait_until { !turn_app.session.turn_in_progress? }
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
    let(:picker_app) { code_app(config: code_config(llms: llms), model: 'm1') }

    it 'seeds the footer with the boot model display name' do
      footer = picker_app.instance_variable_get(:@conversation_window).status_footer_updater
      assert_equal 'Local', footer.current_model
    end

    # Integration: a pick made through the app's Shared::Model::Picker reaches the next
    # run_loop and is consumed once. The picker's own option/marker/keying
    # behavior is unit-tested in model_picker_spec.
    it 'applies the picked transport to the next run_loop, then clears it' do
      agent = picker_app.agent
      seen = []
      agent.define_singleton_method(:run_loop) { |user_message:, transport: nil| seen << transport }
      cloud_transport = picker_app.instance_variable_get(:@models)[1].transport
      picker = picker_app.instance_variable_get(:@model_picker)
      _, block = capture_picker { picker.open(current: agent.transport) }
      block.call('2') # pick 'Cloud'

      picker_app.session.submit('go')
      wait_until { seen.size == 1 }
      assert_equal cloud_transport, seen[0]

      picker_app.session.submit('again')
      wait_until { seen.size == 2 }
      assert_nil seen[1], 'a switch must apply at most once'
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
      assert_includes app.screen.pane.status_bar.text.to_s, '^K menu'
    end

    it 'offers logs, git diff, plan mode, clear and quit for a single-model shell' do
      keys = app.instance_variable_get(:@leader_menu).actions.map(&:key)
      assert_equal %w[l d p c q], keys
    end

    it 'adds a switch-model action when more than one model is configured' do
      picker_app = code_app(config: code_config(llms: [llm('Local', 'm1'), llm('Cloud', 'm2')]), model: 'm1')
      keys = picker_app.instance_variable_get(:@leader_menu).actions.map(&:key)
      assert_equal %w[l d p m c q], keys
    end

    it "picking 'c' clears the agent's conversation" do
      cleared = 0
      app.agent.define_singleton_method(:clear_conversation) { cleared += 1 }
      app.screen.send(:handle_key, Tuile::Keys::CTRL_K)
      app.screen.send(:handle_key, 'c')
      assert_equal 1, cleared
    end

    it "picking 'd' opens the git diff popup" do
      app.screen.send(:handle_key, Tuile::Keys::CTRL_K)
      app.screen.send(:handle_key, 'd')
      assert app.sidebar.diff_open?
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

  # Construct a Code::App with the pre-built workspace objects the bin
  # normally assembles pre-screen. Cheap stand-ins: an AllowAll filesystem
  # rooted at the repo, no sandbox, an empty skill catalog, a placeholder
  # prompt. Overridable via kwargs (the model-picker specs pass a multi-llm
  # config). The block is the no-arg agent seam.
  # Build a Code::App on a fake_transport impersonating a config connection
  # (default model / api_base match the default one-connection config so the
  # footer resolves its name). A +gate+ holds turns open; the block scripts the
  # conversation (default: a single streamed reply, enough for construction-only
  # specs that never run a turn).
  def code_app(config: code_config, model: 'stub-model', api_base: 'http://x/v1', gate: nil,
               skill_catalog: Pikuri::Skill::Catalog::Bundled.new(search_bases: []),
               filesystem: Pikuri::Workspace::Filesystem::AllowAll.new(project_root: Dir.pwd), &script)
    script ||= ->(llm) { llm.stream('ok') }
    transport = Pikuri::Testing.fake_transport(model: model, api_base: api_base, gate: gate, &script)
    described_class.new(
      config: config,
      filesystem: filesystem,
      sandbox: Pikuri::Code::Bash::Sandbox::NONE,
      skill_catalog: skill_catalog,
      system_prompt: 'test system prompt',
      transport: transport
    )
  end

  # An in-memory {Pikuri::Skill::Catalog} for the skill-command specs (the
  # standard's own escape hatch: "hosts that read skills from a hardcoded
  # registry subclass directly").
  class StubCatalog < Pikuri::Skill::Catalog
    def initialize(skills) = @skills = skills
    def list = @skills
    def get(name) = @skills.find { |s| s.name == name }
    def roots = []
  end

  def skill(name, description) = Pikuri::Skill::Catalog::Skill.new(
    name: name, description: description, location: "/skills/#{name}/SKILL.md", body: "# #{name}\n"
  )

  # A Shared::Config carrying the given connections (defaults to one matching
  # code_app's default fake transport, so the footer resolves it). App derives
  # its @models from config.llms via Shared::Model::Choice.from_llm.
  def code_config(llms: [llm('Local', 'stub-model')])
    Shared::Config.new(
      llms: llms,
      search: Shared::Config::Search.new(brave_key: nil, exa_key: nil),
      sandbox: true, confirm: true, mcp: []
    )
  end

  # One [[llm]] connection. +server+ is the base URL (no /v1); from_llm
  # appends /v1, so server 'http://x' yields transport api_base 'http://x/v1'
  # — matching code_app's default fake api_base.
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

  def status_bar_text(some_app = app)
    some_app.screen.pane.status_bar.text.to_s
  end

  # Dispatch Ctrl+C through the screen's real key handler (private in the
  # release gem) so the test exercises the full chain: global-shortcut
  # lookup, the +over_popups: false+ gate, then {Shared::AgentSession#interrupt}.
  def press_ctrl_c(some_app = app)
    some_app.screen.send(:handle_key, Tuile::Keys::CTRL_C)
  end

  # Replaces the (no-op) FakeEventQueue#stop with a recorder and returns a
  # callable that reports whether it has fired — the only observable effect
  # of the quit branch, since the fake queue runs no loop to actually stop.
  def spy_on_stop(some_app = app)
    stopped = false
    some_app.screen.event_queue.define_singleton_method(:stop) { stopped = true }
    -> { stopped }
  end

end
