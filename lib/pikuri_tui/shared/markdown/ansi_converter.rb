# frozen_string_literal: true

require 'kramdown/converter'
require 'rouge'
require 'unicode/display_width'

# Renders a kramdown parse tree to ANSI for the conversation pane.
#
# This is the in-house replacement for +tty-markdown+'s converter —
# same architectural shape (a +Kramdown::Converter::Base+ subclass
# walking the parse tree, emitting SGR-styled terminal text), scoped
# down to the element set LLM chat output actually produces, and
# owning two behaviors tty-markdown got wrong:
#
# - *Loose lists render loose.* A blank line between list items in
#   the source produces a blank line between rendered items (the
#   list-level looseness rule, as in CommonMark). tty-markdown
#   collapsed loose and tight lists into the same output, which
#   {Shared::Markdown::Renderer} used to patch around with an HTML-comment
#   injection hack — bullets only, because splitting ordered lists
#   broke their numbering. Rendering the list ourselves makes both
#   problems disappear: looseness is read off the parse tree
#   (kramdown marks tight items' paragraphs +:transparent+) and
#   numbering comes from the item index.
# - *Paragraphs wrap as a whole.* Inline styling spans (bold, code,
#   links) flow with the surrounding text; tty-markdown wrapped each
#   text fragment independently, mis-measuring every line that
#   contained inline markup.
#
# == Output contract
#
# The produced ANSI sticks to the SGR alphabet
# {Tuile::StyledString.parse} models — colors (16-color, 256-color,
# RGB), bold, italic, underline — because the thinking-pane path
# round-trips rendered output through {Shared::Markdown::Grayscale.recolor}.
# Don't emit dim/reverse/strike SGR codes here; for strikethrough
# the combining long-stroke-overlay character is used instead.
# Styling is re-asserted at every wrapped-line start so each
# physical line is independently parseable.
#
# Honors +NO_COLOR+ (and a +color: false+ converter option): all
# styling and syntax highlighting degrade to plain text. The spec
# suite relies on this to assert structure without ANSI noise.
#
# == Use via Shared::Markdown::Renderer
#
# Callers don't touch this class directly — {Shared::Markdown::Renderer.render}
# parses the source with kramdown (GFM dialect) and invokes
# {.convert} the way tty-markdown's own entry point did:
#
#   doc = Kramdown::Document.new(src, input: 'GFM', width: 80, ...)
#   ansi, warnings = Shared::Markdown::AnsiConverter.convert(doc.root, doc.options)
#
# Unsupported element types degrade: a warning is collected (the
# caller logs them) and the children are rendered as-is, so novel
# markdown never tears down the render path with a raise.
class Shared::Markdown::AnsiConverter < Kramdown::Converter::Base
  NEWLINE = "\n"
  private_constant :NEWLINE

  SPACE = ' '
  private_constant :SPACE

  # Full SGR reset. The only reset form this converter emits, and the
  # only one {#wrap} needs to understand when tracking active styles.
  RESET = "\e[0m"
  private_constant :RESET

  # SGR prefixes per element kind. The palette follows tty-markdown's
  # default theme (yellow accents, cyan headers) so the swap doesn't
  # change the conversation pane's look, with one upgrade: emphasis
  # carries the italic attribute (and strong carries bold) in addition
  # to the color, so {Shared::Markdown::Grayscale} keeps the structure visible after
  # flattening colors away.
  STYLES = {
    header: "\e[36;1m",
    em: "\e[33;3m",
    strong: "\e[33;1m",
    code: "\e[33m",
    link: "\e[33;4m",
    marker: "\e[33m",
    quote: "\e[33m",
    table: "\e[33m",
    hr: "\e[33m",
    image: "\e[90m"
  }.freeze
  private_constant :STYLES

  # Added on top of +STYLES[:header]+ for level-1 headers.
  UNDERLINE = "\e[4m"
  private_constant :UNDERLINE

  BULLET = '●'
  private_constant :BULLET

  QUOTE_BAR = '┃'
  private_constant :QUOTE_BAR

  # Blockquote prefix is the bar plus two spaces — display width 3.
  QUOTE_PREFIX_WIDTH = 3
  private_constant :QUOTE_PREFIX_WIDTH

  HR_END = '◈'
  private_constant :HR_END

  LINE = '─'
  private_constant :LINE

  PIPE = '│'
  private_constant :PIPE

  # Combining long stroke overlay; suffixed per character to fake
  # strikethrough without the SGR strike code (9), which
  # {Tuile::StyledString} doesn't model.
  STRIKE_OVERLAY = "\u0336"
  private_constant :STRIKE_OVERLAY

  SMART_QUOTES = { lsquo: '‘', rsquo: '’', ldquo: '“', rdquo: '”' }.freeze
  private_constant :SMART_QUOTES

  TYPOGRAPHIC_SYMS = {
    mdash: '—', ndash: '–', hellip: '…',
    laquo: '«', raquo: '»', laquo_space: '« ', raquo_space: ' »'
  }.freeze
  private_constant :TYPOGRAPHIC_SYMS

  ANSI_RE = /\e\[[0-9;]*m/
  private_constant :ANSI_RE

  # Rouge code-highlighting theme for light terminal backgrounds. The
  # +Terminal256+ formatter's default theme (+ThankfulEyes+, used on
  # dark) renders its base — i.e. unhighlighted — code text in a
  # near-white 256-color (+#ffffd7+) that all but vanishes on a light
  # background; +github.light+ renders dark-on-light, so plain code
  # stays legible. Picked in {#highlight} by the +dark:+ converter
  # option ({#initialize}). Built once (a Rouge theme is immutable and
  # the formatter only reads it).
  LIGHT_CODE_THEME = Rouge::Theme.find('github.light').new
  private_constant :LIGHT_CODE_THEME

  # Indent added per header level, mirroring tty-markdown's layout
  # convention: content under an H2 sits 2 columns deep, under an
  # H3 4 columns, and so on.
  INDENT_STEP = 2
  private_constant :INDENT_STEP

  # Wrapping floor: with deep nesting on a narrow pane the usable
  # width could reach zero; never wrap tighter than this (overlong
  # lines degrade to TextView's own soft-wrap, which preserves
  # styling).
  MIN_WRAP_WIDTH = 20
  private_constant :MIN_WRAP_WIDTH

  # @param root [Kramdown::Element] the +:root+ element.
  # @param options [Hash] kramdown document options; reads +:width+
  #   (target render width, default 80), +:color+ (+false+
  #   disables all styling; default on unless +NO_COLOR+ is set), and
  #   +:dark+ (+false+ picks {LIGHT_CODE_THEME} for code blocks;
  #   default +true+ keeps the dark-tuned +Terminal256+ default).
  def initialize(root, options)
    super
    @width = options[:width] || 80
    @color = options[:color] != false && ENV['NO_COLOR'].to_s.empty?
    @dark = options[:dark] != false
    @current_indent = 0
  end

  # Convert an element (and its subtree) to ANSI text.
  #
  # @param el [Kramdown::Element] the element to convert.
  # @param opts [Hash] traversal context (+:parent+, +:index+,
  #   +:prev+, +:next+), maintained by {#inner}.
  # @return [String] rendered ANSI. Block-level elements end with a
  #   newline; span-level elements don't.
  def convert(el, opts = { parent: nil })
    handler = :"convert_#{el.type}"
    return send(handler, el, opts) if respond_to?(handler, true)

    warning("element type #{el.type.inspect} not supported; rendering children as-is")
    inner(el, opts).join
  end

  private

  # Convert all children, threading traversal context.
  #
  # @param el [Kramdown::Element]
  # @param opts [Hash]
  # @return [Array<String>] one rendered string per child.
  def inner(el, opts)
    el.children.each_with_index.map do |child, i|
      convert(child, opts.merge(parent: el, index: i,
                                prev: i.zero? ? nil : el.children[i - 1],
                                next: el.children[i + 1]))
    end
  end

  # Children joined into one inline run (for span-level content:
  # paragraph bodies, header text, table cells, link text).
  def inline(el, opts)
    inner(el, opts).join
  end

  # --- block elements ---------------------------------------------

  def convert_root(el, opts)
    inner(el, opts).join
  end

  # Source blank lines separate blocks; a run of any length renders
  # as a single blank line (kramdown coalesces the run into one
  # +:blank+ element, and we ignore its length).
  def convert_blank(_el, _opts)
    NEWLINE
  end

  def convert_p(el, opts)
    block(inline(el, opts))
  end

  def convert_header(el, opts)
    level = el.options[:level]
    # Top-level headers set the indent for everything that follows —
    # tty-markdown's signature layout, kept for visual continuity.
    @current_indent = (level - 1) * INDENT_STEP if opts[:parent]&.type == :root
    style = level == 1 ? STYLES[:header] + UNDERLINE : STYLES[:header]
    block(inline(el, opts), style: style)
  end

  def convert_codeblock(el, opts)
    indent = SPACE * @current_indent
    highlight(el.value.chomp, el.options[:lang]).map { |line| indent + line + NEWLINE }.join
  end

  def convert_blockquote(el, opts)
    outer = SPACE * @current_indent
    inner_indent = @current_indent + QUOTE_PREFIX_WIDTH
    @current_indent = inner_indent
    body = inner(el, opts).join
    @current_indent = inner_indent - QUOTE_PREFIX_WIDTH

    bar = styled(STYLES[:quote], QUOTE_BAR)
    body.lines.map do |line|
      content = line.chomp
      if content.start_with?(outer + (SPACE * QUOTE_PREFIX_WIDTH))
        outer + bar + SPACE + SPACE + content[inner_indent..]
      else
        # Blank line inside the quote — bar only, no trailing spaces.
        outer + bar
      end + NEWLINE
    end.join
  end

  # Loose lists (any item's paragraph not marked +:transparent+, i.e.
  # a blank line somewhere between items in the source) get a blank
  # line between every pair of items — the CommonMark list-level
  # looseness rule. Tight lists render compact.
  def convert_ul(el, opts)
    loose = el.children.any? do |li|
      li.children.any? { |c| c.type == :p && !c.options[:transparent] }
    end
    inner(el, opts).join(loose ? NEWLINE : '')
  end
  alias_method :convert_ol, :convert_ul

  def convert_li(el, opts)
    marker = opts[:parent].type == :ol ? "#{opts[:index] + 1}." : BULLET
    hang = display_width(marker) + 1
    @current_indent += hang
    body = inner(el, opts).join
    @current_indent -= hang
    # Swap the first line's hanging indent for the styled marker;
    # continuation lines and nested blocks keep the full indent and
    # so align under the item text.
    body.sub(/\A {#{@current_indent + hang}}/) do
      (SPACE * @current_indent) + styled(STYLES[:marker], marker) + SPACE
    end
  end

  def convert_dt(el, opts)
    block(inline(el, opts), style: STYLES[:strong])
  end

  def convert_dd(el, opts)
    @current_indent += INDENT_STEP
    body = inner(el, opts).join
    @current_indent -= INDENT_STEP
    body
  end

  def convert_hr(_el, _opts)
    width = [@width - (display_width(HR_END) * 2), 1].max
    styled(STYLES[:hr], HR_END + (LINE * width) + HR_END) + NEWLINE
  end

  def convert_table(el, opts)
    alignment = el.options[:alignment] || []
    rows = el.children.flat_map(&:children)
    data = rows.map { |tr| tr.children.map { |td| inline(td, opts.merge(parent: td)) } }
    widths = distribute_widths(max_widths(data))
    indent = SPACE * @current_indent

    out = +''
    out << indent << table_border(widths, '┌', '┬', '┐') << NEWLINE
    data.each_with_index do |cells, i|
      out << indent << table_border(widths, '├', '┼', '┤') << NEWLINE if i.positive?
      out << table_row(cells, widths, alignment)
    end
    out << indent << table_border(widths, '└', '┴', '┘') << NEWLINE
  end

  def convert_math(el, opts)
    if el.options[:category] == :block
      convert_codeblock(el, opts)
    else
      styled(STYLES[:code], el.value)
    end
  end

  def convert_raw(_el, _opts)
    warning('raw content is not supported')
    ''
  end

  # HTML comments render as nothing — they carry no reader-visible
  # content. (tty-markdown rendered them as gray "# …" lines, which
  # leaked annotation noise into the conversation pane.)
  def convert_xml_comment(_el, _opts)
    ''
  end
  alias_method :convert_comment, :convert_xml_comment

  # --- span elements ----------------------------------------------

  # Soft line breaks inside a paragraph become spaces (CommonMark
  # semantics); {#wrap} then re-flows the text. Hard breaks arrive
  # as +:br+ elements and survive as newlines.
  def convert_text(el, _opts)
    el.value.tr("\n", SPACE)
  end

  def convert_br(_el, _opts)
    NEWLINE
  end

  def convert_em(el, opts)
    styled(STYLES[:em], inline(el, opts))
  end

  def convert_strong(el, opts)
    styled(STYLES[:strong], inline(el, opts))
  end

  def convert_codespan(el, _opts)
    styled(STYLES[:code], el.value)
  end

  def convert_a(el, opts)
    href = el.attr['href'].to_s
    text = inline(el, opts)
    return styled(STYLES[:link], href) if strip_ansi(text) == href || strip_ansi(text).empty?

    "#{text} » #{styled(STYLES[:link], href)}"
  end

  def convert_img(el, _opts)
    alt = el.attr['alt'].to_s
    src = el.attr['src'].to_s
    label = alt.empty? ? src : "#{alt} – #{src}"
    styled(STYLES[:image], "(#{label})")
  end

  def convert_footnote(el, _opts)
    styled(STYLES[:marker], "[^#{el.options[:name]}]")
  end

  def convert_smart_quote(el, _opts)
    SMART_QUOTES.fetch(el.value) { el.value.to_s }
  end

  def convert_typographic_sym(el, _opts)
    TYPOGRAPHIC_SYMS.fetch(el.value) { el.value.to_s }
  end

  def convert_entity(el, _opts)
    [el.value.code_point].pack('U')
  end

  # Span-level HTML that LLMs commonly emit, mapped to the markdown
  # equivalent; anything unrecognized degrades to its children plus
  # a warning.
  def convert_html_element(el, opts)
    case el.value
    when 'del', 's', 'strike'
      strip_ansi(inline(el, opts)).chars.map { |c| c + STRIKE_OVERLAY }.join
    when 'em', 'i' then convert_em(el, opts)
    when 'strong', 'b' then convert_strong(el, opts)
    when 'code' then styled(STYLES[:code], inline(el, opts))
    when 'br' then NEWLINE
    when 'div', 'span', 'p' then inner(el, opts).join
    else
      warning("HTML element #{el.value.inspect} not supported; rendering children as-is")
      inner(el, opts).join
    end
  end

  # --- rendering helpers ------------------------------------------

  # Wrap inline content to the current width, indent every line, and
  # terminate with a newline — the shared tail of every paragraph-like
  # block. With +style:+, each wrapped line is styled independently so
  # it stays parseable on its own.
  #
  # @param content [String] assembled inline ANSI.
  # @param style [String, nil] SGR prefix for the whole block.
  # @return [String]
  def block(content, style: nil)
    width = [@width - @current_indent, MIN_WRAP_WIDTH].max
    indent = SPACE * @current_indent
    wrap(content, width).map do |line|
      indent + (style ? styled(style, line) : line) + NEWLINE
    end.join
  end

  # Apply an SGR prefix to a span, re-asserting it after any reset the
  # content carries so nested styles (code inside bold, …) don't
  # truncate the outer span.
  #
  # @param sgr [String] SGR prefix, e.g. +"\e[33;1m"+.
  # @param text [String]
  # @return [String] +text+ unchanged when color is disabled.
  def styled(sgr, text)
    return text unless @color

    sgr + text.gsub(RESET) { RESET + sgr } + RESET
  end

  # ANSI-aware greedy word wrap. Splits on hard newlines first, then
  # re-flows each segment on spaces; escape sequences are zero-width.
  # Active styles (tracked as the SGR tokens seen since the last
  # {RESET} — the only forms {#styled} emits) are re-asserted at the
  # start of every continuation line, so each physical line renders
  # (and {Tuile::StyledString.parse}s) independently.
  #
  # Words wider than the width get a line of their own — no
  # mid-word breaking; the TextView's own soft-wrap handles the
  # overflow, styles intact. Table cells pass +break_words: true+
  # instead: there an overlong word must hard-split at the column
  # width or it would corrupt the drawn box.
  #
  # @param content [String] inline ANSI (no indentation yet).
  # @param width [Integer] maximum display width per line.
  # @param break_words [Boolean] hard-split words wider than +width+.
  # @return [Array<String>] wrapped lines.
  def wrap(content, width, break_words: false)
    content.split("\n", -1).flat_map do |segment|
      wrap_segment(segment, width, break_words: break_words)
    end
  end

  # @see #wrap
  def wrap_segment(segment, width, break_words:)
    lines = []
    line = +''
    line_width = 0
    active = []

    words = segment.split(/ +/).reject(&:empty?)
    if break_words
      words = words.flat_map do |word|
        display_width(word) > width ? hard_split(word, width) : [word]
      end
    end

    words.each do |word|
      word_width = display_width(word)
      if line_width.positive? && line_width + 1 + word_width > width
        lines << line
        line = active.join + word
        line_width = word_width
      else
        line << SPACE unless line_width.zero?
        line << word
        line_width += line_width.zero? ? word_width : 1 + word_width
      end
      word.scan(ANSI_RE).each { |esc| esc == RESET ? active.clear : active << esc }
    end

    lines << line
    lines
  end

  # Split one overlong word into pieces of at most +width+ display
  # columns, ANSI escapes carried along at zero width. Each full
  # piece exactly fills a wrapped line, so {#wrap_segment}'s normal
  # greedy flow places consecutive pieces on consecutive lines.
  #
  # @param word [String]
  # @param width [Integer]
  # @return [Array<String>]
  def hard_split(word, width)
    pieces = []
    piece = +''
    piece_width = 0
    word.scan(/\e\[[0-9;]*m|./m).each do |token|
      if token.start_with?("\e")
        piece << token
        next
      end
      token_width = display_width(token)
      if piece_width.positive? && piece_width + token_width > width
        pieces << piece
        piece = +''
        piece_width = 0
      end
      piece << token
      piece_width += token_width
    end
    pieces << piece unless piece.empty?
    pieces
  end

  # Syntax-highlight a code block via rouge. Untagged or
  # unrecognized languages render in plain code yellow (matching
  # tty-markdown's fallback); rouge blowing up degrades to
  # unstyled code plus a collected warning — never a raise on the
  # render path.
  #
  # On a light terminal ({@dark} false) the formatter is themed with
  # {LIGHT_CODE_THEME}; on dark it uses +Terminal256+'s default theme
  # (+ThankfulEyes+), whose near-white base text only reads on a dark
  # background. This is the one render path that is appearance-aware:
  # the rest of the body palette ({STYLES}) is named-ANSI and so tracks
  # the terminal's own remapping, but +Terminal256+ emits absolute
  # 256-colors that don't.
  #
  # @param code [String] code without the trailing fence newline.
  # @param lang [String, nil] the fence's language tag.
  # @return [Array<String>] styled lines, no trailing newlines.
  def highlight(code, lang)
    return code.lines.map(&:chomp) unless @color

    lexer = lang && Rouge::Lexer.find_fancy(lang, code)
    return code.lines.map { |l| styled(STYLES[:code], l.chomp) } unless lexer

    code_formatter.format(lexer.lex(code)).lines.map(&:chomp)
  rescue StandardError => e
    warning("rouge highlighting failed (#{e.class}: #{e.message}); rendering plain")
    code.lines.map(&:chomp)
  end

  # The rouge formatter for code blocks, themed for the terminal
  # background. Memoized per converter (one converter per render).
  #
  # @return [Rouge::Formatters::Terminal256]
  def code_formatter
    @code_formatter ||=
      if @dark
        Rouge::Formatters::Terminal256.new
      else
        Rouge::Formatters::Terminal256.new(LIGHT_CODE_THEME)
      end
  end

  # --- table helpers ----------------------------------------------

  # Widest cell per column, by display width.
  #
  # @param data [Array<Array<String>>] rendered cell contents.
  # @return [Array<Integer>]
  def max_widths(data)
    cols = data.map(&:size).max || 0
    (0...cols).map { |i| data.map { |row| display_width(row[i] || '') }.max }
  end

  # Shrink column widths proportionally when the drawn table (cells
  # plus borders and padding) would overflow the render width. Each
  # column keeps at least one cell column; cell content re-wraps to
  # the reduced width.
  #
  # @param widths [Array<Integer>]
  # @return [Array<Integer>]
  def distribute_widths(widths)
    total = widths.sum
    chrome = (3 * widths.size) + 1 # "│ " + " │" per cell, shared borders
    available = @width - @current_indent - chrome
    return widths if total <= available || total.zero?

    excess = total - available
    widths.map { |w| [w - ((excess * w) / total.to_f).ceil, 1].max }
  end

  # @param widths [Array<Integer>] column content widths.
  # @return [String] one styled horizontal border line.
  def table_border(widths, left, center, right)
    styled(STYLES[:table], left + widths.map { |w| LINE * (w + 2) }.join(center) + right)
  end

  # Render one table row, wrapping each cell to its column width and
  # padding every cell to the row's height.
  #
  # @param cells [Array<String>] rendered inline cell contents.
  # @param widths [Array<Integer>] column content widths.
  # @param alignment [Array<Symbol>] per-column +:default+ / +:left+
  #   / +:center+ / +:right+.
  # @return [String]
  def table_row(cells, widths, alignment)
    wrapped = widths.each_with_index.map { |w, i| wrap(cells[i] || '', w, break_words: true) }
    # A zero-column row (GFM parses a lone "|" — the first streamed
    # byte of a table — into a tr with no cells) must produce zero
    # lines: [].max is nil, and (0...nil) is an *endless* range that
    # would loop the render forever.
    height = wrapped.map(&:size).max || 0
    pipe = styled(STYLES[:table], PIPE)
    indent = SPACE * @current_indent

    (0...height).map do |row_line|
      body = wrapped.each_with_index.map do |cell, i|
        pad(cell[row_line] || '', widths[i], alignment[i] || :default)
      end.join(" #{pipe} ")
      "#{indent}#{pipe} #{body} #{pipe}#{NEWLINE}"
    end.join
  end

  # Pad a cell line to the column width, honoring the column's
  # alignment. Content already wider than the column (display-width
  # quirks) is left as-is.
  def pad(content, width, align)
    gap = [width - display_width(content), 0].max
    case align
    when :right then (SPACE * gap) + content
    when :center then (SPACE * (gap / 2)) + content + (SPACE * (gap - (gap / 2)))
    else content + (SPACE * gap)
    end
  end

  # Display width of a string, ANSI escapes excluded.
  def display_width(text)
    Unicode::DisplayWidth.of(strip_ansi(text))
  end

  def strip_ansi(text)
    text.gsub(ANSI_RE, '')
  end
end
