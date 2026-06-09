# frozen_string_literal: true

RSpec.describe PikuriTui::Code::GitDiffRenderer do
  let(:theme) { PikuriTui::AppTheme::DARK }

  # Plain text of the rendered output, with all ANSI parsed away — assertions
  # target structure (headers, gutters, separators), not the styling.
  def plain(diff_text, max_width: 80, **opts)
    Tuile::StyledString.parse(described_class.render(diff_text, theme: theme, max_width: max_width, **opts)).to_s
  end

  # The DiffRenderer body runs under the suite's NO_COLOR by default, so a
  # modified line renders as the delete + add fallback unless color is forced.
  MODIFIED = <<~DIFF
    diff --git a/lib/foo.rb b/lib/foo.rb
    index 1111111..2222222 100644
    --- a/lib/foo.rb
    +++ b/lib/foo.rb
    @@ -10,3 +10,3 @@ class Foo
       def greet(name)
    -    puts "hi"
    +    puts "hello there"
    @@ -40,2 +40,3 @@ end
     last
    +tail
  DIFF

  NEW_FILE = <<~DIFF
    diff --git a/new.txt b/new.txt
    new file mode 100644
    index 0000000..3333333
    --- /dev/null
    +++ b/new.txt
    @@ -0,0 +1,2 @@
    +first
    +second
  DIFF

  describe 'empty input' do
    it 'renders nothing' do
      assert_equal '', described_class.render('', theme: theme, max_width: 80)
    end
  end

  describe 'a modified file' do
    let(:out) { plain(MODIFIED) }

    it 'renders a themed file-path header' do
      assert_includes out, '✎ lib/foo.rb'
      refute_includes out, '(new file)'
      refute_includes out, '(deleted)'
    end

    it 'separates hunks with a "@@ line N @@" marker carrying the new-side start line' do
      assert_includes out, '@@ line 10 @@'
      assert_includes out, '@@ line 40 @@'
    end

    it 'renders the unchanged hunk lines as context (two-space gutter)' do
      assert_includes out, '    def greet(name)'
      assert_includes out, '  last'
    end

    it 'falls back to a delete + add pair for the modified line under NO_COLOR' do
      assert_includes out, '-     puts "hi"'
      assert_includes out, '+     puts "hello there"'
    end

    it 'renders a pure addition with the "+ " gutter' do
      assert_includes out, '+ tail'
    end
  end

  describe 'a modified line in color' do
    # Forced color: the modified pair collapses to a single inline row on the
    # amber line tier, the changed characters picked out in the span tiers.
    let(:rendered) { described_class.render(MODIFIED, theme: theme, max_width: 80, color: true) }
    let(:mod_line) do
      rendered.split("\n").map { |l| Tuile::StyledString.parse(l) }
              .find { |ss| ss.to_s.include?('puts') }
    end

    it 'collapses the pair into one inline ~ row (no separate - / + lines)' do
      flat = Tuile::StyledString.parse(rendered).to_s
      refute_includes flat, '-     puts'
      refute_includes flat, '+     puts'
      assert mod_line.to_s.start_with?('~ '), "expected an inline ~ row, got #{mod_line.to_s.inspect}"
    end

    it 'paints the inserted characters in the green span tier' do
      # "hi" → "hello there": the inserted run is "ello there" (the "h" is
      # shared, the "i" deleted) — inline word-diff, not a contiguous "hello".
      col = mod_line.to_s.index('ello there')
      assert_equal theme[:diff_span_add], mod_line.slice(col, 1).spans.first.style.bg
    end

    it 'tints the unchanged part of the line in the amber modified line tier' do
      col = mod_line.to_s.index('puts')
      assert_equal theme[:diff_line_mod], mod_line.slice(col, 1).spans.first.style.bg
    end
  end

  describe 'a new (untracked / added) file' do
    let(:out) { plain(NEW_FILE) }

    it 'marks the header as a new file' do
      assert_includes out, '✎ new.txt (new file)'
    end

    it 'renders every line as an addition' do
      assert_includes out, '+ first'
      assert_includes out, '+ second'
    end
  end

  describe 'a deleted file' do
    it 'marks the header as deleted and renders the lines as removals' do
      diff = <<~DIFF
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index 4444444..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -one
        -two
      DIFF
      out = plain(diff)
      assert_includes out, '✎ gone.txt (deleted)'
      assert_includes out, '- one'
      assert_includes out, '- two'
    end
  end

  describe 'a binary file' do
    it 'renders a header and a "(binary)" note instead of hunks' do
      diff = <<~DIFF
        diff --git a/logo.png b/logo.png
        index 5555555..6666666 100644
        Binary files a/logo.png and b/logo.png differ
      DIFF
      out = plain(diff)
      assert_includes out, '✎ logo.png'
      assert_includes out, '(binary)'
    end
  end

  describe 'several files' do
    it 'renders each file section, blank-line separated' do
      out = plain("#{MODIFIED}#{NEW_FILE}")
      assert_includes out, '✎ lib/foo.rb'
      assert_includes out, '✎ new.txt (new file)'
    end
  end

  describe 'line-bar width' do
    # Bars pad to the longest content line (so they read as solid) but never
    # past max_width, which TextView would word-wrap. A line longer than the
    # cap drives the width up; shorter lines then pad to exactly the cap.
    it 'caps the padded bar width at max_width' do
      diff = "diff --git a/w.txt b/w.txt\n--- /dev/null\n+++ b/w.txt\n@@ -0,0 +1,2 @@\n+short\n+#{'x' * 200}\n"
      rendered = described_class.render(diff, theme: theme, max_width: 30, color: true)
      short = rendered.split("\n").map { |l| Tuile::StyledString.parse(l) }.find { |ss| ss.to_s.include?('short') }
      assert_equal 30, short.display_width
    end
  end
end
