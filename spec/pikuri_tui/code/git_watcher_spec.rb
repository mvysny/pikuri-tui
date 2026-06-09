# frozen_string_literal: true

require 'tmpdir'
require 'open3'

RSpec.describe PikuriTui::Code::GitWatcher do
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

  let(:summary_view) { Tuile::Component::TextView.new }
  let(:diff_view)    { Tuile::Component::TextView.new }
  let(:watcher) do
    described_class.new(
      summary_view: summary_view, diff_view: diff_view, screen: Tuile::Screen.instance, cwd: @repo
    )
  end

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  # FakeEventQueue#submit runs the block synchronously, so after poll_once
  # both panes already hold their rendered text.
  def summary = summary_view.text.to_s
  def diff = diff_view.text.to_s

  def run(*argv) = Open3.capture2e(*argv, chdir: @repo)
  def write(name, body) = File.write(File.join(@repo, name), body)

  it 'shows the placeholder in both panes when the tree matches HEAD' do
    assert watcher.poll_once
    assert_includes summary, PikuriTui::Code::GitWatcher::PLACEHOLDER
    assert_includes diff, PikuriTui::Code::GitWatcher::PLACEHOLDER
  end

  describe 'the sidebar summary' do
    it 'lists a modified tracked file with its status code and +/- counts' do
      write('tracked.txt', "l1\nCHANGED\nl3\nl4\n") # one line changed, one added
      watcher.poll_once
      assert_includes summary, 'M tracked.txt'
      assert_includes summary, '+2'
      assert_includes summary, '-1'
    end

    it 'lists an untracked file with its whole line count as additions' do
      write('fresh.txt', "a\nb\nc\n")
      watcher.poll_once
      assert_includes summary, '?? fresh.txt'
      assert_includes summary, '+3'
    end

    it 'lists tracked and untracked changes together, one line each' do
      write('tracked.txt', "l1\nl2\nl3\nl4\n")
      write('fresh.txt', "x\n")
      watcher.poll_once
      assert_includes summary, 'M tracked.txt'
      assert_includes summary, '?? fresh.txt'
      assert_equal 2, summary.lines.size
    end
  end

  describe 'the summary status colors' do
    let(:theme) { Tuile::Screen.instance.theme }

    # The label "XY path" is one styled span (uniform color); the +/- count
    # markers are separate spans. Find the span carrying the path.
    def label_color(substr)
      summary_view.text.spans.find { |span| span.text.include?(substr) }&.style&.fg
    end

    it 'tones new files green' do
      write('fresh.txt', "x\n")
      watcher.poll_once
      assert_equal theme[:added], label_color('fresh.txt')
    end

    it 'tones deleted files red' do
      File.delete(File.join(@repo, 'tracked.txt'))
      watcher.poll_once
      assert_equal theme[:removed], label_color('tracked.txt')
    end

    it 'tones modified files yellow' do
      write('tracked.txt', "l1\nCHANGED\nl3\n")
      watcher.poll_once
      assert_equal theme[:notice], label_color('tracked.txt')
    end
  end

  describe 'the full diff pane' do
    # The pane is rendered through GitDiffRenderer, not git's own coloring: a
    # themed "✎ path" header over "@@ line N @@" separators over the
    # DiffRenderer hunk bodies (whose gutter is "- "/"+ ", with a space). Under
    # the suite's NO_COLOR a modified line falls back to the delete + add pair.
    it 'renders a themed header and the hunk for a modified tracked file' do
      write('tracked.txt', "l1\nCHANGED\nl3\n")
      watcher.poll_once
      assert_includes diff, '✎ tracked.txt'
      assert_includes diff, '@@ line 1 @@'
      assert_includes diff, '- l2'
      assert_includes diff, '+ CHANGED'
    end

    it 'renders untracked files as a new-file addition via --no-index' do
      write('fresh.txt', "brand new\n")
      watcher.poll_once
      assert_includes diff, '✎ fresh.txt (new file)'
      assert_includes diff, '+ brand new'
    end

    it 'colors the diff through our theme, not git' do
      write('tracked.txt', "l1\nCHANGED\nl3\n")
      watcher.poll_once
      plain = Tuile::StyledString::Style.new
      assert diff_view.text.spans.any? { |span| span.style != plain },
             'expected at least one themed span (the header tone)'
    end
  end

  describe 'change detection' do
    it 'does not re-render when nothing changed' do
      write('tracked.txt', "l1\nCHANGED\nl3\n")
      assert watcher.poll_once, 'first poll should render the change'
      refute watcher.poll_once, 'an identical state should be skipped'
    end

    it 're-renders after a further change' do
      write('tracked.txt', "l1\nCHANGED\nl3\n")
      assert watcher.poll_once
      write('tracked.txt', "l1\nCHANGED twice\nl3\n")
      assert watcher.poll_once, 'a fresh change should re-render'
      assert_includes diff, '+ CHANGED twice'
    end
  end

  it 'degrades to a logged notice in both panes when git cannot be launched' do
    bogus = described_class.new(
      summary_view: summary_view, diff_view: diff_view,
      screen: Tuile::Screen.instance, cwd: '/no/such/dir'
    )
    assert bogus.poll_once
    assert_includes summary, 'git unavailable'
    assert_includes diff, 'git unavailable'
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
