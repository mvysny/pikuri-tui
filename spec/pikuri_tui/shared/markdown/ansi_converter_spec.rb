# frozen_string_literal: true

RSpec.describe Shared::Markdown::AnsiConverter do
  let(:width) { 60 }

  # The suite runs with NO_COLOR=1 (see spec_helper.rb); this spec is
  # about styling, so each example re-enables color for its render.
  def render(src)
    ENV.delete('NO_COLOR')
    Shared::Markdown::Renderer.render(src, width: width)
  ensure
    ENV['NO_COLOR'] = '1'
  end

  context 'inline styles' do
    it 'renders strong as bold yellow' do
      assert_includes render('**hi**'), "\e[33;1mhi\e[0m"
    end

    it 'renders emphasis as italic yellow' do
      assert_includes render('*hi*'), "\e[33;3mhi\e[0m"
    end

    it 'renders inline code in yellow' do
      assert_includes render('`hi`'), "\e[33mhi\e[0m"
    end

    it 'renders links as text » underlined-yellow href' do
      out = render('[docs](https://example.com)')
      assert_includes out, "docs » \e[33;4mhttps://example.com\e[0m"
    end

    it 'renders a bare URL as the underlined href alone' do
      out = render('<https://example.com>')
      assert_includes out, "\e[33;4mhttps://example.com\e[0m"
      refute_includes out, '»'
    end

    it 'fakes strikethrough with combining overlays, not SGR 9' do
      out = render('~~gone~~')
      assert_includes out, "g̶o̶n̶e̶"
      refute_includes out, "\e[9m"
    end

    it 're-asserts the outer style after a nested span resets' do
      # "**bold `code` tail**" — the codespan's closing reset must not
      # strip bold from " tail".
      out = render('**bold `code` tail**')
      assert_includes out, "\e[0m\e[33;1m tail"
    end
  end

  context 'headers' do
    it 'renders H1 as bold cyan underlined' do
      assert_includes render('# Title'), "\e[36;1m\e[4mTitle\e[0m"
    end

    it 'renders H2 as bold cyan without underline' do
      assert_includes render('## Title'), "\e[36;1mTitle\e[0m"
    end
  end

  context 'wrapping' do
    it 're-asserts an open style at the start of every continuation line' do
      out = render("**#{'word ' * 30}end**")
      lines = out.split("\n")
      assert lines.size > 1, 'expected the bold paragraph to wrap'
      lines.each do |line|
        assert line.start_with?("\e[33;1m"), "continuation lost bold: #{line.inspect}"
      end
    end

    it 'gives an overlong word its own line instead of splitting it' do
      long = 'x' * 100
      lines = render("start #{long} end").split("\n")
      assert_includes lines, long
    end
  end

  context 'code blocks' do
    it 'syntax-highlights a tagged fence via rouge' do
      out = render("```ruby\ndef hi\n  :hi\nend\n```")
      assert_includes out, "\e[38;5;", 'expected rouge 256-color output'
      assert_includes Shared::Markdown::Renderer.render("```ruby\ndef hi\nend\n```", width: width), 'def'
    end

    it 'renders an untagged fence in plain code yellow' do
      out = render("```\nplain code\n```")
      assert_includes out, "\e[33mplain code\e[0m"
    end

    it 'highlights with the dark-tuned rouge default by default' do
      # ThankfulEyes base (unhighlighted) text is 256-color 230, near-white.
      assert_includes render("```ruby\ndef hi\n  :hi\nend\n```"), "\e[38;5;230m"
    end

    it 'highlights with a light-legible code theme when dark: false' do
      ENV.delete('NO_COLOR')
      out = Shared::Markdown::Renderer.render("```ruby\ndef hi\n  :hi\nend\n```", width: width, dark: false)
      # github.light base text is 256-color 235, near-black — legible on light;
      # the dark default's near-white 230 must be gone.
      assert_includes out, "\e[38;5;235m"
      refute_includes out, "\e[38;5;230m"
    ensure
      ENV['NO_COLOR'] = '1'
    end
  end

  context 'tables' do
    it 'honors column alignment' do
      out = render("| l | r |\n|:--|--:|\n| a | b |\n| longer | longer |")
      stripped = out.gsub(/\e\[[0-9;]*m/, '')
      assert_includes stripped, '│ a      │      b │'
    end

    it 'shrinks columns to fit the render width' do
      cell = 'w' * 100
      out = render("| a | b |\n|---|---|\n| #{cell} | #{cell} |")
      out.split("\n").each do |line|
        plain = line.gsub(/\e\[[0-9;]*m/, '')
        assert plain.length <= width, "table line over width: #{plain.length}"
      end
    end

    it 'renders a zero-column table (lone "|", streaming prefix) without hanging' do
      # GFM parses a lone pipe — the first streamed byte of a table —
      # into a tr with no cells. [].max is nil and (0...nil) is an
      # endless range, so an unguarded row height looped (and allocated)
      # forever, taking the UI thread with it. Regression: must
      # terminate and emit only the empty border box.
      out = render('|')
      assert_equal "┌┐\n└┘", out.gsub(/\e\[[0-9;]*m/, '').strip
    end
  end

  context 'Tuile::StyledString compatibility' do
    # The thinking-pane path round-trips rendered output through
    # Shared::Markdown::Grayscale.recolor, which parses with Tuile::StyledString —
    # strict about its SGR alphabet. Every line the converter emits
    # must stay inside it.
    it 'emits only SGR codes StyledString can parse, on every line' do
      kitchen_sink = <<~MD
        # Title

        Para with **bold**, *em*, `code`, [link](https://x.y), ~~strike~~.

        ## Section

        * one

        * two wraps when the text gets long enough to spill over the line

        1. first
        2. second

        ```ruby
        def hi = :hi
        ```

        > quote

        | a | b |
        |:--|--:|
        | 1 | 2 |

        ---

        Done.
      MD
      render(kitchen_sink).split("\n").each do |line|
        Tuile::StyledString.parse(line)
      rescue Tuile::StyledString::ParseError => e
        flunk "unparseable line #{line.inspect}: #{e.message}"
      end
    end
  end

  context 'NO_COLOR' do
    it 'emits no escapes at all when color is disabled' do
      src = "# T\n\n**b** *i* `c` [l](http://x.y)\n\n```ruby\n:hi\n```"
      out = Shared::Markdown::Renderer.render(src, width: width)
      refute_match(/\e\[/, out)
    end
  end

  context 'degradation' do
    it 'renders HTML comments as nothing' do
      out = render("before\n\n<!-- note to self -->\n\nafter")
      refute_includes out, 'note to self'
      assert_includes out, 'before'
      assert_includes out, 'after'
    end

    it 'renders children of unknown HTML elements and collects a warning' do
      out = render('a <blink>b</blink> c')
      assert_includes out, 'a b c'
    end
  end
end
