# frozen_string_literal: true

require 'tmpdir'

RSpec.describe Code::PrivacyStore do
  around do |example|
    Dir.mktmpdir('pikuri-privacy-store') do |dir|
      @dir = dir
      example.run
    end
  end

  # The list lives outside the dirs it records, so creating it never disturbs
  # the realpath checks of the projects under test.
  let(:list_path) { File.join(@dir, 'private-projects') }
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

  it 'reports "never asked" when the file does not exist' do
    assert_nil store.answer(mkdir('proj'))
  end

  it 'reports "never asked" for an empty file' do
    File.write(list_path, '')
    assert_nil store.answer(mkdir('proj'))
  end

  it 'round-trips a private answer' do
    proj = mkdir('proj')
    store.record!(proj, private: true)
    assert_equal true, store.answer(proj)
  end

  # The whole point of persisting a no: a public project must stop being asked.
  it 'round-trips a public answer, distinct from never-asked' do
    proj = mkdir('proj')
    store.record!(proj, private: false)
    assert_equal false, store.answer(proj)
  end

  it 'keeps answers per project' do
    private_proj = mkdir('secret')
    public_proj  = mkdir('oss')
    store.record!(private_proj, private: true)
    store.record!(public_proj, private: false)
    assert_equal true, store.answer(private_proj)
    assert_equal false, store.answer(public_proj)
    assert_nil store.answer(mkdir('unasked'))
  end

  it 'writes one canonical "verdict path" line' do
    proj = mkdir('proj')
    store.record!(proj, private: true)
    assert_equal ["private #{File.realpath(proj)}"], list_lines
  end

  it 'is idempotent: re-recording the same answer appends nothing' do
    proj = mkdir('proj')
    store.record!(proj, private: true)
    store.record!(proj, private: true)
    assert_equal 1, list_lines.size
  end

  it 'lets a later answer override an earlier one (last line wins)' do
    proj = mkdir('proj')
    store.record!(proj, private: false)
    store.record!(proj, private: true)
    assert_equal true, store.answer(proj)
    assert_equal 2, list_lines.size
  end

  it 'normalizes symlink aliases and trailing slashes on both write and read' do
    proj = mkdir('proj')
    link = File.join(@dir, 'alias')
    File.symlink(proj, link)
    store.record!("#{link}/", private: true)
    assert_equal true, store.answer(proj)
    assert_equal ["private #{File.realpath(proj)}"], list_lines
  end

  it 'treats a nonexistent project root as never-asked rather than raising' do
    assert_nil store.answer(File.join(@dir, 'gone'))
  end

  it 'skips a stale entry whose path no longer resolves, without poisoning the rest' do
    proj = mkdir('proj')
    File.write(list_path, "private #{File.join(@dir, 'deleted')}\npublic #{proj}\n")
    assert_equal false, store.answer(proj)
  end

  it 'skips a malformed line' do
    proj = mkdir('proj')
    File.write(list_path, "garbage\nmaybe #{proj}\nprivate #{proj}\n")
    assert_equal true, store.answer(proj)
  end

  it 'handles a project path containing spaces' do
    proj = File.join(@dir, 'my project')
    Dir.mkdir(proj)
    store.record!(proj, private: true)
    assert_equal true, store.answer(proj)
  end

  it 'degrades to not-persisted (logged, not raised) when the file cannot be written' do
    proj = mkdir('proj')
    unwritable = described_class.new(path: File.join(@dir, 'missing-dir', 'private-projects'))
    log = capture_log { unwritable.record!(proj, private: true) }
    assert_includes log, 'could not persist the privacy answer'
    assert_nil unwritable.answer(proj)
  end
end
