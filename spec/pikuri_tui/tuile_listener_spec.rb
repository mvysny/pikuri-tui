# frozen_string_literal: true

RSpec.describe PikuriTui::TuileListener do
  let(:text_view) { Tuile::Component::TextView.new }
  let(:listener)  { described_class.new(text_view: text_view, screen: Tuile::Screen.instance) }

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

  it 'logs and falls back to raw text when TTY::Markdown raises' do
    TTY::Markdown.define_singleton_method(:parse) { |*| raise StandardError, 'boom' }
    captured = StringIO.new
    Tuile.logger = Logger.new(captured)
    listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'plain content'))
    assert_includes rendered, 'plain content'
    assert_includes captured.string, 'TTY::Markdown render failed'
  end

  it 'reports its short label as "TuileListener" (used by Agent#to_s)' do
    assert_equal 'TuileListener', listener.to_s
  end
end
