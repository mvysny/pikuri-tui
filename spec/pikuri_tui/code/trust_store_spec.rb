# frozen_string_literal: true

require 'tmpdir'

RSpec.describe PikuriTui::Code::TrustStore do
  around do |example|
    Dir.mktmpdir('pikuri-trust-store') do |dir|
      @dir = dir
      example.run
    end
  end

  # Trust list lives outside the dirs we trust, so creating it never disturbs
  # the realpath checks of the projects under test.
  let(:list_path) { File.join(@dir, 'trusted-projects') }
  let(:store)     { described_class.new(path: list_path) }

  # A real, existing directory to stand in for a project root (realpath
  # requires the path to exist).
  def mkdir(name)
    path = File.join(@dir, name)
    Dir.mkdir(path)
    path
  end

  def list_lines
    File.exist?(list_path) ? File.readlines(list_path, chomp: true).reject(&:empty?) : []
  end

  it 'reports untrusted when the file does not exist' do
    refute store.trusted?(mkdir('proj'))
  end

  it 'reports untrusted for an empty file' do
    File.write(list_path, '')
    refute store.trusted?(mkdir('proj'))
  end

  it 'round-trips a trusted path' do
    proj = mkdir('proj')
    store.trust!(proj)
    assert store.trusted?(proj)
  end

  it 'is idempotent: trusting twice writes a single line' do
    proj = mkdir('proj')
    store.trust!(proj)
    store.trust!(proj)
    assert_equal 1, list_lines.size
  end

  it 'matches across symlink aliases' do
    real = mkdir('real')
    link = File.join(@dir, 'link')
    File.symlink(real, link)

    store.trust!(real)
    assert store.trusted?(link), 'symlink alias of a trusted real path is trusted'

    other = described_class.new(path: File.join(@dir, 'other-list'))
    other.trust!(link)
    assert other.trusted?(real), 'trusting via the symlink trusts the real path too'
  end

  it 'treats a trailing slash identically' do
    proj = mkdir('proj')
    store.trust!(proj)
    assert store.trusted?(Pathname("#{proj}/"))
  end

  it 'does not prefix-match a sibling path' do
    proj = mkdir('proj')
    mkdir('proj-evil')
    store.trust!(proj)
    refute store.trusted?(File.join(@dir, 'proj-evil'))
  end

  it 'does not trust an unrelated path' do
    a = mkdir('a')
    b = mkdir('b')
    store.trust!(a)
    refute store.trusted?(b)
  end

  it 'tolerates a stale stored entry without raising' do
    gone = mkdir('gone')
    live = mkdir('live')
    store.trust!(gone)
    store.trust!(live)
    Dir.rmdir(gone) # the stored line for `gone` can no longer be realpath'd

    assert store.trusted?(live), 'a live entry still resolves past a stale one'
    refute store.trusted?(mkdir('other'))
  end

  it 'accepts both Pathname and String arguments' do
    proj = mkdir('proj')
    store.trust!(Pathname(proj))
    assert store.trusted?(proj.to_s)
  end

  # Pointing the store at a directory path makes File.readlines / File.write
  # raise a real SystemCallError (Errno::EISDIR), exercising the rescue
  # without a mocking framework (the suite uses none).
  it 'degrades to untrusted (no raise) when the read fails' do
    bad = described_class.new(path: @dir)
    assert_equal false, bad.trusted?(mkdir('proj'))
  end

  it 'degrades (no raise) when the write fails' do
    bad = described_class.new(path: @dir)
    proj = mkdir('proj')
    bad.trust!(proj) # must not raise though the write to a directory fails
    refute bad.trusted?(proj), 'a failed persist leaves the repo untrusted'
  end

  it 'defaults its path under Pikuri::Paths.state' do
    prev = ENV['XDG_STATE_HOME']
    ENV['XDG_STATE_HOME'] = @dir
    expected = File.join(@dir, 'pikuri', 'trusted-projects')
    assert_equal expected, described_class.new.instance_variable_get(:@path)
  ensure
    ENV['XDG_STATE_HOME'] = prev
  end
end
