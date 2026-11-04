# frozen_string_literal: true

require 'tmpdir'

RSpec.describe Shared::AttachmentTokens do
  let(:png) { "\x89PNG\r\n\x1a\n#{'x' * 16}".b }

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def write(name, bytes = png)
    File.binwrite(File.join(@dir, name), bytes)
    File.join(@dir, name)
  end

  def split(line) = described_class.split(line)

  it 'leaves a line without tokens alone' do
    assert_equal ['just text', []], split('just text')
  end

  it 'attaches a bare token, leaving the basename in the text' do
    path = write('shot.png')
    text, images = split("@#{path} what's wrong?")
    assert_equal "shot.png what's wrong?", text
    assert_equal ['shot.png'], images.map(&:filename)
    assert_equal 'image/png', images.first.mime
    assert_equal png, images.first.bytes
  end

  it 'resolves a relative path against the working directory' do
    write('shot.png')
    assert_equal 1, Dir.chdir(@dir) { split('@shot.png') }.last.size
  end

  it 'takes the quoted and escaped forms a terminal pastes for a dragged file' do
    path = write('my shot.png')
    ["@'#{path}'", "@\"#{path}\"", "@#{path.gsub(' ', '\\ ')}"].each do |token|
      text, images = split("#{token} hi")
      assert_equal 'my shot.png hi', text, token
      assert_equal 1, images.size, token
    end
  end

  it 'keeps several images in token order' do
    a = write('a.png')
    b = write('b.png')
    text, images = split("compare @#{a} with @#{b}")
    assert_equal 'compare a.png with b.png', text
    assert_equal %w[a.png b.png], images.map(&:filename)
  end

  it 'leaves sentence punctuation behind a bare token in the text' do
    path = write('shot.png')
    text, images = split("see @#{path}, please")
    assert_equal 'see shot.png, please', text
    assert_equal 1, images.size
  end

  it 'keeps punctuation that is really part of the file name' do
    path = write('odd.png,')
    assert_equal ['odd.png,'], split("@#{path}").last.map(&:filename)
  end

  it 'leaves a mention and a mid-word @ as text' do
    assert_equal ['ask @alice, or bob@example.com', []], split('ask @alice, or bob@example.com')
  end

  it 'refuses a path-like token that names no file' do
    error = assert_raises(described_class::Error) { split("@#{@dir}/missing.png hi") }
    assert_equal "No such file: #{@dir}/missing.png", error.message
    assert_raises(described_class::Error) { split('@missing.png hi') }
    assert_raises(described_class::Error) { split('@some/dir/x hi') }
  end

  it 'refuses a file that is not a supported image' do
    path = write('notes.txt', 'hello')
    error = assert_raises(described_class::Error) { split("@#{path}") }
    assert_equal 'notes.txt is not a PNG, JPEG, GIF or WebP image', error.message
  end

  it 'refuses an empty file' do
    path = write('empty.png', '')
    assert_raises(described_class::Error) { split("@#{path}") }
  end

  it 'refuses an image over the cap' do
    path = write('big.png', png + ('x' * described_class::MAX_BYTES))
    error = assert_raises(described_class::Error) { split("@#{path}") }
    assert_equal 'big.png is over 5.0 MB', error.message
  end

  it 'refuses an unknown user in a ~ path' do
    assert_raises(described_class::Error) { split('@~nosuchuser_pikuri/x.png') }
  end

  describe '.token' do
    def token(arg) = described_class.token(arg)

    it 'returns a bare token for a plain path' do
      path = write('shot.png')
      assert_equal "@#{path}", token(path)
    end

    it 'takes a dragged (quoted or escaped) path, or an unquoted one with spaces, and quotes it' do
      path = write('my shot.png')
      ["'#{path}'", "\"#{path}\"", path.gsub(' ', '\\ '), path].each do |arg|
        assert_equal "@'#{path}'", token(arg), arg
      end
    end

    it 'escapes a path that holds a single quote, and split reads it back' do
      path = write("it's.png")
      tok = token(path)
      assert_equal(["it's.png", ["it's.png"]], split(tok).then { |t, i| [t, i.map(&:filename)] })
    end

    it 'round-trips through split for a path with spaces' do
      path = write('my shot.png')
      assert_equal ['my shot.png'], split("#{token(path)} hi").last.map(&:filename)
    end

    it 'refuses a blank argument, a missing file and a non-image' do
      assert_equal 'Usage: /image <path>', assert_raises(described_class::Error) { token('  ') }.message
      assert_raises(described_class::Error) { token("#{@dir}/nope.png") }
      assert_raises(described_class::Error) { token(write('notes.txt', 'hi')) }
    end
  end
end
