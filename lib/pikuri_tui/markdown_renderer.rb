# frozen_string_literal: true

require 'tty-markdown'

module PikuriTui
  # Single entry point for turning a Markdown string into ANSI for the
  # conversation pane. All of pikuri-tui's Markdown rendering routes
  # through here — the non-streaming +Assistant+ path
  # ({TuileListener#render_markdown}) and the streaming path
  # ({StreamingMarkdownBuffer}, via the +render:+ callable passed at
  # construction).
  #
  # == Why a wrapper around +TTY::Markdown+
  #
  # +TTY::Markdown+ (kramdown under the hood) renders *loose* and *tight*
  # lists identically — +"* foo\n\n* bar"+ and +"* foo\n* bar"+ both
  # produce +"● foo\n● bar"+. That collapses visual structure the LLM
  # explicitly emitted: when the model writes bullets separated by blank
  # lines, the reader expects to see them separated. This module fixes
  # that without changing renderer:
  #
  # 1. *Pre-process*: between two bullet items separated by one or more
  #    blank lines (markers +*+ +-+ +++ — ordered lists are excluded so
  #    we don't perturb numbering, see below), inject an inert HTML
  #    comment +"<!-- -->"+ as a paragraph-level block. kramdown then
  #    treats the input as two separate single-item lists with a
  #    paragraph break between them — which renders with blank lines
  #    around the comment block.
  # 2. *Render*: hand the patched source to +TTY::Markdown.parse+.
  # 3. *Post-process*: collapse runs of 2+ consecutive blank rendered
  #    lines down to 1. The HTML-comment injection produces three blank
  #    rendered lines in a row; we want one. This pass is a no-op on
  #    stock +TTY::Markdown+ output (it never emits adjacent blanks on
  #    its own).
  #
  # == Why bullets only
  #
  # Splitting an ordered list +"1. one\n\n2. two"+ into two single-item
  # lists makes kramdown renumber the second list to start at +1+ — so
  # +"1. one\n\n1. two"+ comes out. That's a worse regression than the
  # missing blank line. Bulleted lists have no numbering to break, so
  # the trick is safe there. Numbered loose lists pass through untouched
  # (rendered tight, with correct numbering).
  #
  # == What this is not
  #
  # The pre-pass handles the common case (single-line bullet items
  # blank-separated). It does *not* handle multi-line items with
  # continuation lines — the regex anchors on a list-marker line and
  # won't fire if the blank is preceded by an indented continuation.
  # LLM bullet output in practice is single-line; if that changes,
  # widen the regex.
  module MarkdownRenderer
    # Matches +<bullet-item-line>\n\n+(?=<bullet-marker>)+ — the boundary
    # between two blank-separated bulleted list items, anchored on both
    # sides so we don't fire on paragraph-then-list or list-then-paragraph
    # transitions. The +/m+ flag makes +.+ optional (we don't use +.+,
    # but +^+ stays line-anchored either way; +/m+ is here as a hedge
    # in case the regex grows).
    LOOSE_BULLET_BOUNDARY = /^([ \t]*[*+\-]\s[^\n]*\n)\n+(?=[ \t]*[*+\-]\s)/m
    private_constant :LOOSE_BULLET_BOUNDARY

    # Inert HTML comment that kramdown happily accepts as a block-level
    # separator between two lists. Surrounded by blank lines so kramdown
    # parses it as its own block rather than as inline HTML inside the
    # preceding list item.
    LOOSE_BULLET_SEPARATOR = "\n<!-- -->\n\n"
    private_constant :LOOSE_BULLET_SEPARATOR

    module_function

    # Render Markdown to ANSI, with the loose-bullet-list fix applied.
    #
    # @param source [String] Markdown source.
    # @param width [Integer] target render width, forwarded to
    #   +TTY::Markdown.parse+.
    # @return [String] rendered ANSI, with internal newlines preserved
    #   (callers that want hard lines should +#split("\n")+ the result).
    # @raise [StandardError] whatever +TTY::Markdown.parse+ raises.
    #   Callers handle this — both the streaming buffer and
    #   {TuileListener#render_markdown} catch and degrade.
    def render(source, width:)
      patched = source.gsub(LOOSE_BULLET_BOUNDARY, "\\1#{LOOSE_BULLET_SEPARATOR}")
      rendered = TTY::Markdown.parse(patched, width: width)
      collapse_blank_runs(rendered)
    end

    # Collapse runs of 2+ adjacent blank lines down to a single blank.
    # No-op on inputs that don't contain such runs. Uses
    # +String#split("\n", -1)+ so a trailing newline in the input is
    # preserved (the default +#split("\n")+ drops trailing empties and
    # would change +"a\n"+ to +"a"+ — surprising for callers).
    # @param ansi [String] rendered ANSI output.
    # @return [String]
    def collapse_blank_runs(ansi)
      lines = ansi.split("\n", -1)
      out = []
      prev_blank = false
      lines.each do |line|
        blank = line.empty?
        next if blank && prev_blank
        out << line
        prev_blank = blank
      end
      out.join("\n")
    end
  end
end
