# frozen_string_literal: true

RSpec.describe Shared::TrifectaRenderer do
  # No screen: the renderer takes the theme, so a plain AppTheme is enough.
  let(:theme) { Shared::AppTheme::DARK }

  # One agent node, tools only, so the verdict is decided by the legs passed in.
  def report(tools)
    Pikuri::Trifecta.walk(
      Pikuri::Trifecta::Node.new(label: 'pikuri-tui-code', tool_legs: tools, children: [])
    )
  end

  def legs(private: false, untrusted: :none, egress: :no_egress)
    Pikuri::Tool::TrifectaLegs.new(private: private, untrusted: untrusted, egress_payload_review: egress)
  end

  let(:loud) do
    report('read' => legs(private: true, untrusted: :hard),
           'bash' => legs(egress: :unreviewed))
  end

  it 'keeps the advisory on the first line and the map below it, verbatim' do
    rendered = described_class.render(loud, theme: theme)
    lines = rendered.lines(chomp: true)
    assert_includes lines.first, loud.advisory
    assert_equal '', lines[1]
    assert_equal ['pikuri-tui-code [:private, :untrusted_hard, :egress]',
                  '  read [:private, :untrusted_hard]',
                  '  bash [:egress]'],
                 lines[2..]
  end

  it 'paints a loud advisory in the error tone (the one line that must shout)' do
    assert_equal theme.error(loud.advisory), described_class.render(loud, theme: theme).lines(chomp: true).first
  end

  it 'paints a soft advisory in the notice tone' do
    soft = report('read' => legs(private: true, untrusted: :hard),
                  'compose' => legs(egress: :human_reviewed))
    assert_equal :soft, soft.tree_verdict
    assert_equal theme.notice(soft.advisory), described_class.render(soft, theme: theme).lines(chomp: true).first
  end

  it 'dims a silent advisory rather than greening it — a missing leg is not a clean bill of health' do
    silent = report('read' => legs(untrusted: :hard), 'bash' => legs(egress: :unreviewed))
    assert_equal :silent, silent.tree_verdict
    assert_equal theme.detail(silent.advisory), described_class.render(silent, theme: theme).lines(chomp: true).first
  end

  it 'renders a sub-agent subtree with its gate and indented tools' do
    child = Pikuri::Trifecta::Node.new(
      label: 'RESEARCHER', tool_legs: { 'fetch' => legs(untrusted: :hard, egress: :unreviewed) },
      children: [], channel_egress: :unreviewed
    )
    parent = Pikuri::Trifecta.walk(
      Pikuri::Trifecta::Node.new(label: 'pikuri-tui-computer',
                                 tool_legs: { 'read' => legs(private: true) }, children: [child])
    )
    rendered = described_class.render(parent, theme: theme)
    assert_includes rendered, '  RESEARCHER [gate: unreviewed]'
    assert_includes rendered, '    fetch [:untrusted_hard, :egress]'
  end
end
