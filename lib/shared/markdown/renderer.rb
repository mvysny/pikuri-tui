# frozen_string_literal: true

require 'kramdown'
require 'kramdown-parser-gfm'
require 'tuile'

# Single entry point for turning a Markdown string into ANSI for the
# conversation pane. All of pikuri-tui's Markdown rendering routes
# through here — the non-streaming +Assistant+ path
# ({Shared::TuileListener#render_markdown}) and the streaming path
# ({Shared::Markdown::StreamingBuffer}, via the +render:+ callable passed at
# construction).
#
# == Pipeline
#
# 1. *Pre-process*: repair LLM-typographic table separators (see
#    below).
# 2. *Parse*: kramdown with the GFM dialect (+kramdown-parser-gfm+) —
#    backtick fences, GFM tables, strikethrough — and
#    +hard_wrap: false+ so single newlines inside a paragraph stay
#    soft breaks (CommonMark semantics), matching how LLMs emit
#    markdown.
# 3. *Render*: {Shared::Markdown::AnsiConverter}, this project's own
#    +Kramdown::Converter+ subclass. It replaced +tty-markdown+
#    (whose stale dependency pins blocked updates) and natively
#    handles what this module previously patched around with
#    source-injection hacks: loose lists render loose — bulleted
#    *and* ordered, numbering intact — and block spacing comes out
#    right the first time, so there is no post-processing pass.
#
# Parser and converter warnings are forwarded to the +'markdown'+ pikuri
# logger (the diagnostic pane), not the conversation pane.
#
# == Table separators
#
# LLMs frequently typographically substitute +"---"+ with +"—-"+
# (em-dash + hyphen) when emitting GFM table separator rows.
# kramdown's separator detector only accepts +-+, +:+, +|+, and
# whitespace; any other character disqualifies the block, and the
# table falls back to prose paragraphs that contain literal pipes.
# We pre-process any line that looks like a separator row (only
# pipe / dash / em-dash / en-dash / colon / space characters, with
# at least one interior pipe) and rewrite the em-dashes and
# en-dashes back to ASCII hyphens before parsing. Prose lines that
# contain em-dashes are untouched — the pattern requires the whole
# line to be made of separator characters.
module Shared::Markdown::Renderer
  # Matches a line whose entire content is GFM-table-separator-shaped
  # — only pipes, dashes, em-dashes (U+2014), en-dashes (U+2013),
  # colons, and horizontal whitespace, with at least one interior
  # pipe. The interior pipe is the disambiguator: prose with a stray
  # em-dash won't match, and a horizontal rule (+"---"+ alone) won't
  # match either. Used to find malformed separator rows emitted by
  # LLMs that typographically substitute +"---"+ with +"—-"+.
  TABLE_SEPARATOR_LIKE = /^[ \t]*\|?[ \t\-—–:]*\|[ \t\-—–:|]*$/
  private_constant :TABLE_SEPARATOR_LIKE

  LOG = Pikuri.logger_for('markdown')
  private_constant :LOG

  module_function

  # Render Markdown to ANSI.
  #
  # @param source [String] Markdown source.
  # @param width [Integer] target render width, forwarded to
  #   {Shared::Markdown::AnsiConverter}.
  # @param dark [Boolean] whether the terminal background is dark,
  #   forwarded to {Shared::Markdown::AnsiConverter} to pick a legible code-block
  #   highlighting theme. Defaults to +true+ (the "inconclusive means
  #   dark" convention), so callers that don't know the scheme keep the
  #   dark-tuned output.
  # @return [String] rendered ANSI, with internal newlines preserved
  #   (callers that want hard lines should +#split("\n")+ the result).
  # @raise [StandardError] whatever kramdown parsing or {Shared::Markdown::AnsiConverter}
  #   raises. Callers handle this — both the streaming buffer and
  #   {Shared::TuileListener#render_markdown} catch and degrade.
  def render(source, width:, dark: true)
    patched = fix_table_separators(source)
    doc = Kramdown::Document.new(patched, input: 'GFM', hard_wrap: false, width: width, dark: dark)
    ansi, warnings = Shared::Markdown::AnsiConverter.convert(doc.root, doc.options)
    doc.warnings.each { |w| LOG.debug("Shared::Markdown::Renderer: kramdown: #{w}") }
    warnings.each { |w| LOG.warn("Shared::Markdown::Renderer: #{w}") }
    ansi
  end

  # Rewrite em-dashes (U+2014) and en-dashes (U+2013) back to ASCII
  # hyphens on lines that look like GFM table separator rows, so
  # kramdown recognises the table. No-op on lines that don't match
  # {TABLE_SEPARATOR_LIKE} and on separator rows that already use
  # only ASCII hyphens.
  #
  # @param source [String] Markdown source.
  # @return [String]
  def fix_table_separators(source)
    source.gsub(TABLE_SEPARATOR_LIKE) do |line|
      line.match?(/[—–]/) ? line.tr('—–', '-') : line
    end
  end
end
