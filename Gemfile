# frozen_string_literal: true

source 'https://rubygems.org'

ruby '>= 3.3'

# Component-oriented terminal UI framework. The shared API has stabilized,
# so we consume the released gem; for co-development against an unreleased
# Tuile change, temporarily swap this for `path: '../tuile'`.
gem 'tuile', '~> 0.8.0'

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

# TOML parser for the layered config file (PikuriTui::Config). Pure Ruby,
# parse-only (we only ever READ config, never serialize), with ZERO runtime
# dependencies — chosen over toml-rb after vetting: toml-rb pulls in citrus,
# which was last released in 2015 and ships no license. tomlrb is MIT,
# actively maintained, and the most-downloaded TOML gem. In :default because
# BOTH shells read config — the chat shell needs the [[llm]] section, the
# coding shell that plus [code] / [[code.mcp]]. We parse TOML into a Hash
# and validate that Hash by hand (the schema is tiny); no JSON Schema gem.
gem 'tomlrb', '~> 2.0'

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
gem 'pikuri-core', path: '../pikuri'

# In-process, pure-Ruby (pdf-reader) PDF text extraction with lazy
# windowed paging. Shared by both shells in :default: zero infra
# (no docker / host CLIs), so the lightweight chat shell still runs
# against a bare local llama.cpp. Richer document formats
# (DOCX/XLSX/EPUB/…) via the sandboxed pikuri-extractors gem are
# deliberately deferred until a concrete need — see AGENTS.md.
gem 'pikuri-pdf', '~> 0.0.7'

# The two heavier shells (coding + OS) share their runtime across three
# Bundler groups so each shell's +Bundler.setup+ activates exactly what it
# needs. +bin/pikuri-tui-chat+ runs +Bundler.setup(:default)+ and never
# puts any of this on its load path; +bin/pikuri-tui-code+ opts in with
# +(:default, :code)+; +bin/pikuri-tui-os+ with +(:default, :os)+. NOTE: a
# single Gemfile.lock still resolves all groups together, and +bundle
# install+ installs them all unless +--without+ is configured — the
# grouping buys runtime/load-path selection and documents intent, not
# separate dependency trees.

# Shared by the coding AND OS shells. Line- and character-level LCS diffing
# for the conversation-pane diff view of the edit / write tools
# (PikuriTui::Code::DiffRenderer, which the OS shell reuses). The de-facto
# standard Ruby diff library (rspec depends on it too). The chat shell
# never renders a diff, so +groups:+ keeps it off chat's +(:default)+ load
# path while +(:default, :code)+ and +(:default, :os)+ both activate it.
gem 'diff-lcs', '~> 2.0', groups: %i[code os]

# Shared by the coding AND OS shells. pikuri-workspace (the five file
# tools) and pikuri-code (Bash + the bubblewrap / FullFsNoNet sandbox +
# plan mode) back both: the coding shell composes them directly, the OS
# shell gets them transitively through pikuri-os and reuses the same
# Code:: adapters (ConfirmerPopup, the edit/write diff formatters). Shared
# via +groups:+ so each shell activates them and chat does not.
gem 'pikuri-workspace', path: '../pikuri', groups: %i[code os]
gem 'pikuri-code', path: '../pikuri', groups: %i[code os]

# Shared by the coding AND OS shells. The privilege-separated sub-agent
# personas + the `agent` tool. The coding shell spawns FILE_MINER /
# RESEARCHER / GIT_REPO_RESEARCHER; the OS shell always wires the RESEARCHER
# persona so its otherwise network-severed agent can delegate web research to
# an isolated sub-agent (web tools, no filesystem) — see bin/pikuri-tui-os.
# +groups:+ so each shell activates it and chat does not.
gem 'pikuri-subagents', path: '../pikuri', groups: %i[code os]

# Coding-shell-only runtime: git_clone + toolchain paths (pikuri-code,
# above), the in-context task list (pikuri-tasks), the skill catalog
# (pikuri-skills), and MCP wiring (pikuri-mcp). The OS shell is a single
# offline agent that wires none of these, so they stay off its load path.
group :code do
  gem 'pikuri-tasks', path: '../pikuri'
  gem 'pikuri-skills', path: '../pikuri'
  gem 'pikuri-mcp', path: '../pikuri'
end

# OS-assistant-shell-only runtime. pikuri-os is the OS-integration layer +
# +Pikuri::Os::Extension+ (the five file tools + sandboxed bash + the
# machine facts / MACHINE.md system-prompt sections); it pulls in
# pikuri-core + -workspace + -code. Grouped so +bin/pikuri-tui-os+ opts in
# with +Bundler.setup(:default, :os)+ while chat and code never load it.
group :os do
  gem 'pikuri-os', path: '../pikuri'
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
