# frozen_string_literal: true

require 'kramdown'
require 'kramdown-parser-gfm'
require 'streaming_markdown_parser'

# Turns Markdown into ANSI for the conversation pane: a whole text at once, or
# one block a {Shared::Markdown::StreamingBuffer} already parsed.
#
#   ansi = Shared::Markdown::Renderer.render(md, width: 80, dark: true)
#   ansi = Shared::Markdown::Renderer.convert(root, width: 80, dark: true, section_indent: 2)
#
# Both parse as the streaming parser does — its GFM options and its
# +StreamingMarkdownParser::Repair+ of what LLMs get wrong — so a reply looks
# the same streamed and rendered whole. {Shared::Markdown::AnsiConverter} draws.
#
# Parser and converter warnings go to the +'markdown'+ pikuri logger (the
# diagnostic pane), not the conversation pane.
module Shared::Markdown::Renderer
  # @return [Logger]
  LOG = Pikuri.logger_for('markdown')
  private_constant :LOG

  module_function

  # @param source [String] Markdown source.
  # @param width [Integer] target render width.
  # @param dark [Boolean] whether the terminal background is dark, to pick a
  #   legible code-highlighting theme; "inconclusive" callers keep the default.
  # @return [String] rendered ANSI, newline-terminated lines.
  # @raise [StandardError] whatever kramdown or {Shared::Markdown::AnsiConverter}
  #   raises; the callers degrade.
  def render(source, width:, dark: true)
    doc = Kramdown::Document.new(StreamingMarkdownParser::Repair.call(source),
                                 **StreamingMarkdownParser::DEFAULT_OPTIONS)
    doc.warnings.each { |w| LOG.debug("Shared::Markdown::Renderer: kramdown: #{w}") }
    convert(doc.root, width: width, dark: dark)
  end

  # @param root [Kramdown::Element] a parsed +:root+, e.g. one streamed block.
  # @param width [Integer] target render width.
  # @param dark [Boolean] as in {.render}.
  # @param section_indent [Integer] the indent the headers before +root+ left;
  #   see {Shared::Markdown::AnsiConverter.section_indent_after}.
  # @return [String] rendered ANSI, newline-terminated lines.
  # @raise [StandardError] whatever {Shared::Markdown::AnsiConverter} raises.
  def convert(root, width:, dark: true, section_indent: 0)
    ansi, warnings = Shared::Markdown::AnsiConverter.convert(root, width: width, dark: dark,
                                                                   section_indent: section_indent)
    warnings.each { |w| LOG.warn("Shared::Markdown::Renderer: #{w}") }
    ansi
  end
end
