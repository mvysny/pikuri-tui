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

  def rendered = pane.text.to_s

  describe 'pane scaffolding' do
    it 'is an unframed TextView — the primary pane keeps the terminal background' do
      assert_kind_of Tuile::Component::TextView, pane
      assert_nil pane.bg_color
    end

    it 'tails the transcript and shows its own scrollbar (the frame carried neither)' do
      assert pane.auto_scroll
      assert_equal :visible, pane.scrollbar_visibility
    end

    it 'owns the transcript listener it exposes for the agent ListenerList' do
      assert_kind_of Shared::ConversationTextView::Listener, pane.listener
    end
  end

  describe '#buffer_width' do
    it 'is the wrap width — the pane less the columns the scrollbar claims' do
      pane.rect = Tuile::Rect.new(0, 0, 40, 3)
      # 40 columns less the bar's own and the blank Tuile reserves beside it.
      assert_equal 38, pane.buffer_width
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
      pane.rect = Tuile::Rect.new(0, 0, 40, 10)
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

  it 'renders ToolCall with name and arguments' do
    listener.on_event(Pikuri::Agent::Event::ToolCall.new(name: 'echo', arguments: { 'text' => 'hi' }))
    assert_includes rendered, 'echo'
    assert_includes rendered, 'text='
  end

  it 'renders ToolResult content prefixed with "="' do
    listener.on_event(Pikuri::Agent::Event::ToolResult.new(content: '42'))
    assert_includes rendered, '= 42'
  end

  it 'flattens whitespace in ToolResult content to a single line' do
    listener.on_event(Pikuri::Agent::Event::ToolResult.new(content: "line one\n  line two\n\n\tline three"))
    assert_includes rendered, 'line one line two line three'
    refute_includes rendered, "\n  line two"
  end

  it 'truncates long ToolResult content and reports the original byte count' do
    listener.on_event(Pikuri::Agent::Event::ToolResult.new(content: 'x' * 5_000))
    assert_includes rendered, '…'
    assert_includes rendered, '5000 bytes total'
    refute_includes rendered, 'x' * 5_000
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

  it 'renders FallbackNotice with the reason' do
    listener.on_event(Pikuri::Agent::Event::FallbackNotice.new(reason: 'budget'))
    assert_includes rendered, '! budget'
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
      deltas('hello tehre')  # preview with typo
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
      listener.on_event(Pikuri::Agent::Event::ToolCall.new(name: 'echo', arguments: { 'text' => 'hi' }))
      refute_includes rendered, 'preview text that should disappear'
      assert_includes rendered, 'echo'
    end

    it 'after wipe by unrelated event, the next AssistantDelta opens a fresh buffer' do
      deltas('wiped preview')
      listener.on_event(Pikuri::Agent::Event::ToolCall.new(name: 'echo', arguments: {}))
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
      listener.on_event(Pikuri::Agent::Event::ToolCall.new(name: 'x', arguments: {}))
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
      fg_colors = pane.text.spans.map { |s| s.style.fg }
      refute_includes fg_colors, Tuile::Color.new(:red)
      assert_includes fg_colors, gray
    end

    it 'preserves bold/italic/underline while repainting fg to gray' do
      Shared::Markdown::Renderer.define_singleton_method(:render) do |_text, **_kwargs|
        "\e[1;3;4;31mbold italic underlined red\e[0m"
      end
      listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: 'anything'))
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
      assert_equal [true], @captured_dark
    end

    it 'forwards dark: false once the screen holds the light theme' do
      Tuile::Screen.instance.theme = Shared::AppTheme::LIGHT
      listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'hi'))
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

        def render_result(content:, theme:)
          @result_args = { content: content, theme: theme }
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
      w.listener.on_event(Pikuri::Agent::Event::ToolCall.new(name: 'edit', arguments: { 'path' => 'a.rb' }))
      assert_includes w.text.to_s, 'DIFF BLOCK'
      refute_includes w.text.to_s, '→ edit'
    end

    it 'passes the pane width and theme to the formatter' do
      fmt = formatter.new(call_block: 'X', result_block: nil)
      w = pane_with(fmt)
      w.listener.on_event(Pikuri::Agent::Event::ToolCall.new(name: 'edit', arguments: { 'path' => 'a.rb' }))
      assert_equal({ 'path' => 'a.rb' }, fmt.call_args[:arguments])
      assert fmt.call_args[:width].positive?
      assert_same Tuile::Screen.instance.theme, fmt.call_args[:theme]
    end

    it 'suppresses the result line when the paired formatter returns nil (success)' do
      fmt = formatter.new(call_block: 'DIFF', result_block: nil)
      w = pane_with(fmt)
      w.listener.on_event(Pikuri::Agent::Event::ToolCall.new(name: 'edit', arguments: {}))
      w.listener.on_event(Pikuri::Agent::Event::ToolResult.new(content: 'Edited a.rb: replaced 1 occurrence.'))
      refute_includes w.text.to_s, 'Edited a.rb'
      refute_includes w.text.to_s, '= '
    end

    it 'renders the formatter result block when it returns one (error path)' do
      fmt = formatter.new(call_block: 'DIFF', result_block: '✗ Error: old_string not found')
      w = pane_with(fmt)
      w.listener.on_event(Pikuri::Agent::Event::ToolCall.new(name: 'edit', arguments: {}))
      w.listener.on_event(Pikuri::Agent::Event::ToolResult.new(content: 'Error: old_string not found in a.rb.'))
      assert_includes w.text.to_s, '✗ Error: old_string not found'
    end

    it 'falls back to the default tool-call line when render_call returns nil' do
      fmt = formatter.new(call_block: nil, result_block: nil)
      w = pane_with(fmt)
      w.listener.on_event(Pikuri::Agent::Event::ToolCall.new(name: 'edit', arguments: { 'path' => 'a.rb' }))
      assert_includes w.text.to_s, '→ edit'
    end

    it 'routes the result to the default += line when render_call declined' do
      fmt = formatter.new(call_block: nil, result_block: 'SHOULD NOT SHOW')
      w = pane_with(fmt)
      w.listener.on_event(Pikuri::Agent::Event::ToolCall.new(name: 'edit', arguments: {}))
      w.listener.on_event(Pikuri::Agent::Event::ToolResult.new(content: 'whatever'))
      assert_includes w.text.to_s, '= whatever'
      refute_includes w.text.to_s, 'SHOULD NOT SHOW'
    end

    it 'leaves unregistered tools on the default rendering' do
      fmt = formatter.new(call_block: 'DIFF', result_block: 'R')
      w = pane_with(fmt)
      w.listener.on_event(Pikuri::Agent::Event::ToolCall.new(name: 'grep', arguments: { 'q' => 'x' }))
      w.listener.on_event(Pikuri::Agent::Event::ToolResult.new(content: 'match'))
      assert_includes w.text.to_s, '→ grep'
      assert_includes w.text.to_s, '= match'
      refute_includes w.text.to_s, 'DIFF'
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
      view.rect = Tuile::Rect.new(0, 0, 60, 6)
      view.repaint
      text_area = Tuile::Rect.new(0, 0, view.rect.width - 2, view.rect.height)
      Tuile::Screen.instance.buffer.region_text(text_area).map(&:rstrip)
    end

    it 'paints the indent: prefix, so sub-agent blocks nest visibly' do
      pane.add_block('→ web_search', indent: described_class::Listener::SUB_AGENT_INDENT)
      assert_equal ["#{' ' * described_class::Listener::SUB_AGENT_INDENT}→ web_search"],
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

    it 'renders into the same conversation pane, indented by SUB_AGENT_INDENT' do
      sub.on_event(Pikuri::Agent::Event::ToolCall.new(name: 'web_search', arguments: { 'q' => 'x' }))
      assert_includes rendered, "#{pad}→ web_search"
    end

    it 'indents a streamed assistant answer (first line pads)' do
      sub.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'found it'))
      sub.on_event(Pikuri::Agent::Event::Assistant.new(content: 'found it'))
      assert_includes rendered, "#{pad}found it"
    end

    it 'indents a tool result' do
      sub.on_event(Pikuri::Agent::Event::ToolResult.new(content: '42'))
      assert_includes rendered, "#{pad}= 42"
    end

    it 'leaves the parent listener unindented' do
      listener.on_event(Pikuri::Agent::Event::ToolResult.new(content: '42'))
      assert_includes rendered, '= 42'
      refute_includes rendered, "#{pad}= 42"
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
      assert_equal true, pane.handle_key('n')
      assert_equal [:n_picked], picked
    end

    it 'declines a key it was not offered, leaving the scroll ladder alone' do
      pane.pending_decision = decision('y')
      assert_equal false, pane.handle_key('z')
      assert_empty picked
    end

    it 'answers nothing when no decision is asked — y is just a key' do
      assert_equal false, pane.handle_key('y')
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
      assert_equal false, pane.handle_key('y')
      assert_empty picked
    end

    it 'settles again for an outcome that took two steps' do
      pane.pending_decision = decision('r')
      pane.settle_pending_decision('rejecting — type a reason')
      pane.settle_pending_decision('rejected: wrong directory')
      assert_includes rendered, '· rejected: wrong directory'
      refute_includes rendered, 'type a reason'
    end

    it 'raises when settling a decision that was never asked (our bug, not a no-op)' do
      assert_raises(RuntimeError) { pane.settle_pending_decision('approved') }
    end

    it 'drops the asked decision when the conversation is cleared' do
      pane.pending_decision = decision('y')
      pane.clear
      assert_nil pane.pending_decision
      assert_equal false, pane.handle_key('y')
    end
  end

  describe 'leaving the pane' do
    it 'runs on_escape — the host hands the caret back to the prompt' do
      escaped = 0
      pane.on_escape = -> { escaped += 1 }
      described_class::LEAVE_KEYS.each { |key| assert_equal true, pane.handle_key(key) }
      assert_equal described_class::LEAVE_KEYS.length, escaped
    end

    it 'leaves them unclaimed with no handler wired' do
      described_class::LEAVE_KEYS.each { |key| assert_equal false, pane.handle_key(key) }
    end
  end
end
