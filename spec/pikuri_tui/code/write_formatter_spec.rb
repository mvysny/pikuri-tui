# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'pathname'

RSpec.describe PikuriTui::Code::WriteFormatter do
  let(:theme) { PikuriTui::AppTheme::DARK }
  let(:tmp)   { Pathname.new(Dir.mktmpdir) }

  after { FileUtils.remove_entry(tmp) if tmp.exist? }

  def plain(ansi)
    Tuile::StyledString.parse(ansi).to_s
  end

  # Minimal workspace stand-in: maps a raw path to a Pathname (or raises,
  # for the boundary-violation case). The formatter only calls
  # resolve_for_write.
  def workspace(map)
    Class.new do
      def initialize(map) = @map = map
      def resolve_for_write(path) = @map.fetch(path) { raise "outside workspace: #{path}" }
    end.new(map)
  end

  describe '#render_call' do
    it 'diffs the existing file against the new content (verb: write)' do
      file = tmp.join('foo.rb')
      file.write("a\nb\n")
      out = described_class.new(workspace: workspace('foo.rb' => file)).render_call(
        arguments: { 'path' => 'foo.rb', 'content' => "a\nc\n" }, width: 40, theme: theme
      )
      text = plain(out)
      assert_includes text, '✎ write  foo.rb'
      assert_includes text, '- b'
      assert_includes text, '+ c'
    end

    it 'renders a not-yet-existing file as an all-added create' do
      file = tmp.join('new.rb')
      out = described_class.new(workspace: workspace('new.rb' => file)).render_call(
        arguments: { 'path' => 'new.rb', 'content' => "x\ny\n" }, width: 40, theme: theme
      )
      text = plain(out)
      assert_includes text, '✎ create  new.rb'
      assert_includes text, '+ x'
      assert_includes text, '+ y'
    end

    it 'falls back (nil) when the existing file is binary' do
      file = tmp.join('bin.dat')
      file.binwrite("\xff\xfe\x00\x01".b)
      out = described_class.new(workspace: workspace('bin.dat' => file)).render_call(
        arguments: { 'path' => 'bin.dat', 'content' => 'text' }, width: 40, theme: theme
      )
      assert_nil out
    end

    it 'falls back (nil) when the path is a directory' do
      out = described_class.new(workspace: workspace('d' => tmp)).render_call(
        arguments: { 'path' => 'd', 'content' => 'x' }, width: 40, theme: theme
      )
      assert_nil out
    end

    it 'falls back (nil) and logs when resolution raises (outside workspace)' do
      captured = StringIO.new
      Tuile.logger = Logger.new(captured)
      out = described_class.new(workspace: workspace({})).render_call(
        arguments: { 'path' => '../escape', 'content' => 'x' }, width: 40, theme: theme
      )
      assert_nil out
      assert_includes captured.string, 'WriteFormatter'
    end
  end

  describe '#render_result' do
    it 'suppresses (nil) a success observation' do
      assert_nil described_class.new(workspace: workspace({})).render_result(
        content: 'Created foo.rb (10 bytes)', theme: theme
      )
    end

    it 'surfaces an Error observation as a themed line' do
      out = described_class.new(workspace: workspace({})).render_result(
        content: 'Error: user declined the write to foo.rb.', theme: theme
      )
      assert_includes plain(out), '✗ Error: user declined the write to foo.rb.'
    end
  end
end
