# frozen_string_literal: true

RSpec.describe Code::EditFormatter do
  let(:theme) { Shared::AppTheme::DARK }

  # Plain text of the rendered output, with the header's ANSI fg stripped.
  def plain(ansi)
    Tuile::StyledString.parse(ansi).to_s
  end

  describe '#render_call' do
    it 'renders a header and a before/after diff of the strings' do
      out = described_class.new.render_call(
        arguments: { 'path' => 'lib/foo.rb', 'old_string' => "def foo\n", 'new_string' => "def bar\n" },
        width: 40, theme: theme
      )
      text = plain(out)
      assert_includes text, '✎ Edit(lib/foo.rb)'
      assert_includes text, '- def foo'
      assert_includes text, '+ def bar'
    end

    it 'accepts symbol-keyed arguments' do
      out = described_class.new.render_call(
        arguments: { path: 'a.rb', old_string: 'x', new_string: 'y' },
        width: 40, theme: theme
      )
      text = plain(out)
      assert_includes text, '✎ Edit(a.rb)'
      assert_includes text, '- x'
      assert_includes text, '+ y'
    end

    # DiffRenderer emits its span text verbatim, so an ESC in a written line
    # would recolor every cell after it — and the header's path and the diff
    # body are both model-authored.
    it 'defangs an ESC in the path and in the diffed content' do
      out = described_class.new.render_call(
        arguments: { 'path' => "a\e[31m.rb", 'old_string' => 'x', 'new_string' => "y\e[35mz" },
        width: 40, theme: theme
      )
      text = plain(out)
      assert_includes text, '✎ Edit(a\x1b[31m.rb)'
      assert_includes text, '+ y\x1b[35mz'
      refute_includes Tuile::StyledString.parse(out).spans.map { |s| s.style.fg },
                      Tuile::Color.new(:magenta)
    end

    it 'returns nil and logs when rendering raises (degrade, not crash)' do
      # A non-Hash arguments value blows up on transform_keys.
      out = nil
      log = capture_log { out = described_class.new.render_call(arguments: Object.new, width: 40, theme: theme) }
      assert_nil out
      assert_includes log, 'EditFormatter'
    end
  end

  describe '#render_result' do
    it 'suppresses (nil) a success summary' do
      assert_nil described_class.new.render_result(
        summary: 'Replaced 1 occurrence in a.rb', theme: theme
      )
    end

    it 'surfaces an Error summary as a themed line' do
      out = described_class.new.render_result(summary: 'Error: old_string not found in a.rb.', theme: theme)
      assert_includes plain(out), '✗ Error: old_string not found in a.rb.'
    end

    it 'defangs an ESC in the summary, and keeps it to one row' do
      out = described_class.new.render_result(summary: "Error: no \e[31mmatch\nin a.rb", theme: theme)
      assert_equal '✗ Error: no \x1b[31mmatch in a.rb', plain(out)
    end
  end
end
