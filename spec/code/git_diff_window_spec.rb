# frozen_string_literal: true

RSpec.describe Code::GitDiffWindow do
  let(:pane) { described_class.new }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  def rendered = pane.view.text.to_s

  def snapshot(diff: '', error: nil)
    Code::GitWatcher::Snapshot.new(changes: [], diff_text: diff, error: error)
  end

  # A real (small) plain unified diff, as `git diff` would emit it.
  MODIFIED_DIFF = <<~DIFF
    diff --git a/tracked.txt b/tracked.txt
    index 1111111..2222222 100644
    --- a/tracked.txt
    +++ b/tracked.txt
    @@ -1,3 +1,3 @@
     l1
    -l2
    +CHANGED
     l3
  DIFF

  it 'shows a placeholder for an empty diff' do
    pane.snapshot = snapshot(diff: '')
    assert_includes rendered, described_class::PLACEHOLDER
  end

  it 'renders the two-tier inline form via GitDiffRenderer' do
    pane.snapshot = snapshot(diff: MODIFIED_DIFF)
    assert_includes rendered, '✎ tracked.txt'
    assert_includes rendered, '@@ line 1 @@'
    assert_includes rendered, '- l2'
    assert_includes rendered, '+ CHANGED'
  end

  it 'colors the diff through our theme, not git' do
    pane.snapshot = snapshot(diff: MODIFIED_DIFF)
    plain = Tuile::StyledString::Style.new
    assert pane.view.text.spans.any? { |span| span.style != plain },
           'expected at least one themed span (the header tone)'
  end

  it 'stays alive (does not raise) on text GitDiffRenderer cannot parse' do
    pane.snapshot = snapshot(diff: 'this is not a diff at all')
    assert_kind_of String, rendered # rendered to *something*, no teardown
  end

  it 'shows a one-line notice for a degraded (error) snapshot, surviving a resize' do
    pane.snapshot = snapshot(error: 'git unavailable: boom')
    assert_includes rendered, 'git unavailable: boom'
    pane.rect = Tuile::Rect.new(0, 0, 40, 10)
    assert_includes rendered, 'git unavailable: boom'
  end

  # The inline bars pad to the pane width, but the padding is a *background*
  # style that NO_COLOR (the suite's mode) strips - so the width effect is
  # invisible in .to_s here. We assert the observable contract instead: the
  # width the render uses tracks the pane, and a resize actually re-renders.
  describe 'width-responsive re-render on resize' do
    it 'derives the diff-bar width from the window width (less border + gutter)' do
      pane.rect = Tuile::Rect.new(0, 0, 50, 10)
      assert_equal 47, pane.send(:max_width)
    end

    it 're-renders the retained diff when the pane width changes (handle_width_changed)' do
      pane.snapshot = snapshot(diff: MODIFIED_DIFF)
      writes = 0
      view = pane.view
      original = view.method(:text=)
      view.define_singleton_method(:text=) do |value|
        writes += 1
        original.call(value)
      end

      pane.rect = Tuile::Rect.new(0, 0, 40, 10) # width 0 -> 40 fires handle_width_changed
      assert writes.positive?, 'a width change should re-render the retained diff'
      assert_includes rendered, '✎ tracked.txt' # …and not blank it
    end
  end
end
