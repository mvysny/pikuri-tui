# frozen_string_literal: true

RSpec.describe Code::GitSummaryWindow do
  let(:pane)  { described_class.new }
  let(:theme) { Tuile::Screen.instance.theme }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  def rendered = pane.view.text.to_s

  def change(code, path, added, deleted)
    Code::GitWatcher::Change.new(code: code, path: path, added: added, deleted: deleted)
  end

  def snapshot(changes: [], error: nil)
    Code::GitWatcher::Snapshot.new(changes: changes, diff_text: '', error: error)
  end

  # The label "XY path" is one styled span (uniform color); the +/- markers are
  # separate spans. Find the span carrying the path.
  def label_color(substr)
    pane.view.text.spans.find { |span| span.text.include?(substr) }&.style&.fg
  end

  it 'shows a placeholder when there are no changes' do
    pane.snapshot = snapshot(changes: [])
    assert_includes rendered, described_class::PLACEHOLDER
  end

  it 'renders one line per change with its code, path and counts' do
    pane.snapshot = snapshot(changes: [change('M', 'tracked.txt', 2, 1), change('??', 'fresh.txt', 3, 0)])
    assert_includes rendered, 'M tracked.txt'
    assert_includes rendered, '+2'
    assert_includes rendered, '-1'
    assert_includes rendered, '?? fresh.txt'
    assert_includes rendered, '+3'
    assert_equal 2, rendered.lines.size
  end

  it 'omits a zero marker (an untracked file shows only additions)' do
    pane.snapshot = snapshot(changes: [change('??', 'fresh.txt', 3, 0)])
    assert_includes rendered, '+3'
    refute_includes rendered, '-0'
  end

  describe 'label tone by change kind' do
    it 'tones new files green' do
      pane.snapshot = snapshot(changes: [change('??', 'fresh.txt', 1, 0)])
      assert_equal theme[:added], label_color('fresh.txt')
    end

    it 'tones deleted files red' do
      pane.snapshot = snapshot(changes: [change(' D', 'gone.txt', 0, 4)])
      assert_equal theme[:removed], label_color('gone.txt')
    end

    it 'tones modified files yellow' do
      pane.snapshot = snapshot(changes: [change(' M', 'tracked.txt', 1, 1)])
      assert_equal theme[:notice], label_color('tracked.txt')
    end
  end

  it 'shows a one-line notice for a degraded (error) snapshot' do
    pane.snapshot = snapshot(error: 'git unavailable: boom')
    assert_includes rendered, 'git unavailable: boom'
  end
end
