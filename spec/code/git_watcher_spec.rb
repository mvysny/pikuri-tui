# frozen_string_literal: true

require 'tmpdir'
require 'open3'

# GitWatcher is now the pure data-producing model: it polls git and pushes
# *data* (a GitSummaryTextView::Change list + raw diff text) to the panes, which
# own rendering. So this spec asserts on the captured data and on change
# detection; how that data is drawn is covered by the view specs
# (git_summary_text_view_spec / git_diff_text_view_spec).
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

  let(:summary_view) { Code::GitSummaryTextView.new }
  let(:diff_view)    { Code::GitDiffTextView.new }
  let(:watcher) do
    described_class.new(
      summary_view: summary_view, diff_view: diff_view, screen: Tuile::Screen.instance, cwd: @repo
    )
  end

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  # The captured data snapshot (the watcher's product), without a poll thread.
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
      assert_equal Code::GitSummaryTextView::UNTRACKED_CODE, change.code
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

  describe 'change detection' do
    it 'does not re-render when nothing changed' do
      write('tracked.txt', "l1\nCHANGED\nl3\n")
      assert watcher.poll_once, 'first poll should push the change'
      refute watcher.poll_once, 'an identical state should be skipped'
    end

    it 're-renders after a further change' do
      write('tracked.txt', "l1\nCHANGED\nl3\n")
      assert watcher.poll_once
      write('tracked.txt', "l1\nCHANGED twice\nl3\n")
      assert watcher.poll_once, 'a fresh change should push'
    end

    it 'pushes the captured data through to the panes on poll' do
      write('tracked.txt', "l1\nCHANGED\nl3\n")
      watcher.poll_once # FakeEventQueue#submit runs synchronously
      assert_includes summary_view.text.to_s, 'tracked.txt'
      assert_includes diff_view.text.to_s, 'tracked.txt'
    end
  end

  it 'degrades to a logged error notice when git cannot be launched' do
    bogus = described_class.new(
      summary_view: summary_view, diff_view: diff_view,
      screen: Tuile::Screen.instance, cwd: '/no/such/dir'
    )
    snapshot = bogus.send(:capture)
    assert_includes snapshot.error, 'git unavailable'
    assert_empty snapshot.changes
    # …and the notice reaches both panes on push.
    bogus.poll_once
    assert_includes summary_view.text.to_s, 'git unavailable'
    assert_includes diff_view.text.to_s, 'git unavailable'
  end

  it 'stops the poll thread cleanly' do
    fast = described_class.new(
      summary_view: summary_view, diff_view: diff_view,
      screen: Tuile::Screen.instance, cwd: @repo, interval: 0.01
    )
    fast.start
    fast.stop # must return; a hung join would fail the suite via timeout
    assert true
  end
end
