# frozen_string_literal: true

require 'streaming_markdown_parser'
require 'tuile'

# Renders a streamed Markdown reply into one +Tuile::Component::TextView::Region+,
# live, delta by delta:
#
#   render = ->(root, section_indent) { Shared::Markdown::Renderer.convert(root, width: 80, section_indent:) }
#   buf = Shared::Markdown::StreamingBuffer.new(render: render, region: region)
#   buf.append('## Hel')          # region shows the partial render
#   buf.append("lo\n")
#   buf.finalize(final_markdown)   # the authoritative text; buffer now dead
#
# +StreamingMarkdownParser+ cuts the reply into top-level blocks: each finished
# block is rendered once and kept, and only the open tail re-renders per delta,
# so the cost of a delta doesn't grow with the reply. Finished blocks sit one
# blank line apart, as {Shared::Markdown::AnsiConverter} spaces a whole text.
#
# One buffer per assistant turn: {#append} each +AssistantDelta+, then
# {#finalize} once with the +Assistant+ content, which renders the reply
# afresh, whole: deltas are only a preview of it, and only the whole text
# resolves a reference link or footnote whose definition is a block away
# (streaming-markdown-parser's README, "When is a block finished?").
#
# == Implementation details
#
# A top-level header indents what follows it, and a block rendered alone can't
# see the headers above it; the buffer carries that indent from block to block
# (+section_indent+ in the render callable).
#
# A render that raises is logged and degrades: the open tail keeps its
# previous render, a finished block shows as its Markdown source. Raising
# would escape through the parser mid-commit.
#
# UI-thread-confined (the region's mutators call +Tuile::Screen#check_locked+).
class Shared::Markdown::StreamingBuffer
  include StreamingMarkdownParser::Listener

  # @return [Logger]
  LOG = Pikuri.logger_for('markdown')
  private_constant :LOG

  # @param render [#call] +(Kramdown::Element root, Integer section_indent) -> String+:
  #   ANSI for the root's blocks. Bake width and theme in; a resize mid-stream
  #   shows from the next reply.
  # @param region [Tuile::Component::TextView::Region] rewritten on every delta;
  #   nothing else may write it until {#finalize}.
  # @param indent [Integer] leading spaces on the region's first line.
  def initialize(render:, region:, indent: 0)
    @render = render
    @region = region
    @pad = ' ' * indent
    @parser = StreamingMarkdownParser.new(self)
    on_reset
  end

  # Feeds one streamed chunk. Empty / +nil+ content is a no-op.
  #
  # @param content [String, nil] the +AssistantDelta#content+ payload.
  # @return [void]
  # @raise [RuntimeError] if called after {#finalize}.
  def append(content)
    raise 'Shared::Markdown::StreamingBuffer#append called after #finalize' if finalized?

    parse { @parser.append(content) }
  end

  # Ends the stream with the authoritative final Markdown, which may differ
  # from the deltas, and renders it as a reply that arrived whole: a fresh
  # parser, not the streaming one, whose +finish+ given the streamed text
  # would keep its blocks and their literal references. The region keeps the
  # streamed render until the whole one is ready.
  #
  # @param authoritative [String] the final Markdown for this turn.
  # @return [void]
  # @raise [RuntimeError] if called more than once.
  def finalize(authoritative)
    raise 'Shared::Markdown::StreamingBuffer#finalize called twice' if finalized?

    @parser = StreamingMarkdownParser.new(self)
    on_reset
    parse { @parser.finish(authoritative.to_s) }
  end

  # @return [Boolean] +true+ after {#finalize} has run.
  def finalized? = @parser.finished?

  # @return [String] the Markdown so far — what the owner passes to {#finalize}
  #   to keep the preview as-is.
  def source = @parser.source

  # @param root [Kramdown::Element]
  # @return [void]
  def on_block(root)
    lines = render_lines(root) || source_lines(root)
    @section_indent = Shared::Markdown::AnsiConverter.section_indent_after(root, @section_indent)
    return if lines.empty?

    @done_lines << '' unless @done_lines.empty?
    @done_lines.concat(lines)
  end

  # @param root [Kramdown::Element]
  # @return [void]
  def on_open(root)
    lines = render_lines(root)
    return if lines.nil?

    lines = [''] + lines unless @done_lines.empty? || lines.empty?
    text = (@done_lines + lines).join("\n")
    @region.text = text.empty? ? text : @pad + text
  end

  # @return [void]
  def on_reset
    @done_lines = []
    @section_indent = 0
  end

  private

  # Runs a parser call, logging a kramdown failure rather than raising: the
  # region keeps its previous render, and the next delta parses again.
  #
  # @return [void]
  def parse
    yield
  rescue StandardError => e
    LOG.warn("Shared::Markdown::StreamingBuffer: parse failed (#{e.class}: #{e.message}); keeping previous render")
  end

  # @param root [Kramdown::Element]
  # @return [Array<String>, nil] the rendered hard lines, or +nil+ when the
  #   render raised (logged).
  def render_lines(root)
    return [] if root.children.empty?

    @render.call(root, @section_indent).split("\n")
  rescue StandardError => e
    LOG.warn("Shared::Markdown::StreamingBuffer: render failed (#{e.class}: #{e.message})")
    nil
  end

  # @param root [Kramdown::Element]
  # @return [Array<String>] the block as Markdown source, for a block whose
  #   render failed.
  def source_lines(root)
    Kramdown::Converter::Kramdown.convert(root).first.split("\n")
  end
end
