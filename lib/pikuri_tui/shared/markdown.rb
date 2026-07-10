# frozen_string_literal: true

module Shared
  # Markdown → ANSI rendering for the conversation pane: the entry point
  # ({Markdown::Renderer}) over its in-house kramdown converter
  # ({Markdown::AnsiConverter}), the buffers that rewrite a +TextView::Region+
  # in place from streamed deltas ({Markdown::StreamingBuffer} and its
  # render-free variant {Markdown::PassthroughBuffer}), and the thinking-pane
  # recolorizer ({Markdown::Grayscale}).
  module Markdown
  end
end
