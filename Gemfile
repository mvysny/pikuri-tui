# frozen_string_literal: true

source 'https://rubygems.org'

ruby '>= 3.4'

# Component-oriented terminal UI framework. Pinned to a local checkout
# alongside this project (and pikuri) so changes in the UI framework can be
# co-developed without a release dance; swap to the released gem once the
# shared API has stabilized.
gem 'tuile', path: '../tuile'

# Convention-based autoloader for lib/. Wired up in lib/pikuri_tui.rb so
# every file under lib/pikuri_tui/ declares exactly the constant matching
# its path without per-file require_relative ceremony.
gem 'zeitwerk', '~> 2.7'

# Markdown parser for the conversation pane. PikuriTui::MarkdownRenderer
# parses with kramdown (GFM dialect, via kramdown-parser-gfm) and renders
# the parse tree to ANSI with its own Kramdown::Converter subclass —
# replacing tty-markdown, whose stale pins (strings ~> 0.2.0, rouge < 5)
# were blocking dependency updates. (pikuri-core dropped its own
# tty-markdown dependency in 0.0.6, so it's gone from the lockfile too.)
gem 'kramdown', '~> 2.4'
gem 'kramdown-parser-gfm', '~> 1.1'

# Syntax highlighting for fenced code blocks in the conversation pane.
# Used by PikuriTui::MarkdownRenderer::AnsiConverter. The upper bound
# stays wide on purpose — pinning tightly here is how tty-markdown got
# us stuck.
gem 'rouge', '>= 4.0', '< 6'

# The pikuri-core gem — Agent, Tool, prompts, listeners. The lean
# foundation of pikuri's seven-gem monorepo split (the +pikuri+
# metagem also exists and pulls in every sibling; we only need
# core for the chat shell). Bundled bin scripts in this repo wire
# +Pikuri::Agent+ + +Pikuri::Tool::*+ into Tuile TUIs.
gem 'pikuri-core', path: '../pikuri/pikuri-core'
gem 'pikuri-pdf', path: '../pikuri/pikuri-pdf'

group :test do
  # Test runner. We use the rspec-core describe/it harness but write
  # assertions in minitest style — see CLAUDE.md. Matches pikuri's
  # convention so the two codebases read side-by-side.
  gem 'rspec-core', '~> 3.13'

  # Provides the minitest-style assertion methods (assert_equal,
  # assert_includes, refute, …) used throughout spec/.
  gem 'minitest', '~> 6.0'
end
