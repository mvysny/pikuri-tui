# frozen_string_literal: true

RSpec.describe Code::App do
  # App builds its *real* Pikuri::Agent (real default_build_agent listener /
  # tool / extension wiring — workspace, sandbox, MCP, sub-agents, tasks,
  # skills) on a fake_transport, so these specs exercise the actual wiring
  # without a server. The old whole-agent CodeStubAgent is gone; see
  # spec_helper's `require 'pikuri/testing'`. Code's agent is streaming: true,
  # so scripted turns use `llm.stream(...)` (SSE).

  let(:app) { code_app }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  it 'mounts a Code::Layout as the screen content with its panes and sidebar' do
    layout = app.layout
    assert_kind_of Code::Layout, layout
    assert_kind_of Shared::ConversationTextView, layout.conversation
    assert_kind_of Shared::StatusRuleLabel, layout.status_rule
    assert_kind_of Shared::InputPane, layout.input
    assert_kind_of Code::WorkspaceSidebar, layout.sidebar
    assert_same layout.sidebar, app.sidebar
  end

  it 'exposes the task-pane listener at #task_listener' do
    assert_kind_of Code::TaskListPane::Listener, app.task_listener
  end

  it 'focuses the input TextArea on boot so the user can start typing immediately' do
    assert_kind_of Tuile::Component::TextArea, app.screen.focused
  end

  it 'registers the coding slash commands mirroring the leader menu (single connection: no /model)' do
    assert_equal ['/logs', '/trifecta', '/diff', '/sidebar', '/plan', '/thinking', '/tools', '/clear', '/exit',
                  '/quit'],
                 app.send(:build_slash_commands).map(&:name)
  end

  describe 'the workspace digest standing in for a hidden sidebar' do
    def rule = app.instance_variable_get(:@status_rule)
    def sidebar = app.sidebar

    def emit_changes(added, deleted)
      sidebar.git_watcher.send(:emit, Code::GitWatcher::Snapshot.new(
                                        changes: [Code::GitWatcher::Change.new(
                                          code: ' M', path: 'a.rb', added: added, deleted: deleted
                                        )],
                                        diff_text: '', error: nil
                                      ))
      Tuile::Testing.loop
    end

    it 'carries nothing while the sidebar is showing — the panes have it' do
      emit_changes(4, 1)
      assert_nil rule.workspace_digest
      refute_includes rule.text.to_s, 'file'
    end

    it 'moves the counts into the rule when the sidebar is hidden' do
      emit_changes(42, 7)
      app.send(:select_sidebar, 'off')
      app.screen.flush_layout
      assert_includes rule.text.to_s, '1 file +42/-7'
    end

    it 'picks up data arriving after the sidebar is already hidden' do
      app.send(:select_sidebar, 'off')
      app.screen.flush_layout
      emit_changes(3, 0)
      assert_includes rule.text.to_s, '1 file +3'
    end

    it 'takes the tasks half from the task pane, not just the git poll' do
      app.send(:select_sidebar, 'off')
      app.screen.flush_layout
      sidebar.task_listener.on_event(
        Pikuri::Tasks::ListChanged.new(items: [
                                         Pikuri::Tasks::Item.new(id: 1, content: 'a', status: 'completed'),
                                         Pikuri::Tasks::Item.new(id: 2, content: 'b', status: 'pending')
                                       ])
      )
      Tuile::Testing.loop
      assert_includes rule.text.to_s, '1/2 tasks'
    end

    it 'hands the counts back to the panes when the sidebar returns' do
      emit_changes(9, 2)
      app.send(:select_sidebar, 'off')
      app.screen.flush_layout
      assert_includes rule.text.to_s, '1 file'
      app.send(:select_sidebar, 'full')
      app.screen.flush_layout
      assert_nil rule.workspace_digest
      refute_includes rule.text.to_s, 'file'
    end
  end

  describe '/sidebar' do
    def sidebar_command = app.send(:build_slash_commands).find { |c| c.name == '/sidebar' }
    def run_sidebar(rest) = sidebar_command.callback.call(rest)
    def mode = app.instance_variable_get(:@layout).sidebar_mode

    it 'sets the named mode and echoes it' do
      assert_equal 'Sidebar: narrow.', run_sidebar('narrow')
      assert_equal :narrow, mode
    end

    it 'takes off as an alias for hidden' do
      assert_equal 'Sidebar: hidden.', run_sidebar('off')
      assert_equal :hidden, mode
    end

    it 'cycles on a blank argument, like the leader key' do
      assert_equal 'Sidebar: narrow.', run_sidebar('')
      assert_equal 'Sidebar: hidden.', run_sidebar('')
      assert_equal 'Sidebar: full.', run_sidebar('')
    end

    it 'tolerates surrounding space and case' do
      assert_equal 'Sidebar: hidden.', run_sidebar('  HIDDEN ')
    end

    it 'answers an unknown mode with the ones on offer, changing nothing' do
      outcome = run_sidebar('tiny')
      assert_includes outcome, '"tiny"'
      assert_includes outcome, 'full / narrow / hidden / off'
      assert_equal :full, mode
    end
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

    def skill_commands(some_app = app) = some_app.instance_variable_get(:@skill_activation)

    it 'appends a /<name> per catalog skill, after the built-in commands, with the skill description as the hint' do
      commands = skill_commands.commands
      rdoc = commands.find { |c| c.name == '/writing-rdoc' }
      refute_nil rdoc
      assert_equal 'writing rdoc docs', rdoc.description
      assert_equal '/writing-rdoc', commands.map(&:name).last # after the built-ins
    end

    it 'keeps the built-in commands out of the skill half' do
      refute_includes app.send(:build_slash_commands).map(&:name), '/writing-rdoc'
    end

    it 'lets a built-in command win a name collision: the skill is skipped, not a duplicate /plan' do
      names = skill_commands.commands.map(&:name)
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

      rdoc = skill_commands.commands.find { |c| c.name == '/writing-rdoc' }
      assert_nil rdoc.callback.call('polish the docs') # no echo; the turn is the record
      assert_equal ['writing-rdoc'], loaded
      assert_equal ['polish the docs'], submitted
    end

    describe 'the paths: gate' do
      let(:app) do
        code_app(skill_catalog: StubCatalog.new([skill('writing-rdoc', 'writing rdoc docs', paths: ['**/*.rb']),
                                                 skill('cop', 'component-oriented programming')]))
      end

      it 'withholds a gated skill until a touched file fires it' do
        names = skill_commands.commands.map(&:name)
        assert_includes names, '/cop'
        refute_includes names, '/writing-rdoc'
      end

      it 'lists it the moment a read touches a matching file' do
        touch('lib/code/app.rb')
        assert_includes skill_commands.commands.map(&:name), '/writing-rdoc'
      end

      it 'says in the transcript which file fired it' do
        touch('lib/code/app.rb')
        assert_includes app.conversation.text.to_s,
                        'skills available: writing-rdoc (matched lib/code/app.rb)'
      end

      it 'hides it again when the conversation is cleared' do
        touch('lib/code/app.rb')
        app.send(:clear_conversation)
        refute_includes skill_commands.commands.map(&:name), '/writing-rdoc'
      end

      it 'never lists a skill schedule_load_skill would refuse' do
        refute_includes skill_commands.commands.map(&:name), '/writing-rdoc'
        assert_raises(KeyError) { app.instance_variable_get(:@skill_ext).schedule_load_skill('writing-rdoc') }
      end

      # Drive the promotion the way the agent does: the listener watches
      # ToolCall arguments at before_tool_call, so a bare emit is the whole
      # mechanism (no tool has to actually run).
      def touch(path, some_app = app)
        some_app.agent.instance_variable_get(:@listeners)
                .emit(tool_call('read', path, arguments: { 'path' => path }))
        Tuile::Testing.loop
      end
    end
  end

  # The three namespaces competing for one typed /name, resolved
  # built-in > file command > skill (pikuri's Command::Registry states the
  # order; the loser is warned, not silently duplicated).
  describe 'slash-command precedence' do
    around do |example|
      Dir.mktmpdir('pikuri-tui-commands') do |dir|
        FileUtils.mkdir_p(File.join(dir, '.claude/commands'))
        %w[wh plan writing-rdoc].each do |name|
          File.write(File.join(dir, '.claude/commands', "#{name}.md"), "A #{name} template.")
        end
        @commands_base = dir
        example.run
      end
    end

    let(:app) do
      code_app(
        command_registry: Pikuri::Command::Registry.new(search_bases: [@commands_base]),
        skill_catalog: StubCatalog.new([skill('writing-rdoc', 'writing rdoc docs'),
                                        skill('cop', 'component-oriented programming')])
      )
    end

    def palette = app.instance_variable_get(:@skill_activation).commands.map(&:name)

    it 'lists file commands after the built-ins and before the skills' do
      assert_equal ['/logs', '/trifecta', '/diff', '/sidebar', '/plan', '/thinking', '/tools', '/clear', '/exit',
                    '/quit', '/wh', '/writing-rdoc', '/cop'],
                   palette
    end

    it 'lets the built-in /plan win over a same-named command file' do
      assert_equal 1, palette.count('/plan')
      assert_equal 'toggle plan mode', app.send(:build_slash_commands).find { |c| c.name == '/plan' }.description
    end

    it 'lets the command file win over a same-named skill' do
      assert_equal 1, palette.count('/writing-rdoc')
      refute_equal 'writing rdoc docs',
                   app.instance_variable_get(:@skill_activation).commands
                      .find { |c| c.name == '/writing-rdoc' }.description
    end

    it 'declares the command surface to /trifecta, so its untrusted leg is counted' do
      assert app.agent.trifecta.render.include?('(commands)'),
             'an unvouched command base contributes an untrusted row'
    end
  end

  it 'eager-constructs the LogDialog (Pikuri.log_io routes through it from boot)' do
    assert_kind_of Shared::Log::Dialog, app.log_dialog
  end

  it 'exposes #project_root (the filesystem root the bin logs)' do
    assert_equal Pathname.new(Dir.pwd).realpath, Pathname.new(app.project_root.to_s).realpath
  end

  it 'cycles focus between the prompt and the transcript only (Tab is how a decision is answered)' do
    # Class names, not the components: a failing assert_equal on two mounted
    # components dumps the whole screen tree.
    stops = Array.new(4) { app.screen.focus_next; app.screen.focused.class.name }
    assert_equal ['Shared::ConversationTextView', 'Shared::InputPane::Area'] * 2, stops
  end

  it 'hands the caret back to the prompt when ESC leaves the transcript' do
    app.conversation.focus
    app.screen.key(Tuile::Keys::ESC)
    assert_same app.layout.input.area, app.screen.focused
  end

  it "exposes the TranscriptConfirmer at #confirmer, wired to this app's panes" do
    assert_kind_of Code::TranscriptConfirmer, app.confirmer
    assert_same app.screen, app.confirmer.instance_variable_get(:@screen)
    assert_same app.conversation, app.confirmer.instance_variable_get(:@conversation)
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
    wait_until { turn_app.conversation.text.to_s.include?('Patch applied.') }

    assert_includes turn_app.conversation.text.to_s, 'Patch applied.'
  end

  # The confirmer App wired is the one the write/bash tools were handed, so
  # asking through it exercises the whole shell path: question into *this*
  # app's transcript, answered by a key on *this* app's conversation pane.
  # (A scripted tool call can't drive it — pikuri-testing doesn't model
  # tool-call streaming, and this shell's agent streams.)
  describe 'a confirmation the tools would ask' do
    let(:request) do
      Pikuri::Workspace::Confirmer::Request.new(question: 'OK to run this?', detail: 'mkdir -p tmp/x',
                                                editable: false, change: nil)
    end

    # #ask parks the calling thread, so it runs where a tool runs: off the UI.
    def asking(some_app)
      answer = nil
      worker = Thread.new { answer = some_app.confirmer.ask(request: request) }
      wait_until { some_app.confirmer.pending? }
      yield
      worker.join(2) || raise('the confirmer never answered')
      answer
    end

    it 'asks in the transcript with no popup, and rejects on n' do
      answer = asking(app) do
        assert_empty app.screen.overlays, 'the question belongs in the transcript, not over it'
        assert_predicate app.status_rule, :decision_pending
        assert_includes app.conversation.text.to_s, '⏵ OK to run this?'
        app.conversation.handle_key?('n')
      end

      assert_equal Pikuri::Workspace::Confirmer::Rejected.new(reason: nil), answer
      assert_includes app.conversation.text.to_s, '· rejected'
      refute_predicate app.status_rule, :decision_pending
    end

    it 'declines it on Ctrl+C, so the interrupt is never swallowed' do
      answer = asking(app) { press_ctrl_c }

      assert_equal Pikuri::Workspace::Confirmer::Rejected.new(reason: nil), answer
      refute_predicate app.confirmer, :pending?
    end
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
    let(:picker_app) { code_app(config: code_config(llms: llms), model: 'm1') }

    it 'seeds the footer with the boot model display name' do
      footer = picker_app.status_rule
      assert_equal 'Local', footer.current_model
    end

    # Integration: a pick made through the app's Shared::Model::Picker reaches the next
    # run_loop and is consumed once. The picker's own option/marker/keying
    # behavior is unit-tested in model_picker_spec.
    it 'applies the picked transport to the next run_loop, then clears it' do
      agent = picker_app.agent
      seen = []
      agent.define_singleton_method(:run_loop) { |transport: nil, **| seen << transport }
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
      assert_includes app.status_bar.text.to_s, '^K menu'
    end

    it 'offers logs, git diff, sidebar, plan mode, UI toggles, clear and quit for a single-model shell' do
      keys = app.instance_variable_get(:@leader_menu).actions.map(&:key)
      assert_equal %w[l d s p u c q], keys
    end

    it 'adds a switch-model action when more than one model is configured' do
      picker_app = code_app(config: code_config(llms: [llm('Local', 'm1'), llm('Cloud', 'm2')]), model: 'm1')
      keys = picker_app.instance_variable_get(:@leader_menu).actions.map(&:key)
      assert_equal %w[l d s p u m c q], keys
    end

    it "picking 'c' clears the agent's conversation" do
      cleared = 0
      app.agent.define_singleton_method(:clear_conversation) { cleared += 1 }
      app.screen.key(Tuile::Keys::CTRL_K)
      app.screen.key('c')
      assert_equal 1, cleared
    end

    it "picking 'd' opens the git diff popup" do
      app.screen.key(Tuile::Keys::CTRL_K)
      app.screen.key('d')
      assert app.sidebar.diff_open?
    end

    it "picking 'p' toggles plan mode" do
      app.screen.key(Tuile::Keys::CTRL_K)
      app.screen.key('p')
      assert app.instance_variable_get(:@plan_mode).active?
    end

    it "picking 's' cycles the sidebar width, letting the re-split be the feedback" do
      layout = app.instance_variable_get(:@layout)
      app.screen.key(Tuile::Keys::CTRL_K)
      app.screen.key('s')
      assert_equal :narrow, layout.sidebar_mode
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
               command_registry: Pikuri::Command::Registry.new(search_bases: []),
               filesystem: Pikuri::Workspace::Filesystem::AllowAll.new(project_root: Dir.pwd), &script)
    script ||= ->(llm) { llm.stream('ok') }
    transport = Pikuri::Testing.fake_transport(model: model, api_base: api_base, gate: gate, &script)
    described_class.new(
      config: config,
      filesystem: filesystem,
      sandbox: Pikuri::Code::Bash::Sandbox::NONE,
      skill_catalog: skill_catalog,
      command_registry: command_registry,
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

  def skill(name, description, paths: Pikuri::Skill::PathMatcher::UNCONDITIONAL) =
    Pikuri::Skill::Catalog::Skill.new(
      name: name, description: description, location: "/skills/#{name}/SKILL.md", body: "# #{name}\n",
      paths: paths
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

  def status_bar_text(some_app = app)
    Tuile::Testing.loop
    some_app.status_bar.text.to_s
  end

  # Dispatch Ctrl+C through the screen's real key handler (private in the
  # release gem) so the test exercises the full chain: global-shortcut
  # lookup, the +over_modal: false+ gate, then {Shared::AgentSession#interrupt}.
  def press_ctrl_c(some_app = app)
    some_app.screen.key(Tuile::Keys::CTRL_C)
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
