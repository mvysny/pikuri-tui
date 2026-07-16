# frozen_string_literal: true

RSpec.describe Code::GitDiffTextView do
  let(:view) { described_class.new }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  def rendered = view.text.to_s

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
    view.diff = ''
    assert_includes rendered, described_class::PLACEHOLDER
  end

  it 'renders the two-tier inline form via GitDiffRenderer' do
    view.diff = MODIFIED_DIFF
    assert_includes rendered, '✎ tracked.txt'
    assert_includes rendered, '@@ line 1 @@'
    assert_includes rendered, '- l2'
    assert_includes rendered, '+ CHANGED'
  end

  it 'colors the diff through our theme, not git' do
    view.diff = MODIFIED_DIFF
    plain = Tuile::StyledString::Style.new
    assert view.text.spans.any? { |span| span.style != plain },
           'expected at least one themed span (the header tone)'
  end

  it 'stays alive (does not raise) on text GitDiffRenderer cannot parse' do
    view.diff = 'this is not a diff at all'
    assert_kind_of String, rendered # rendered to *something*, no teardown
  end

  it 'shows a one-line notice for a degraded state, surviving a resize' do
    view.notice = 'git unavailable: boom'
    assert_includes rendered, 'git unavailable: boom'
    view.rect = Tuile::Rect.new(0, 0, 40, 10)
    assert_includes rendered, 'git unavailable: boom'
  end

  # The inline bars pad to the pane width, but the padding is a *background*
  # style that NO_COLOR (the suite's mode) strips — so the width effect is
  # invisible in .to_s here. We assert the observable contract instead: the
  # width the render uses tracks the pane, and a resize actually re-renders.
  describe 'width-responsive re-render on resize' do
    it 'derives the diff-bar width from the pane width (less the gutter)' do
      view.rect = Tuile::Rect.new(0, 0, 50, 10)
      assert_equal 48, view.send(:max_width)
    end

    it 're-renders the retained diff when the pane width changes (on_width_changed)' do
      view.diff = MODIFIED_DIFF
      writes = 0
      original = view.method(:text=)
      view.define_singleton_method(:text=) do |value|
        writes += 1
        original.call(value)
      end

      view.rect = Tuile::Rect.new(0, 0, 40, 10) # width 0 -> 40 fires on_width_changed
      assert writes.positive?, 'a width change should re-render the retained diff'
      assert_includes rendered, '✎ tracked.txt' # …and not blank it
    end
  end
end
