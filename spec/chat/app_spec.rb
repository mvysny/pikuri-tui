# frozen_string_literal: true

RSpec.describe Chat::App do
  # App builds its *real* Pikuri::Agent (real default_build_agent listener /
  # tool wiring) on a fake_transport — a scripted-HTTP backend — so these
  # specs exercise the actual wiring end-to-end without a server. The old
  # per-shell ChatStubAgent (which faked the whole agent and bypassed that
  # wiring) is gone; see spec_helper's `require 'pikuri/testing'`.
  #
  # Chat's agent is streaming: true, so scripted turns use `llm.stream(...)`
  # (SSE), never `llm.reply` (JSON) — a streaming request served JSON would
  # mismatch the adapter's stream path.

  let(:config) { chat_config }
  let(:app) { build_app }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  # Build a Chat::App on a fake_transport that impersonates a config
  # connection (so the footer resolves its display name). Default model /
  # api_base match the default one-connection config. A +gate+ holds turns
  # open; the block scripts the conversation (default: a single streamed
  # reply, enough for construction-only specs that never run a turn).
  def build_app(config: self.config, model: 'stub-model', api_base: 'http://x/v1',
                gate: nil, markdown: true, &script)
    script ||= ->(llm) { llm.stream('ok') }
    transport = Pikuri::Testing.fake_transport(model: model, api_base: api_base, gate: gate, &script)
    described_class.new(config: config, markdown: markdown, transport: transport)
  end

  it 'mounts a Chat::Layout as the screen content with conversation + input panes' do
    layout = app.layout
    assert_kind_of Chat::Layout, layout
    assert_kind_of Shared::ConversationTextView, layout.conversation
    assert_kind_of Shared::StatusRuleLabel, layout.status_rule
    assert_kind_of Shared::InputPane, layout.input
  end

  it 'focuses the input TextArea on boot so the user can start typing immediately' do
    assert_kind_of Tuile::Component::TextArea, app.screen.focused
  end

  it 'registers the chat slash commands mirroring the leader menu (single connection: no /model)' do
    assert_equal ['/logs', '/trifecta', '/thinking', '/tools', '/clear', '/exit', '/quit'],
                 app.send(:build_slash_commands).map(&:name)
  end

  it 'adds /model to the slash commands only when more than one model is configured' do
    picker_app = build_app(config: chat_config(llms: [llm('Local', 'm1'), llm('Cloud', 'm2')]), model: 'm1')
    assert_equal ['/logs', '/trifecta', '/thinking', '/tools', '/model', '/clear', '/exit', '/quit'],
                 picker_app.send(:build_slash_commands).map(&:name)
  end

  it 'eager-constructs the LogDialog (Pikuri.log_io routes through it from boot)' do
    assert_kind_of Shared::Log::Dialog, app.log_dialog
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

  it 'builds a real Pikuri::Agent (not a stub) with the chat tool set wired' do
    assert_kind_of Pikuri::Agent, app.agent
    tool_names = app.agent.tools.map(&:name)
    assert_includes tool_names, 'calculator'
    assert_includes tool_names, 'web_search'
  end

  # The headline capability the fake backend unlocks: a real turn runs through
  # the real agent + real ruby_llm streaming loop + real listener wiring, and
  # the streamed answer lands in the conversation pane. Nothing asserted this
  # before — the whole-agent stub never emitted an event.
  it 'renders a real streamed turn in the conversation pane' do
    turn_app = build_app { |llm| llm.stream('Hello ', 'from ', 'the ', 'fake') }
    turn_app.session.submit('hi')
    wait_until { !turn_app.session.turn_in_progress? }
    wait_until { turn_app.conversation.text.to_s.include?('Hello from the fake') }

    assert_includes turn_app.conversation.text.to_s, 'Hello from the fake'
  end

  describe 'leader menu (Ctrl+K)' do
    it 'advertises the ^K menu status-bar hint' do
      app
      assert_includes status_bar_text, '^K menu'
    end

    it 'offers logs, UI toggles, clear and quit for a single-model shell' do
      keys = app.instance_variable_get(:@leader_menu).actions.map(&:key)
      assert_equal %w[l u c q], keys
    end

    it 'includes a switch-model action only when more than one model is configured' do
      picker_app = build_app(config: chat_config(llms: [llm('Local', 'm1'), llm('Cloud', 'm2')]), model: 'm1')
      keys = picker_app.instance_variable_get(:@leader_menu).actions.map(&:key)
      assert_equal %w[l u m c q], keys
    end

    it "picking 'c' clears the agent's conversation" do
      cleared = 0
      app.agent.define_singleton_method(:clear_conversation) { cleared += 1 }
      app.screen.key(Tuile::Keys::CTRL_K)
      app.screen.key('c')
      assert_equal 1, cleared
    end

    it 'opens a modal menu popup on Ctrl+K' do
      app.screen.key(Tuile::Keys::CTRL_K)
      assert_kind_of Shared::LeaderMenu, app.instance_variable_get(:@leader_menu)
      assert_kind_of Tuile::Component::PickerDialog, app.screen.pane.modal_overlay
    end

    it "picking 'l' opens the log popup" do
      app.screen.key(Tuile::Keys::CTRL_K)
      app.screen.key('l')
      assert app.instance_variable_get(:@log_ui).log_dialog.open?
    end

    it "picking 'q' stops the event loop" do
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

  it 'cancels the in-flight turn when Ctrl+C arrives mid-turn' do
    gate = Pikuri::Testing::Gate.new
    turn_app = build_app(gate: gate) { |llm| llm.stream('done') }
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

  it 'clears the hint counter when the log popup is dismissed (user has now read the diagnostics)' do
    app
    Tuile.logger.error('boom')
    assert_includes status_bar_text, '^K ⚠ menu (1)'

    # Open the popup directly — same dispatch path as the menu's 'l' entry.
    log_dialog = app.instance_variable_get(:@log_ui).log_dialog
    log_dialog.open
    log_dialog.close
    assert_includes status_bar_text, '^K menu'
    refute_includes status_bar_text, '⚠'
  end

  it 'wires a Shared::StatusRuleLabel as the layout row between the panes' do
    app
    assert_kind_of Shared::StatusRuleLabel, app.status_rule
    # It is the layout's own row between the two panes, not chrome hung off
    # another component.
    assert_same app.status_rule, app.layout.status_rule
  end

  it "hands the agent's interloper to the Shared::StatusRuleLabel for the queued-count display" do
    app
    assert_same app.agent.interloper, app.status_rule.interloper
  end

  it 'feeds the Shared::StatusRuleLabel from the App-owned TokenLog' do
    footer = app.status_rule
    assert_same app.token_log, footer.instance_variable_get(:@token_log)
  end

  it 'routes pikuri-side log lines through the LogDialog (Pikuri.log_io rewired at boot)' do
    app
    Pikuri.logger_for('TestSubsystem').info('pikuri-side message')
    Tuile::Testing.loop # LogDialog#log submits
    rendered = app.log_dialog.content.text.to_s
    assert_includes rendered, 'pikuri-side message'
  end

  it 'forwards markdown: true (the default) to the Shared::ConversationTextView' do
    app
    window = app.conversation
    assert_equal true, window.instance_variable_get(:@markdown)
  end

  it 'forwards markdown: false to the Shared::ConversationTextView when wired off' do
    explicit_app = build_app(markdown: false)
    window = explicit_app.conversation
    assert_equal false, window.instance_variable_get(:@markdown)
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
    let(:picker_app) { build_app(config: chat_config(llms: llms), model: 'm1') }

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

    # Regression (integration): two connections running the same model id on
    # different servers must not collide in the footer's id → name map — the
    # footer must name the connection the agent actually booted on.
    it 'seeds the footer with the active connection, not a same-model sibling' do
      pair = [llm('Local Qwen', 'qwen3', server: 'http://localhost:8080'),
              llm('Remote Qwen', 'qwen3', server: 'http://mavi-fw:8080')]
      app = build_app(config: chat_config(llms: pair), model: 'qwen3', api_base: 'http://mavi-fw:8080/v1')
      assert_equal 'Remote Qwen', app.status_rule.current_model
    end
  end

  private

  # A Shared::Config carrying the given connections (defaults to one matching
  # build_app's default fake transport, so the footer resolves it). App
  # derives its @models from config.llms via Shared::Model::Choice.from_llm.
  def chat_config(llms: [llm('Local', 'stub-model')])
    Shared::Config.new(
      llms: llms,
      search: Shared::Config::Search.new(brave_key: nil, exa_key: nil),
      sandbox: true, confirm: true, mcp: []
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
