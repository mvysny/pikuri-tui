# frozen_string_literal: true

source 'https://rubygems.org'

ruby '>= 3.3'

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
# metagem also exists and pulls in every sibling; we only need a
# subset). Bundled bin scripts in this repo wire +Pikuri::Agent+ +
# +Pikuri::Tool::*+ into Tuile TUIs. In :default because BOTH shells
# need it; the coding shell's extras are split into the :code group
# below so the coding bin can +Bundler.setup(:default, :code)+ while
# the chat bin stays on +Bundler.setup(:default)+, keeping the heavier
# coding dependencies off chat's load path. (No +:chat+ group: tuile,
# kramdown and rouge are shared by both conversation panes, so the
# chat shell has no dependencies of its own beyond +:default+.)
gem 'pikuri-core', path: '../pikuri/pikuri-core'

# In-process, pure-Ruby (pdf-reader) PDF text extraction with lazy
# windowed paging. Shared by both shells in :default: zero infra
# (no docker / host CLIs), so the lightweight chat shell still runs
# against a bare local llama.cpp. Richer document formats
# (DOCX/XLSX/EPUB/…) via the sandboxed pikuri-extractors gem are
# deliberately deferred until a concrete need — see AGENTS.md.
gem 'pikuri-pdf', path: '../pikuri/pikuri-pdf'

# The coding shell's extra runtime — the six file/shell tools
# (pikuri-workspace), the bubblewrap sandbox + git_clone + toolchain
# paths (pikuri-code), the in-context task list (pikuri-tasks), the
# skill catalog (pikuri-skills), MCP wiring (pikuri-mcp), and the
# privilege-separated sub-agent personas (pikuri-subagents). Grouped
# so +bin/pikuri-tui-chat+, which calls +Bundler.setup(:default,
# :chat)+, never puts any of this on its load path — chat needs none
# of it. +bin/pikuri-tui-code+ opts in with +Bundler.setup(:default,
# :code)+. NOTE: a single Gemfile.lock still resolves all groups
# together, and +bundle install+ installs them unless +--without
# code+ is configured; the grouping buys runtime/load-path selection
# and documents intent, not separate dependency trees.
group :code do
  gem 'pikuri-workspace', path: '../pikuri/pikuri-workspace'
  gem 'pikuri-code', path: '../pikuri/pikuri-code'
  gem 'pikuri-tasks', path: '../pikuri/pikuri-tasks'
  gem 'pikuri-skills', path: '../pikuri/pikuri-skills'
  gem 'pikuri-mcp', path: '../pikuri/pikuri-mcp'
  gem 'pikuri-subagents', path: '../pikuri/pikuri-subagents'
end

group :test do
  # Test runner. We use the rspec-core describe/it harness but write
  # assertions in minitest style — see CLAUDE.md. Matches pikuri's
  # convention so the two codebases read side-by-side.
  gem 'rspec-core', '~> 3.13'

  # Provides the minitest-style assertion methods (assert_equal,
  # assert_includes, refute, …) used throughout spec/.
  gem 'minitest', '~> 6.0'
end
