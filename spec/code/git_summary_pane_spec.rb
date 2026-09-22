# frozen_string_literal: true

RSpec.describe Code::GitSummaryPane do
  let(:pane)  { described_class.new }
  let(:theme) { Tuile::Screen.instance.theme }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  # The pane renders in its own relayout, so a read settles first.
  def view_text
    pane.flush_layout
    pane.view.text
  end

  def rendered = view_text.to_s
  def rows = rendered.lines.map(&:chomp)
  def caption = caption_text.to_s

  def caption_text
    pane.flush_layout
    pane.caption_label.caption
  end

  # Gives the pane a real width, so the width-dependent eliding runs.
  def size!(width = 24) = Tuile::Testing.place(pane, Tuile::Rect.new(0, 0, width, 12))

  it 'displays and nothing more: Tab never parks focus on the sidebar' do
    assert_kind_of Shared::PassiveTextView, pane.view
    refute_predicate pane.view, :tab_stop?
    refute_predicate pane.view, :focusable?
  end

  it 'stands up as a borderless "Changes" caption row over a text view' do
    assert_kind_of Shared::PaneCaptionLabel, pane.caption_label
    assert_equal pane.caption_label, pane.children.first
    assert_equal described_class::CAPTION, caption
  end

  def change(code, path, added, deleted)
    Code::GitWatcher::Change.new(code: code, path: path, added: added, deleted: deleted)
  end

  def snapshot(changes: [], error: nil)
    Code::GitWatcher::Snapshot.new(changes: changes, diff_text: '', error: error)
  end

  # The porcelain code is the span carrying the change-kind tone; the filename
  # beside it is deliberately left in the default foreground.
  def code_color(code)
    view_text.spans.find { |span| span.text.strip == code.strip && span.style.fg }&.style&.fg
  end

  def span_containing(substr)
    view_text.spans.find { |span| span.text.include?(substr) }
  end

  # Header rows as they stand, file rows reduced to their basename.
  def row_names = rows.map { |row| row.end_with?('/') ? row : row.strip.split(/\s+/)[1] }

  it 'shows a placeholder when there are no changes' do
    pane.snapshot = snapshot(changes: [])
    assert_includes rendered, described_class::PLACEHOLDER
    assert_equal described_class::CAPTION, caption
  end

  it 'shows a one-line notice for a degraded (error) snapshot' do
    pane.snapshot = snapshot(error: 'git unavailable: boom')
    assert_includes rendered, 'git unavailable: boom'
    assert_equal described_class::CAPTION, caption
  end

  describe 'grouping by directory' do
    it 'heads each directory once and indents its files under it' do
      pane.snapshot = snapshot(changes: [change(' M', 'lib/code/app.rb', 2, 1),
                                         change(' M', 'lib/code/layout.rb', 4, 0),
                                         change(' M', 'spec/code/app_spec.rb', 6, 0)])
      assert_equal ['lib/code/', 'app.rb', 'layout.rb', 'spec/code/', 'app_spec.rb'], row_names
      assert_equal 5, rows.size
    end

    it 'inserts a header where dirname changes, preserving git\'s own order' do
      # Not group_by: a re-bucketing would pull the second lib/ file up beside
      # the first, moving rows out from under the reader.
      pane.snapshot = snapshot(changes: [change(' M', 'lib/a.rb', 1, 0),
                                         change(' M', 'spec/b.rb', 1, 0),
                                         change(' M', 'lib/c.rb', 1, 0)])
      assert_equal ['lib/', 'a.rb', 'spec/', 'b.rb', 'lib/', 'c.rb'], row_names
    end

    it 'heads repo-root files with ./ so a run cannot be misread' do
      pane.snapshot = snapshot(changes: [change(' M', 'AGENTS.md', 3, 1)])
      assert_equal described_class::ROOT_GROUP, rows.first
      assert_includes rows[1], 'AGENTS.md'
    end

    it 'elides a deep directory header from the left, keeping its own name' do
      size!
      pane.snapshot = snapshot(changes: [change(' M', 'lib/shared/markdown/deeply/nested/x.rb', 1, 0)])
      assert rows.first.start_with?('…'), "expected a leading ellipsis, got #{rows.first.inspect}"
      assert rows.first.end_with?('nested/'), "expected the tail kept, got #{rows.first.inspect}"
      assert_equal 24, rows.first.length
    end
  end

  describe 'the counts column' do
    it 'renders +A/-D with a slash binding them' do
      pane.snapshot = snapshot(changes: [change(' M', 'a.rb', 31, 8)])
      assert_includes rendered, '+31/-8'
    end

    it 'omits a zero side (an untracked file shows only additions)' do
      pane.snapshot = snapshot(changes: [change('??', 'fresh.txt', 3, 0)])
      assert rows.last.end_with?('+3'), "expected only additions, got #{rows.last.inspect}"
      refute_includes rows.last, '-'
    end

    it 'reserves the snapshot\'s widest counts, so every file row is one width' do
      size!
      pane.snapshot = snapshot(changes: [change(' M', 'lib/a.rb', 2, 1),
                                         change(' M', 'lib/b.rb', 184, 17)])
      file_rows = rows.reject { |row| row.end_with?('/') }
      assert_equal 2, file_rows.size
      assert_equal [24, 24], file_rows.map(&:length)
      assert file_rows.all? { |row| row.end_with?('1', '7') }, "counts not right-aligned: #{file_rows.inspect}"
    end

    it 'tones additions green, deletions red and the slash dim' do
      pane.snapshot = snapshot(changes: [change(' M', 'a.rb', 2, 1)])
      assert_equal theme[:added], span_containing('+2').style.fg
      assert_equal theme[:removed], span_containing('-1').style.fg
      assert_equal theme[:detail], span_containing('/').style.fg
    end
  end

  describe 'kind tone rides the porcelain code, not the filename' do
    it 'tones new files green' do
      pane.snapshot = snapshot(changes: [change('??', 'fresh.txt', 1, 0)])
      assert_equal theme[:added], code_color('??')
    end

    it 'tones deleted files red' do
      pane.snapshot = snapshot(changes: [change(' D', 'gone.txt', 0, 4)])
      assert_equal theme[:removed], code_color('D')
    end

    it 'tones modified files yellow' do
      pane.snapshot = snapshot(changes: [change(' M', 'tracked.txt', 1, 1)])
      assert_equal theme[:notice], code_color('M')
    end

    it 'leaves the filename in the default foreground' do
      pane.snapshot = snapshot(changes: [change(' M', 'tracked.txt', 1, 1)])
      assert_nil span_containing('tracked.txt').style.fg
    end

    it 'right-justifies a one-letter code into the two porcelain columns' do
      pane.snapshot = snapshot(changes: [change('M', 'a.rb', 1, 0)])
      assert_includes rendered, '  M a.rb'
    end
  end

  describe 'the caption tally' do
    it 'carries the file count and the whole-tree totals' do
      size!
      pane.snapshot = snapshot(changes: [change(' M', 'a.rb', 100, 10),
                                         change(' M', 'b.rb', 84, 7)])
      assert_equal 'Changes: 2; +184/-17', caption
    end

    it 'drops the file count before the totals when the pane narrows' do
      size!(18)
      pane.snapshot = snapshot(changes: [change(' M', 'a.rb', 100, 10),
                                         change(' M', 'b.rb', 84, 7)])
      assert_equal 'Changes +184/-17', caption
    end

    it 'falls back to the bare caption when even the totals will not fit' do
      size!(10)
      pane.snapshot = snapshot(changes: [change(' M', 'a.rb', 1000, 1000)])
      assert_equal described_class::CAPTION, caption
    end

    it 'tones the totals like the per-file counts under them, prose left plain' do
      size!
      pane.snapshot = snapshot(changes: [change(' M', 'a.rb', 100, 10),
                                         change(' M', 'b.rb', 84, 7)])
      toned = caption_text.spans.to_h { |span| [span.text, span.style.fg] }
      assert_equal theme[:added], toned['+184']
      assert_equal theme[:removed], toned['-17']
      assert_nil toned['Changes: 2; '], 'prose must stay unset so the caption accent fills it'
    end

    it 'drops the totals rather than trailing an empty tally when nothing changed lines' do
      size!
      pane.snapshot = snapshot(changes: [change('R ', 'a.rb', 0, 0)])
      assert_equal 'Changes: 1', caption
    end
  end

  describe 'width awareness' do
    it 'elides a long filename from the right, keeping its head' do
      size!
      pane.snapshot = snapshot(changes: [change(' M', 'lib/code/task_list_pane.rb', 31, 8)])
      file_row = rows.last
      assert_equal 24, file_row.length
      assert_includes file_row, 'task_list_pa…'
      assert file_row.end_with?('+31/-8')
    end

    it 're-renders at the new width on resize' do
      size!(40)
      pane.snapshot = snapshot(changes: [change(' M', 'lib/code/task_list_pane.rb', 31, 8)])
      assert_includes rows.last, 'task_list_pane.rb'
      size!(24)
      assert_includes rows.last, 'task_list_pa…'
    end

    it 'elides nothing while the pane has no width yet' do
      pane.snapshot = snapshot(changes: [change(' M', 'lib/code/task_list_pane.rb', 31, 8)])
      assert_includes rendered, 'task_list_pane.rb'
    end
  end
end
