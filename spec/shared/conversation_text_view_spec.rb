# frozen_string_literal: true

RSpec.describe Shared::ConversationTextView do
  let(:pane)      { described_class.new }
  let(:listener)  { pane.listener }
  let(:gray)      { Shared::Markdown::Grayscale::GRAY }

  before do
    Tuile::Screen.fake
    # Stub the renderer seam with a passthrough: these specs are about the
    # listener's event routing, not Markdown rendering quality
    # (markdown_renderer_spec.rb and ansi_converter_spec.rb own that).
    @original_md_render = Shared::Markdown::Renderer.method(:render)
    Shared::Markdown::Renderer.define_singleton_method(:render) { |text, **| text }
  end

  after do
    original = @original_md_render
    Shared::Markdown::Renderer.define_singleton_method(:render) { |*a, **k| original.call(*a, **k) }
    Tuile::Screen.close
  end

  # The listener submits each event, as it would from the worker thread; play
  # the loop turn that runs them before reading the transcript.
  def text_of(view)
    Tuile::Testing.loop
    view.text.to_s
  end

  def rendered = text_of(pane)

  describe 'pane scaffolding' do
    it 'is an unframed TextView — the primary pane keeps the terminal background' do
      assert_kind_of Tuile::Component::TextView, pane
      assert_nil pane.bg_color
    end

    it 'tails the transcript and shows its own scrollbar once it overflows (the frame carried neither)' do
      assert pane.auto_scroll
      assert_equal :auto, pane.scrollbar_visibility
    end

    it 'owns the transcript listener it exposes for the agent ListenerList' do
      assert_kind_of Shared::ConversationTextView::Listener, pane.listener
    end
  end

  describe '#buffer_width' do
    it 'keeps back the columns the scrollbar claims, even while it is hidden' do
      Tuile::Testing.place(pane, Tuile::Rect.new(0, 0, 40, 3))
      # 40 columns less the bar's own and the blank Tuile reserves beside it.
      assert_equal 38, pane.buffer_width
      assert_equal 40, pane.send(:wrap_width) # a short transcript: no bar yet
    end

    it 'does not rewrap a full-width block when the transcript overflows' do
      Tuile::Testing.place(pane, Tuile::Rect.new(0, 0, 40, 3))
      pane.add_block('x' * pane.buffer_width)
      4.times { |i| pane.add_block("line #{i}") }
      pane.flush_layout
      assert_equal 38, pane.send(:wrap_width) # the bar is up now…
      # …and the long block still takes one row: five rows tailed in a
      # three-row viewport put the top at 2, where a rewrapped one would put it at 3.
      assert_equal 2, pane.scroll_top_row
    end

    it 'floors at 1 before the pane is laid out, so no renderer sees width 0' do
      assert_equal 1, pane.buffer_width
    end

    it 'honors markdown: false' do
      plain = described_class.new(markdown: false)
      assert_equal false, plain.instance_variable_get(:@markdown)
    end

    it 'renders a caught turn error as an error-themed transcript line' do
      pane.render_turn_error(RuntimeError.new('boom'))
      assert_includes rendered, 'RuntimeError'
      assert_includes rendered, 'boom'
    end

    it 'renders a notice as a plain dim transcript line (no error marker)' do
      pane.render_notice('type a message to start the turn')
      assert_includes rendered, 'type a message to start the turn'
      refute_includes rendered, '!'
    end
  end

  describe 'half-page scrolling' do
    let(:half_page) { pane.rect.height / 2 }

    before do
      Tuile::Testing.place(pane, Tuile::Rect.new(0, 0, 40, 10))
      30.times { |i| pane.add_block("line #{i}") }
    end

    it 'pages up half a screen, clamped at the top' do
      pane.scroll_top_row = 10
      pane.scroll_half_page_up
      assert_equal 10 - half_page, pane.scroll_top_row

      3.times { pane.scroll_half_page_up }
      assert_equal 0, pane.scroll_top_row
    end

    it 'pages down half a screen, and re-arms tailing on reaching the bottom' do
      pane.scroll_top_row = 0
      refute pane.following?, 'scrolled off the bottom'

      pane.scroll_half_page_down
      assert_equal half_page, pane.scroll_top_row

      10.times { pane.scroll_half_page_down }
      assert pane.following?, 'paging back to the bottom resumes tailing'
    end
  end

  it 'renders UserTurn as "> <content>" (the CLI listener stayed silent here)' do
    listener.on_event(Pikuri::Agent::Event::UserTurn.new(content: 'hello?'))
    assert_includes rendered, '> hello?'
  end

  it 'renders a dim 📎 line under the UserTurn for each image the model was shown' do
    png = Pikuri::Attachment.new(mime: 'image/png', filename: "sh\e[31mot.png", bytes: 'x' * 2048)
    listener.on_event(Pikuri::Agent::Event::UserTurn.new(content: 'why?', attachments: [png]))
    lines = rendered.lines.map(&:rstrip)
    assert_equal '📎 sh\x1b[31mot.png (image/png, 2.0 kB)', lines[lines.index('> why?') + 1].strip
  end

  it 'renders mid-loop UserTurn injections (Interloper deliveries) the same way' do
    listener.on_event(Pikuri::Agent::Event::UserTurn.new(content: 'also handle this', mid_loop: true))
    assert_includes rendered, '> also handle this'
  end

  it 'renders Thinking content (so the user sees the reasoning stream)' do
    listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'pondered'))
    assert_includes rendered, 'pondered'
  end

  it 'renders Assistant content through the Markdown renderer' do
    listener.on_event(Pikuri::Agent::Event::Assistant.new(content: '**hi**'))
    assert_includes rendered, 'hi'
  end

  describe 'short tool lines' do
    let(:listener_class) { described_class::Listener }

    it "renders a call as the tool's own name over its own argument" do
      listener.on_event(tool_call('web_search', 'rails 8 credentials',
                                  arguments: { 'query' => 'rails 8 credentials', 'limit' => 5 }))
      assert_includes rendered, 'WebSearch(rails 8 credentials)'
      refute_includes rendered, 'limit'
    end

    it 'drops the parentheses for a call the tool describes with no argument' do
      listener.on_event(tool_call('enter_plan_mode'))
      assert_includes rendered, 'EnterPlanMode'
      refute_includes rendered, '('
    end

    it 'flattens and elides a long argument to one capped line' do
      listener.on_event(tool_call('bash', "set -e\n#{'x' * 4_000}"))
      line = rendered.lines.first.chomp
      assert_equal 'Bash('.length + listener_class::TOOL_ARGUMENT_MAX_CHARS + 1, line.length
      assert_includes line, 'set -e x'
      assert_includes line, '…'
    end

    # The k=v.inspect dump this replaced escaped control bytes for free; the
    # short form prints the tool's strings raw, so the sanitizer is
    # load-bearing here — and a display string can still carry a path or a
    # command the model chose.
    it 'escapes an ESC in a display string instead of letting it recolor the pane' do
      listener.on_event(tool_call('read', "a\e[31m.rb"))
      assert_includes rendered, 'Read(a\x1b[31m.rb)'
      refute_includes pane.text.spans.map { |s| s.style.fg }, Tuile::Color.new(:red)
    end

    it "renders a result as the tool's own summary" do
      listener.on_event(tool_result('Returned 23 search results'))
      assert_includes rendered, 'Returned 23 search results'
    end

    it 'indents the result line under the call it answers' do
      listener.on_event(tool_call('bash', 'ls'))
      listener.on_event(tool_result('Returned 4 lines'))
      pad = ' ' * listener_class::TOOL_RESULT_INDENT
      assert_equal ['Bash(ls)', "#{pad}Returned 4 lines"], rendered.lines.map(&:chomp).reject(&:empty?)
    end

    # pikuri composes the "Error: " prefix in Tool::Result.error, so the tone
    # reads the tool's own status rather than sniffing the observation.
    it 'tones a summary that reports a failure as an error' do
      listener.on_event(tool_result("Error: exit 1: rm: cannot remove 'build'"))
      assert_includes rendered, "Error: exit 1: rm: cannot remove 'build'"
      assert_includes pane.text.spans.map { |s| s.style.fg }, Tuile::Screen.instance.theme[:error]
    end

    it 'caps a runaway summary' do
      listener.on_event(tool_result("Error: #{'y' * 500}"))
      line = rendered.lines.first.chomp.lstrip
      assert_equal listener_class::TOOL_SUMMARY_MAX_CHARS, line.length
      assert line.end_with?('…'), 'expected the cut to be marked'
    end
  end

  describe 'the thinking toggle' do
    def deltas(*chunks)
      chunks.each { |c| listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: c)) }
    end

    it 'starts shown' do
      assert pane.show_thinking
    end

    it 'honors show_thinking: false at construction' do
      hidden = described_class.new(show_thinking: false)
      hidden.listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'quiet reasoning'))
      assert_equal '', hidden.text.to_s
    end

    it 'collapses a non-streamed bookend already in the transcript, and brings it back' do
      listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'pondered'))
      assert_includes rendered, 'pondered'

      refute pane.toggle_thinking
      assert_equal '', rendered

      assert pane.toggle_thinking
      assert_includes rendered, 'pondered'
    end

    # The buffer's own #source is the thunk's input, so reasoning that streamed
    # is revealable whether it went on to be finalized, preserved, or is still
    # open.
    it 'collapses reasoning that streamed, and restores it from the buffer' do
      deltas('streamed ')
      listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'streamed (authoritative)'))
      assert_includes rendered, 'streamed (authoritative)'

      pane.toggle_thinking
      assert_equal '', rendered

      pane.toggle_thinking
      assert_includes rendered, 'streamed (authoritative)'
    end

    it 'collapses a preserved stream — the common path, where the bookend is suppressed' do
      deltas('reasoning')
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'answer'))
      assert_includes rendered, 'reasoning'

      pane.toggle_thinking
      refute_includes rendered, 'reasoning'
      assert_includes rendered, 'answer'
    end

    it 'collects the delta stream unrendered while hidden, and reveals the bookend text' do
      pane.show_thinking = false
      deltas('never shown ')
      listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'the whole reasoning'))
      assert_equal '', rendered

      pane.toggle_thinking
      assert_includes rendered, 'the whole reasoning'
      refute_includes rendered, 'never shown', 'the bookend replaced the collected preview'
    end

    # pikuri emits the Thinking bookend from +after_message+, i.e. after the
    # answer has streamed, so a block first created on that bookend files itself
    # below the answer it preceded.
    it 'reveals hidden reasoning above the answer, not where its bookend landed' do
      pane.show_thinking = false
      deltas('pondering')
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'Hi'))
      listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'pondering'))
      listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'Hi there!'))
      assert_equal 'Hi there!', rendered.strip

      pane.toggle_thinking
      assert_equal ['pondering', 'Hi there!'], rendered.lines.map(&:strip).reject(&:empty?)
    end

    it 'puts a bookend that finalized an open stream back under the gate' do
      deltas('preview')
      pane.show_thinking = false
      listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'authoritative reasoning'))
      assert_equal '', rendered, 'finalize writes straight to its region; it must be re-hidden'

      pane.toggle_thinking
      assert_includes rendered, 'authoritative reasoning'
    end

    it 'leaves assistant prose and tool lines alone' do
      listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'pondered'))
      listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'the answer'))
      listener.on_event(tool_call('bash', 'ls'))
      pane.toggle_thinking
      refute_includes rendered, 'pondered'
      assert_includes rendered, 'the answer'
      assert_includes rendered, 'Bash(ls)'
    end

    # The trap the clear-and-replay alternative walks into: the question would
    # be erased while the tool thread stays blocked on its answer.
    it 'keeps a parked decision askable across a toggle' do
      picked = []
      choice = Shared::PendingDecision::Choice.new(key: 'y', label: 'approve', outcome: :approve)
      pane.pending_decision = Shared::PendingDecision.new(body: '⏵ OK to run this?', choices: [choice],
                                                          on_choice: ->(outcome) { picked << outcome })
      pane.toggle_thinking
      assert_includes rendered, '⏵ OK to run this?'
      assert_equal true, pane.handle_key?('y')
      assert_equal [:approve], picked
    end

    it 'applies a /thinking argument, toggles on a blank one, and names the config key' do
      assert_includes pane.select_thinking('off'), 'ui.show_thinking = false'
      refute pane.show_thinking
      assert_equal 'Thinking shown.', pane.select_thinking('on')
      assert_includes pane.select_thinking(''), 'ui.show_thinking = false'
      assert_includes pane.select_thinking('maybe'), 'No thinking setting "maybe"'
      refute pane.show_thinking, 'a bad argument changes nothing'
    end
  end

  describe 'the tool-line form toggle' do
    def call_and_result
      listener.on_event(tool_call('web_search', 'rails 8', arguments: { 'query' => 'rails 8' }))
      listener.on_event(tool_result('Returned 1 match', content: 'match'))
    end

    it 'starts on the short form' do
      assert_equal :short, pane.tool_detail
    end

    # The whole point of a redraw register: a filter applied as events arrive
    # would only ever reach the *next* call, and "show me the raw form of the
    # one I just read" is the case that matters.
    it 'redraws the tool blocks already in the transcript, both ways' do
      call_and_result
      assert_includes rendered, 'WebSearch(rails 8)'

      assert_equal :verbose, pane.toggle_tool_detail
      assert_includes rendered, '→ web_search(query="rails 8")'
      assert_includes rendered, '= match'
      refute_includes rendered, 'WebSearch(rails 8)'

      assert_equal :short, pane.toggle_tool_detail
      assert_includes rendered, 'WebSearch(rails 8)'
      refute_includes rendered, '→ web_search'
    end

    it 'caps a long observation in the verbose form, reporting the byte count' do
      pane.tool_detail = :verbose
      listener.on_event(tool_result('Returned 5000 bytes', content: 'x' * 5_000))
      assert_includes rendered, '…'
      assert_includes rendered, '5000 bytes total'
      refute_includes rendered, 'x' * 300
    end

    it 'raises on a form it does not have (our bug, not a silent no-op)' do
      assert_raises(ArgumentError) { pane.tool_detail = :loud }
    end

    it 'applies a /tools argument, toggles on a blank one, and reports either' do
      assert_equal 'Tool lines: verbose.', pane.select_tool_detail('verbose')
      assert_equal :verbose, pane.tool_detail
      assert_equal 'Tool lines: short.', pane.select_tool_detail('  ')
      assert_includes pane.select_tool_detail('loud'), 'No tool-line form "loud"'
      assert_equal :short, pane.tool_detail
    end

    it 'drops the redraw register with the conversation, so a later toggle is inert' do
      call_and_result
      listener.on_event(Pikuri::Agent::Event::Reset.new)
      pane.toggle_tool_detail
      assert_equal '', rendered
    end
  end

  it 'renders SystemInjected as a dim ⊕ block' do
    listener.on_event(Pikuri::Agent::Event::SystemInjected.new(content: 'remember: be brief'))
    assert_includes rendered, '⊕ remember: be brief'
  end

  it 'collapses a loaded skill body to its name instead of pasting the whole SKILL.md' do
    body = Pikuri::Skill::Renderer.format_skill(
      Pikuri::Skill::Catalog::Skill.new(name: 'writing-rdoc', description: 'd',
                                        location: '/skills/writing-rdoc/SKILL.md',
                                        body: "# Writing rdoc\n\nlots and lots of guidance\n")
    )
    listener.on_event(Pikuri::Agent::Event::SystemInjected.new(content: body))
    assert_includes rendered, '⊕ loaded skill: writing-rdoc'
    refute_includes rendered, 'lots and lots of guidance'
  end

  # The promoting host renders its own line, carrying the matched path this
  # block has no room for — so pasting it too would be a noisier duplicate.
  it 'drops a path-activation promotion block entirely' do
    promotion = Pikuri::Skill::Renderer.format_promotion(
      [Pikuri::Skill::Catalog::Skill.new(name: 'writing-rdoc', description: 'd',
                                         location: '/skills/writing-rdoc/SKILL.md', body: '')]
    )
    listener.on_event(Pikuri::Agent::Event::SystemInjected.new(content: promotion))
    refute_includes rendered, 'writing-rdoc'
    refute_includes rendered, '⊕'
  end

  it 'renders Cancelled as a "! cancelled" notice' do
    listener.on_event(Pikuri::Agent::Event::Cancelled.new)
    assert_includes rendered, '! cancelled'
  end

  it 'wipes the conversation pane on Reset (clear_conversation)' do
    listener.on_event(Pikuri::Agent::Event::UserTurn.new(content: 'hello?'))
    listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'hi there'))
    refute_equal '', rendered

    listener.on_event(Pikuri::Agent::Event::Reset.new)
    assert_equal '', rendered
  end

  it 'drops the open streaming buffer on Reset so the next turn starts clean' do
    # A Reset arriving mid-stream (e.g. clear while a preview region is open)
    # must not leave the buffer extending a now-detached region.
    listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'partial'))
    listener.on_event(Pikuri::Agent::Event::Reset.new)
    assert_equal '', rendered

    # The next turn renders into a fresh region rather than raising on the
    # detached one.
    listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'fresh answer'))
    assert_includes rendered, 'fresh answer'
  end

  it 'is silent for Tokens (TokenLog handles them)' do
    tokens = Pikuri::Agent::Event::Tokens.new(input: 10, output: 5, cached: nil,
                                              cache_creation: nil, thinking: nil, model_id: nil)
    listener.on_event(tokens)
    assert_equal '', rendered
  end

  it 'is silent for ContextCap (its consumer is TokenLog)' do
    listener.on_event(Pikuri::Agent::Event::ContextCap.new(cap: 32_768))
    assert_equal '', rendered
  end

  it 'logs and falls back to raw text when the Markdown renderer raises' do
    Shared::Markdown::Renderer.define_singleton_method(:render) { |*| raise StandardError, 'boom' }
    log = capture_log do
      listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'plain content'))
      Tuile::Testing.loop
    end
    assert_includes rendered, 'plain content'
    assert_includes log, 'Shared::Markdown::Renderer.render failed'
  end

  it 'reports its listener label as "Shared::ConversationTextView::Listener" (used by Agent#to_s)' do
    assert_equal 'Shared::ConversationTextView::Listener', listener.to_s
  end

  context 'streaming AssistantDelta' do
    def deltas(*chunks)
      chunks.each { |c| listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: c)) }
    end

    it 'incrementally renders deltas into the conversation pane' do
      deltas('Hello, ', 'world')
      assert_includes rendered, 'Hello, world'
    end

    it 'finalizes the streamed region with the authoritative Assistant content' do
      deltas('hello tehre') # preview with typo
      listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'hello there'))
      assert_includes rendered, 'hello there'
      refute_includes rendered, 'tehre'
    end

    it 'after finalize, a new AssistantDelta opens a fresh buffer' do
      deltas('first reply')
      listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'first reply'))
      deltas('second reply')
      listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'second reply'))
      assert_includes rendered, 'first reply'
      assert_includes rendered, 'second reply'
    end

    it 'falls back to direct render when Assistant arrives without prior deltas' do
      listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'no-stream reply'))
      assert_includes rendered, 'no-stream reply'
    end

    it 'Cancelled mid-stream preserves the streamed region' do
      deltas('partial reply ', 'so far')
      listener.on_event(Pikuri::Agent::Event::Cancelled.new)
      assert_includes rendered, 'partial reply so far'
      assert_includes rendered, '! cancelled'
    end

    it 'an unrelated mid-stream event wipes the preview before rendering itself' do
      deltas('preview text that should disappear')
      listener.on_event(tool_call('echo', 'hi'))
      refute_includes rendered, 'preview text that should disappear'
      assert_includes rendered, 'Echo(hi)'
    end

    it 'after wipe by unrelated event, the next AssistantDelta opens a fresh buffer' do
      deltas('wiped preview')
      listener.on_event(tool_call('echo'))
      deltas('next round reply')
      listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'next round reply'))
      assert_includes rendered, 'next round reply'
      refute_includes rendered, 'wiped preview'
    end
  end

  context 'streaming ThinkingDelta' do
    it 'streams reasoning through the same Markdown buffer as the assistant pane' do
      listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: '**still bold in markdown**'))
      assert_includes rendered, '**still bold in markdown**'
    end

    it 'consecutive deltas extend the same thinking block' do
      listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: 'first '))
      listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: 'second'))
      lines = rendered.split("\n").reject(&:empty?)
      thinking_lines = lines.grep(/first|second/)
      assert_equal 1, thinking_lines.size
      assert_includes thinking_lines.first, 'first second'
    end

    it 'a non-thinking event between deltas preserves the streamed prefix and starts a new block' do
      listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: 'before'))
      listener.on_event(tool_call('x'))
      listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: 'after'))
      lines = rendered.split("\n").reject(&:empty?)
      # 'before' must survive the tool-call cross — preserving a committed
      # thinking block is the whole reason a thinking release is non-wiping.
      assert_includes lines, 'before'
      after_line = lines.find { |l| l.include?('after') }
      refute_nil after_line
      refute_equal 'before', after_line
    end

    it 'reconciles the streamed thinking with the Thinking bookend when they diverge' do
      # Real-world case: the provider truncates the delta stream and the bookend
      # carries content that the deltas never delivered. The streamed preview
      # must be replaced by the authoritative content so the user sees the full
      # reasoning, not just the prefix the deltas got through.
      listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: 'streamed'))
      listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'streamed (authoritative)'))
      assert_includes rendered, 'streamed (authoritative)'
    end

    it 'suppresses the Thinking bookend when AssistantDelta arrived between deltas and bookend' do
      listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: 'reasoning'))
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'answer'))
      listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'reasoning (authoritative)'))
      listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'answer'))
      # AssistantDelta releases (preserves) the thinking buffer — the streamed
      # reasoning stays in its region but the handle is dropped so the next
      # ThinkingDelta opens fresh. The bookend that follows then has nowhere to
      # land — the thinking block is closed and @thinking_streamed is still
      # true, so neither finalize nor a fresh add_block fires. Intentional: the
      # streamed preview already shipped, and rendering the bookend again would
      # duplicate the reasoning.
      assert_equal 1, rendered.scan('reasoning').size
      refute_includes rendered, 'reasoning (authoritative)'
    end

    it 'renders the Thinking bookend when no deltas were emitted (non-streaming provider)' do
      listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'bookend only'))
      assert_includes rendered, 'bookend only'
    end

    it 'resets streamed-thinking state across rounds so the next bookend renders again' do
      # Round 1: streamed thinking, bookend suppressed.
      listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: 'round1 thinking'))
      listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'round1 authoritative'))
      # Round 2: only the bookend (no deltas) — should render.
      listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'round2 only'))
      assert_includes rendered, 'round2 only'
    end

    it 'recolors streamed thinking to a single gray tone, stripping any color the renderer produced' do
      Shared::Markdown::Renderer.define_singleton_method(:render) { |_text, **_kwargs| "\e[31mred-from-renderer\e[0m" }
      listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: 'anything'))
      Tuile::Testing.loop
      fg_colors = pane.text.spans.map { |s| s.style.fg }
      refute_includes fg_colors, Tuile::Color.new(:red)
      assert_includes fg_colors, gray
    end

    it 'preserves bold/italic/underline while repainting fg to gray' do
      Shared::Markdown::Renderer.define_singleton_method(:render) do |_text, **_kwargs|
        "\e[1;3;4;31mbold italic underlined red\e[0m"
      end
      listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: 'anything'))
      Tuile::Testing.loop
      span = pane.text.spans.find { |s| s.text.include?('bold italic underlined red') }
      refute_nil span, 'expected a span carrying the rendered text'
      assert_equal gray, span.style.fg
      assert span.style.bold,      'bold should pass through the recolor'
      assert span.style.italic,    'italic should pass through the recolor'
      assert span.style.underline, 'underline should pass through the recolor'
    end

    it 'renders the non-streaming Thinking bookend in the same gray tone' do
      Shared::Markdown::Renderer.define_singleton_method(:render) { |_text, **_kwargs| "\e[31mred\e[0m" }
      listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'bookend'))
      Tuile::Testing.loop
      fg_colors = pane.text.spans.map { |s| s.style.fg }
      assert_includes fg_colors, gray
      refute_includes fg_colors, Tuile::Color.new(:red)
    end
  end

  context 'markdown: false' do
    let(:pane) { described_class.new(markdown: false) }

    # If the passthrough stub fired we'd see no behavior difference vs
    # markdown: true. Replace it with a sentinel that would *always* be visible
    # if invoked, so the spec proves the flag short-circuits the render.
    before do
      Shared::Markdown::Renderer.define_singleton_method(:render) { |*| 'MARKDOWN_RAN' }
    end

    it 'echoes non-streaming Assistant content verbatim, skipping the Markdown renderer' do
      listener.on_event(Pikuri::Agent::Event::Assistant.new(content: '**not bold here**'))
      assert_includes rendered, '**not bold here**'
      refute_includes rendered, 'MARKDOWN_RAN'
    end

    it 'echoes the non-streaming Thinking bookend verbatim (still gray-tinted)' do
      listener.on_event(Pikuri::Agent::Event::Thinking.new(content: '**raw thinking**'))
      assert_includes rendered, '**raw thinking**'
      refute_includes rendered, 'MARKDOWN_RAN'
      Tuile::Testing.loop
      fg_colors = pane.text.spans.map { |s| s.style.fg }
      assert_includes fg_colors, gray
    end

    it 'streams AssistantDelta content through Shared::Markdown::PassthroughBuffer (no Markdown render)' do
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: '**still literal**'))
      assert_includes rendered, '**still literal**'
      refute_includes rendered, 'MARKDOWN_RAN'
    end

    it 'streams ThinkingDelta content through Shared::Markdown::PassthroughBuffer, gray-tinted' do
      listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: '**still literal**'))
      assert_includes rendered, '**still literal**'
      refute_includes rendered, 'MARKDOWN_RAN'
      Tuile::Testing.loop
      fg_colors = pane.text.spans.map { |s| s.style.fg }
      assert_includes fg_colors, gray
    end
  end

  context 'code-highlighting scheme' do
    # Capture the dark: flag the listener forwards to the renderer, so we can
    # prove it tracks the screen's current theme (the converter spec owns what
    # dark:/light actually does to the output).
    before do
      captured = @captured_dark = []
      Shared::Markdown::Renderer.define_singleton_method(:render) do |text, **kw|
        captured << kw[:dark]
        text
      end
    end

    it 'forwards dark: true on a dark screen (Screen.fake pins :dark)' do
      listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'hi'))
      Tuile::Testing.loop
      assert_equal [true], @captured_dark
    end

    it 'forwards dark: false once the screen holds the light theme' do
      Tuile::Screen.instance.theme = Shared::AppTheme::LIGHT
      listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'hi'))
      Tuile::Testing.loop
      assert_equal [false], @captured_dark
    end
  end

  describe 'per-tool formatters' do
    # A stand-in formatter recording its calls; the real EditFormatter /
    # WriteFormatter are exercised by their own specs.
    let(:formatter) do
      Class.new do
        attr_reader :call_args, :result_args

        def initialize(call_block:, result_block:)
          @call_block = call_block
          @result_block = result_block
        end

        def render_call(arguments:, width:, theme:)
          @call_args = { arguments: arguments, width: width, theme: theme }
          @call_block
        end

        def render_result(summary:, theme:)
          @result_args = { summary: summary, theme: theme }
          @result_block
        end
      end
    end

    # The formatter is set at construction, so each test builds its own pane
    # (and asserts on its pane) rather than the shared markdown-true one.
    def pane_with(fmt)
      described_class.new(tool_formatters: { 'edit' => fmt })
    end

    it 'renders a formatter call block instead of the default tool-call line' do
      fmt = formatter.new(call_block: 'DIFF BLOCK', result_block: nil)
      w = pane_with(fmt)
      w.listener.on_event(tool_call('edit', 'a.rb', arguments: { 'path' => 'a.rb' }))
      assert_includes text_of(w), 'DIFF BLOCK'
      refute_includes text_of(w), 'Edit('
    end

    it 'passes the pane width and theme to the formatter' do
      fmt = formatter.new(call_block: 'X', result_block: nil)
      w = pane_with(fmt)
      w.listener.on_event(tool_call('edit', 'a.rb', arguments: { 'path' => 'a.rb' }))
      Tuile::Testing.loop
      assert_equal({ 'path' => 'a.rb' }, fmt.call_args[:arguments])
      assert fmt.call_args[:width].positive?
      assert_same Tuile::Screen.instance.theme, fmt.call_args[:theme]
    end

    it 'suppresses the result line when the paired formatter returns nil (success)' do
      fmt = formatter.new(call_block: 'DIFF', result_block: nil)
      w = pane_with(fmt)
      w.listener.on_event(tool_call('edit'))
      w.listener.on_event(tool_result('Replaced 1 occurrence in a.rb'))
      refute_includes text_of(w), 'Edited a.rb'
      refute_includes text_of(w), 'OK'
    end

    it 'renders the formatter result block when it returns one (error path)' do
      fmt = formatter.new(call_block: 'DIFF', result_block: '✗ Error: old_string not found')
      w = pane_with(fmt)
      w.listener.on_event(tool_call('edit'))
      w.listener.on_event(tool_result('Error: old_string not found in a.rb.'))
      assert_includes text_of(w), '✗ Error: old_string not found'
    end

    it 'falls back to the default tool-call line when render_call returns nil' do
      fmt = formatter.new(call_block: nil, result_block: nil)
      w = pane_with(fmt)
      w.listener.on_event(tool_call('edit', 'a.rb', arguments: { 'path' => 'a.rb' }))
      assert_includes text_of(w), 'Edit(a.rb)'
    end

    it 'routes the result to the default summary line when render_call declined' do
      fmt = formatter.new(call_block: nil, result_block: 'SHOULD NOT SHOW')
      w = pane_with(fmt)
      w.listener.on_event(tool_call('edit'))
      w.listener.on_event(tool_result('Returned 8 bytes', content: 'whatever'))
      assert_includes text_of(w), 'Returned 8 bytes'
      refute_includes text_of(w), 'SHOULD NOT SHOW'
    end

    # D_density_thunks: a diff is the one tool output the user reviews rather
    # than skims, so the formatter blocks are not kinded and the tool-line
    # toggle cannot reach them.
    it 'leaves a formatter block alone when the tool-line form flips' do
      fmt = formatter.new(call_block: 'DIFF BLOCK', result_block: nil)
      w = pane_with(fmt)
      w.listener.on_event(tool_call('edit', 'a.rb', arguments: { 'path' => 'a.rb' }))
      w.toggle_tool_detail
      assert_includes text_of(w), 'DIFF BLOCK'
      refute_includes text_of(w), '→ edit'
    end

    it 'leaves unregistered tools on the default rendering' do
      fmt = formatter.new(call_block: 'DIFF', result_block: 'R')
      w = pane_with(fmt)
      w.listener.on_event(tool_call('grep', 'x'))
      w.listener.on_event(tool_result('Returned 1 match', content: 'match'))
      assert_includes text_of(w), 'Grep(x)'
      assert_includes text_of(w), 'Returned 1 match'
      refute_includes text_of(w), 'DIFF'
    end
  end

  # Every other spec here reads pane.text — the pre-wrap model, which
  # holds the indent whether or not the pane can display it. tuile#2 (0.10.0's
  # wrapper ate a leading whitespace run on the *first* row, not just on
  # continuations) was invisible to all of them: the /trifecta tree and the
  # sub-agent indent painted flush left with the model still reading nested.
  # These assert on painted rows, so a wrapper that swallows an indent fails
  # here rather than in a screenshot.
  describe 'painted indentation' do
    # Wide enough that nothing wraps: the bug is about the indent, not the wrap.
    # Read back short of the two columns the scrollbar claims (its glyph plus
    # the blank Tuile reserves) so neither lands in the compared text.
    def painted(view)
      Tuile::Testing.place(view, Tuile::Rect.new(0, 0, 60, 6))
      painted_region(view, trim_right: 2).map(&:rstrip)
    end

    it 'paints the indent: prefix, so sub-agent blocks nest visibly' do
      pane.add_block('WebSearch(rails 8)', indent: described_class::Listener::SUB_AGENT_INDENT)
      assert_equal ["#{' ' * described_class::Listener::SUB_AGENT_INDENT}WebSearch(rails 8)"],
                   painted(pane).reject(&:empty?)
    end

    it 'paints indentation carried inside a block, so a /trifecta tree stays a tree' do
      pane.add_block("pikuri-tui-code [:egress]\n  read [:untrusted_hard]\n  file_miner []\n    read []")
      assert_equal ['pikuri-tui-code [:egress]', '  read [:untrusted_hard]',
                    '  file_miner []', '    read []'],
                   painted(pane).reject(&:empty?)
    end
  end

  describe '#for_sub_agent' do
    let(:sub) { listener.for_sub_agent(id: 'researcher 0') }
    let(:pad) { ' ' * described_class::Listener::SUB_AGENT_INDENT }
    let(:result_pad) { ' ' * described_class::Listener::TOOL_RESULT_INDENT }

    it 'renders into the same conversation pane, indented by SUB_AGENT_INDENT' do
      sub.on_event(tool_call('web_search', 'x'))
      assert_includes rendered, "#{pad}WebSearch(x)"
    end

    it 'indents a streamed assistant answer (first line pads)' do
      sub.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'found it'))
      sub.on_event(Pikuri::Agent::Event::Assistant.new(content: 'found it'))
      assert_includes rendered, "#{pad}found it"
    end

    it 'indents a tool result on top of the indent it already carries' do
      sub.on_event(tool_result('Returned 2 bytes'))
      assert_includes rendered, "#{pad}#{result_pad}Returned 2 bytes"
    end

    it 'leaves the parent listener unindented' do
      listener.on_event(tool_result('Returned 2 bytes'))
      assert_includes rendered, "#{result_pad}Returned 2 bytes"
      refute_includes rendered, "#{pad}#{result_pad}Returned 2 bytes"
    end
  end

  describe 'asking a decision' do
    let(:picked) { [] }

    def decision(*keys)
      choices = keys.map do |key|
        Shared::PendingDecision::Choice.new(key: key, label: "do #{key}", outcome: :"#{key}_picked")
      end
      Shared::PendingDecision.new(body: '⏵ OK to run this?', choices: choices,
                                  on_choice: ->(outcome) { picked << outcome })
    end

    it 'appends the body with the key cue under it' do
      pane.pending_decision = decision('y', 'n')
      assert_includes rendered, '⏵ OK to run this?'
      assert_includes rendered, '(y) do y   (n) do n'
    end

    it 'reports the picked outcome and consumes the key' do
      pane.pending_decision = decision('y', 'n')
      assert_equal true, pane.handle_key?('n')
      assert_equal [:n_picked], picked
    end

    it 'declines a key it was not offered, leaving the scroll ladder alone' do
      pane.pending_decision = decision('y')
      assert_equal false, pane.handle_key?('z')
      assert_empty picked
    end

    it 'answers nothing when no decision is asked — y is just a key' do
      assert_equal false, pane.handle_key?('y')
      assert_empty picked
    end

    it 'keeps the question and swaps the cue for the outcome once settled' do
      pane.pending_decision = decision('y', 'n')
      pane.settle_pending_decision('approved')
      assert_includes rendered, '⏵ OK to run this?'
      assert_includes rendered, '· approved'
      refute_includes rendered, '(y) do y'
    end

    it 'stops answering once settled' do
      pane.pending_decision = decision('y')
      pane.settle_pending_decision('approved')
      assert_nil pane.pending_decision
      assert_equal false, pane.handle_key?('y')
      assert_empty picked
    end

    it 'settles again for an outcome that took two steps' do
      pane.pending_decision = decision('r')
      pane.settle_pending_decision('redirecting — tell the agent')
      pane.settle_pending_decision('redirected: wrong directory')
      assert_includes rendered, '· redirected: wrong directory'
      refute_includes rendered, 'tell the agent'
    end

    it 'raises when settling a decision that was never asked (our bug, not a no-op)' do
      assert_raises(RuntimeError) { pane.settle_pending_decision('approved') }
    end

    it 'drops the asked decision when the conversation is cleared' do
      pane.pending_decision = decision('y')
      pane.clear
      assert_nil pane.pending_decision
      assert_equal false, pane.handle_key?('y')
    end
  end

  describe 'leaving the pane' do
    it 'runs on_escape — the host hands the caret back to the prompt' do
      escaped = []
      pane.on_escape { |e| escaped << e.source }
      described_class::LEAVE_KEYS.each { |key| assert_equal true, pane.handle_key?(key) }
      assert_equal [pane] * described_class::LEAVE_KEYS.length, escaped
    end

    it 'leaves them unclaimed with an empty slot' do
      described_class::LEAVE_KEYS.each { |key| assert_equal false, pane.handle_key?(key) }
    end
  end
end
