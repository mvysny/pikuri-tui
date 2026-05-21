# frozen_string_literal: true

RSpec.describe PikuriTui::TuileListener do
  let(:text_view) { Tuile::Component::TextView.new }
  let(:listener)  { described_class.new(text_view: text_view, screen: Tuile::Screen.instance) }
  let(:gray)      { PikuriTui::AnsiGrayscale::GRAY }

  before do
    Tuile::Screen.fake
    # TTY::Markdown.parse probes the TTY for width via ioctl on $stdout,
    # which StringIO/PTY-less rspec runs can't satisfy. Swap to a
    # passthrough for the duration of the spec so assistant rendering
    # doesn't blow up; the actual Markdown rendering quality is tty-
    # markdown's responsibility, not ours.
    @original_md_parse = TTY::Markdown.method(:parse)
    TTY::Markdown.define_singleton_method(:parse) { |text, **| text }
  end

  after do
    original = @original_md_parse
    TTY::Markdown.define_singleton_method(:parse) { |*a, **k| original.call(*a, **k) }
    Tuile::Screen.close
  end

  def rendered = text_view.text.to_s

  it 'renders UserTurn as "> <content>" (the CLI listener stayed silent here)' do
    listener.on_event(Pikuri::Agent::Event::UserTurn.new(content: 'hello?'))
    assert_includes rendered, '> hello?'
  end

  it 'renders Thinking content (so the user sees the reasoning stream)' do
    listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'pondered'))
    assert_includes rendered, 'pondered'
  end

  it 'renders Assistant content through TTY::Markdown' do
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

  it 'renders FallbackNotice with the reason' do
    listener.on_event(Pikuri::Agent::Event::FallbackNotice.new(reason: 'budget'))
    assert_includes rendered, '! budget'
  end

  it 'renders Cancelled as a "! cancelled" notice' do
    listener.on_event(Pikuri::Agent::Event::Cancelled.new)
    assert_includes rendered, '! cancelled'
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
    TTY::Markdown.define_singleton_method(:parse) { |*| raise StandardError, 'boom' }
    captured = StringIO.new
    Tuile.logger = Logger.new(captured)
    listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'plain content'))
    assert_includes rendered, 'plain content'
    assert_includes captured.string, 'MarkdownRenderer.render failed'
  end

  it 'reports its short label as "TuileListener" (used by Agent#to_s)' do
    assert_equal 'TuileListener', listener.to_s
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
      # thinking block is the whole reason flush_thinking is non-wiping.
      assert_includes lines, 'before'
      after_line = lines.find { |l| l.include?('after') }
      refute_nil after_line
      refute_equal 'before', after_line
    end

    it 'reconciles the streamed thinking with the Thinking bookend when they diverge' do
      # Real-world case: the provider truncates the delta stream and the
      # bookend carries content that the deltas never delivered. The
      # streamed preview must be replaced by the authoritative content so
      # the user sees the full reasoning, not just the prefix the deltas
      # got through.
      listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: 'streamed'))
      listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'streamed (authoritative)'))
      assert_includes rendered, 'streamed (authoritative)'
    end

    it 'suppresses the Thinking bookend when AssistantDelta arrived between deltas and bookend' do
      listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: 'reasoning'))
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'answer'))
      listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'reasoning (authoritative)'))
      listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'answer'))
      # AssistantDelta releases the thinking buffer (the streamed
      # reasoning is preserved in its region but the handle is dropped
      # so the next ThinkingDelta opens fresh). The bookend that follows
      # then has nowhere to land — @thinking_buffer is nil and
      # @thinking_streamed is still true, so neither finalize-buffer nor
      # non-streaming-add_block fires. That's intentional: in this
      # interleaved order the streamed preview already shipped to the
      # screen, and rendering the bookend a second time as a new block
      # would duplicate the reasoning. The reconcile-on-divergence path
      # only protects the non-interleaved case, which is by far the more
      # common one (deltas truncated before the bookend arrives).
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
      TTY::Markdown.define_singleton_method(:parse) { |_text, **_kwargs| "\e[31mred-from-renderer\e[0m" }
      listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: 'anything'))
      fg_colors = text_view.text.spans.map { |s| s.style.fg }
      refute_includes fg_colors, Tuile::Color.new(:red)
      assert_includes fg_colors, gray
    end

    it 'preserves bold/italic/underline while repainting fg to gray' do
      TTY::Markdown.define_singleton_method(:parse) do |_text, **_kwargs|
        "\e[1;3;4;31mbold italic underlined red\e[0m"
      end
      listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: 'anything'))
      span = text_view.text.spans.find { |s| s.text.include?('bold italic underlined red') }
      refute_nil span, 'expected a span carrying the rendered text'
      assert_equal gray, span.style.fg
      assert span.style.bold,      'bold should pass through the recolor'
      assert span.style.italic,    'italic should pass through the recolor'
      assert span.style.underline, 'underline should pass through the recolor'
    end

    it 'renders the non-streaming Thinking bookend in the same gray tone' do
      TTY::Markdown.define_singleton_method(:parse) { |_text, **_kwargs| "\e[31mred\e[0m" }
      listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'bookend'))
      fg_colors = text_view.text.spans.map { |s| s.style.fg }
      assert_includes fg_colors, gray
      refute_includes fg_colors, Tuile::Color.new(:red)
    end
  end

  context 'markdown: false' do
    let(:listener) do
      described_class.new(text_view: text_view, screen: Tuile::Screen.instance, markdown: false)
    end

    # If the TTY::Markdown stub fired we'd see no behavior difference vs
    # markdown: true (the stub is a passthrough). Replace it with a
    # sentinel that would *always* be visible if invoked, so the spec
    # actually proves the flag short-circuits the render.
    before do
      TTY::Markdown.define_singleton_method(:parse) { |*| 'MARKDOWN_RAN' }
    end

    it 'echoes non-streaming Assistant content verbatim, skipping TTY::Markdown' do
      listener.on_event(Pikuri::Agent::Event::Assistant.new(content: '**not bold here**'))
      assert_includes rendered, '**not bold here**'
      refute_includes rendered, 'MARKDOWN_RAN'
    end

    it 'echoes the non-streaming Thinking bookend verbatim (still gray-tinted)' do
      listener.on_event(Pikuri::Agent::Event::Thinking.new(content: '**raw thinking**'))
      assert_includes rendered, '**raw thinking**'
      refute_includes rendered, 'MARKDOWN_RAN'
      fg_colors = text_view.text.spans.map { |s| s.style.fg }
      assert_includes fg_colors, gray
    end

    it 'streams AssistantDelta content through PassthroughBuffer (no Markdown render)' do
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: '**still literal**'))
      assert_includes rendered, '**still literal**'
      refute_includes rendered, 'MARKDOWN_RAN'
    end

    it 'streams ThinkingDelta content through PassthroughBuffer, gray-tinted' do
      listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: '**still literal**'))
      assert_includes rendered, '**still literal**'
      refute_includes rendered, 'MARKDOWN_RAN'
      fg_colors = text_view.text.spans.map { |s| s.style.fg }
      assert_includes fg_colors, gray
    end
  end
end
