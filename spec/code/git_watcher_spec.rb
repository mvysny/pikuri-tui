# frozen_string_literal: true

require 'tmpdir'
require 'open3'

# GitWatcher is a UI-independent service: it polls git and emits a Snapshot
# (a Change list + raw diff text) to registered listeners on its poll thread.
# It has no screen, no views. So this spec asserts on the captured data, on the
# emit-on-change contract, and on change detection; how the data is drawn is
# covered by the view specs, and the snapshot->view wiring by app_spec.
RSpec.describe Code::GitWatcher do
  around do |example|
    Dir.mktmpdir('pikuri-git-watcher') do |dir|
      @repo = dir
      run('git', 'init', '-q')
      run('git', 'config', 'user.email', 'spec@example.com')
      run('git', 'config', 'user.name', 'Spec')
      write('tracked.txt', "l1\nl2\nl3\n")
      run('git', 'add', '.')
      run('git', 'commit', '-qm', 'initial')
      example.run
    end
  end

  let(:watcher) { described_class.new(cwd: @repo) }

  # The captured data snapshot (the service's product), without a poll thread.
  def capture = watcher.send(:capture)

  def run(*argv) = Open3.capture2e(*argv, chdir: @repo)
  def write(name, body) = File.write(File.join(@repo, name), body)

  it 'captures nothing when the tree matches HEAD' do
    snapshot = capture
    assert_empty snapshot.changes
    assert_empty snapshot.diff_text
    assert_nil snapshot.error
  end

  describe 'the captured change data' do
    it 'reports a modified tracked file with its code and +/- counts' do
      write('tracked.txt', "l1\nCHANGED\nl3\nl4\n") # one line changed, one added
      change = capture.changes.find { |c| c.path == 'tracked.txt' }
      refute_nil change
      assert_includes change.code, 'M'
      assert_equal 2, change.added
      assert_equal 1, change.deleted
    end

    it 'reports an untracked file with its whole line count as additions' do
      write('fresh.txt', "a\nb\nc\n")
      change = capture.changes.find { |c| c.path == 'fresh.txt' }
      refute_nil change
      assert_equal Code::GitWatcher::UNTRACKED_CODE, change.code
      assert_equal 3, change.added
      assert_equal 0, change.deleted
    end

    it 'reports tracked and untracked changes together, one entry each' do
      write('tracked.txt', "l1\nl2\nl3\nl4\n")
      write('fresh.txt', "x\n")
      paths = capture.changes.map(&:path)
      assert_equal %w[tracked.txt fresh.txt].sort, paths.sort
    end
  end

  describe 'the captured diff text' do
    it 'includes the raw hunk for a modified tracked file' do
      write('tracked.txt', "l1\nCHANGED\nl3\n")
      diff = capture.diff_text
      assert_includes diff, 'tracked.txt'
      assert_includes diff, '-l2'
      assert_includes diff, '+CHANGED'
    end

    it 'includes untracked files as a new-file diff via --no-index' do
      write('fresh.txt', "brand new\n")
      diff = capture.diff_text
      assert_includes diff, 'fresh.txt'
      assert_includes diff, '+brand new'
    end
  end

  describe 'emit / change detection' do
    it 'emits the captured snapshot to every registered listener on change' do
      write('tracked.txt', "l1\nCHANGED\nl3\n")
      received = []
      watcher.on_change { |s| received << s }
      assert watcher.poll_once, 'first poll should emit'
      assert_equal 1, received.size
      assert_includes received.first.diff_text, 'CHANGED'
    end

    it 'does not emit again when the state is unchanged' do
      received = []
      watcher.on_change { |s| received << s }
      assert watcher.poll_once, 'first capture always emits (differs from nil)'
      refute watcher.poll_once, 'an identical state should be skipped'
      assert_equal 1, received.size
    end

    it 're-emits after a further change' do
      write('tracked.txt', "l1\nCHANGED\nl3\n")
      assert watcher.poll_once
      write('tracked.txt', "l1\nCHANGED twice\nl3\n")
      assert watcher.poll_once, 'a fresh change should emit'
    end
  end

  it 'degrades to a logged error snapshot when git cannot be launched' do
    bogus = described_class.new(cwd: '/no/such/dir')
    snapshot = bogus.send(:capture)
    assert_includes snapshot.error, 'git unavailable'
    assert_empty snapshot.changes
  end

  it 'stops the poll thread cleanly' do
    fast = described_class.new(cwd: @repo, interval: 0.01)
    fast.start
    fast.stop # must return; a hung join would fail the suite via timeout
    assert true
  end
end
