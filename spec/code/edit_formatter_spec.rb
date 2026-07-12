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
      assert_includes text, '✎ edit  lib/foo.rb'
      assert_includes text, '- def foo'
      assert_includes text, '+ def bar'
    end

    it 'accepts symbol-keyed arguments' do
      out = described_class.new.render_call(
        arguments: { path: 'a.rb', old_string: 'x', new_string: 'y' },
        width: 40, theme: theme
      )
      text = plain(out)
      assert_includes text, '✎ edit  a.rb'
      assert_includes text, '- x'
      assert_includes text, '+ y'
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
    it 'suppresses (nil) a success observation' do
      assert_nil described_class.new.render_result(
        content: 'Edited a.rb: replaced 1 occurrence.', theme: theme
      )
    end

    it 'surfaces an Error observation as a themed line' do
      out = described_class.new.render_result(content: 'Error: old_string not found in a.rb.', theme: theme)
      assert_includes plain(out), '✗ Error: old_string not found in a.rb.'
    end
  end
end
