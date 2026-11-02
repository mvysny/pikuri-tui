# frozen_string_literal: true

source 'https://rubygems.org'

ruby '>= 3.3'

# Component-oriented terminal UI framework.
#
# TEMPORARILY on tuile's git master: this side is ported onto master's
# post-0.17.0 API, which the released 0.17.0 gem no longer builds. The
# breaking changes that reach us — `Popup` became `Dialog`, which draws its own
# border, and the `*Window` modals became `*Dialog` subclasses opened by plain
# `#open`, so the log and leader-menu dialogs subclass them and the git diff
# is a `TextView` in a plain `Dialog`, none wrapping a window in a popup; a
# string field
# announces typing only on commit, so the input's slash palette asks for
# `value_change_mode = :eager`; the fake event queue queues every `submit`
# until `Tuile::Testing.loop` (or a `FakeScreen#key`) plays the turn; and
# every framework ivar is now `@_foo`. `capture_mouse` defaulting to `:drag`
# makes the pane scrollbars draggable for free.
#
# Git rather than `path: '../tuile'`, so the build gets the revision
# Gemfile.lock pins, not whatever a sibling checkout happens to hold: a stale
# `../tuile` loads an old Theme that rejects AppTheme's derived tokens at boot.
# `bundle update tuile` moves the pin to master's head. The cut of tuile 0.18
# reverts this line to `'~> 0.18'`.
#
# 0.15 still matters underneath it: Code::Layout hides the sidebar column with
# Component#visible=, which landed there (tuile#17) and now also marks the
# parent's `relayout` — that is what stops a hidden pane painting back at stale
# coordinates on the next full repaint.
gem 'tuile', git: 'https://github.com/mvysny/tuile.git', branch: 'master'

# Convention-based autoloader for lib/. Wired up in lib/pikuri_tui.rb so
# every file under lib/ declares exactly the top-level constant matching
# its path without per-file require_relative ceremony.
gem 'zeitwerk', '~> 2.7'

# Markdown parser for the conversation pane. Shared::Markdown::Renderer
# parses with kramdown (GFM dialect, via kramdown-parser-gfm) and renders
# the parse tree to ANSI with its own Kramdown::Converter subclass —
# replacing tty-markdown, whose stale pins (strings ~> 0.2.0, rouge < 5)
# were blocking dependency updates. (pikuri-core dropped its own
# tty-markdown dependency in 0.0.6, so it's gone from the lockfile too.)
gem 'kramdown', '~> 2.4'
gem 'kramdown-parser-gfm', '~> 1.1'

# Syntax highlighting for fenced code blocks in the conversation pane.
# Used by Shared::Markdown::AnsiConverter. The upper bound
# stays wide on purpose — pinning tightly here is how tty-markdown got
# us stuck.
gem 'rouge', '>= 4.0', '< 6'

# TOML parser for the layered config file (Shared::Config). Pure Ruby,
# parse-only (we only ever READ config, never serialize), with ZERO runtime
# dependencies — chosen over toml-rb after vetting: toml-rb pulls in citrus,
# which was last released in 2015 and ships no license. tomlrb is MIT,
# actively maintained, and the most-downloaded TOML gem. In :default because
# BOTH shells read config — the chat shell needs the [[llm]] section, the
# coding shell that plus [code] / [[code.mcp]]. typemap, below, checks the
# parsed Hash; no JSON Schema gem.
gem 'tomlrb', '~> 3.0'

# Maps the parsed TOML onto Shared::Config's Data classes, checking every value
# against the type its YARD tag gives. Typemap reads those types from
# sig/pikuri_tui.rbs through rbs's parser, so rbs is a runtime gem here (about
# 0.2 s of `require` at boot). On typemap's git main until its first release.
gem 'rbs', '~> 4.2'
gem 'typemap', git: 'https://github.com/mvysny/typemap.git', branch: 'main'

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
#
# TEMPORARILY on pikuri's git master — and so is every other pikuri-* gem
# below, all from the one monorepo checkout Bundler finds their gemspecs in.
# This side has absorbed master's post-0.1.0 API (the step limit and its
# FallbackNotice are gone; the two tool events carry the display strings a tool
# composes; the `[[server]]` schema's `max_concurrent_requests` pairs with
# pikuri's +decisions.md+ → +probe_when_unknown+), so the released 0.1.0 gems
# no longer build this repo. Git rather than `path: '../pikuri/<gem>'` for
# tuile's reason above: Gemfile.lock pins one revision for all of them, and
# `bundle update pikuri-core` moves it. The cut of pikuri 0.2.0 reverts every
# one of these to `'~> 0.2'`.
pikuri = { git: 'https://codeberg.org/mvysny/pikuri.git', branch: 'master' }
gem 'pikuri-core', **pikuri

# In-process, pure-Ruby (pdf-reader) PDF text extraction with lazy
# windowed paging. Shared by both shells in :default: zero infra
# (no docker / host CLIs), so the lightweight chat shell still runs
# against a bare local llama.cpp. Richer document formats
# (DOCX/XLSX/EPUB/…) via the sandboxed pikuri-extractors gem are
# deliberately deferred until a concrete need — see AGENTS.md.
gem 'pikuri-pdf', **pikuri

# The two heavier shells (coding + computer) share their runtime across three
# Bundler groups so each shell's +Bundler.setup+ activates exactly what it
# needs. +bin/pikuri-tui-chat+ runs +Bundler.setup(:default)+ and never
# puts any of this on its load path; +bin/pikuri-tui-code+ opts in with
# +(:default, :code)+; +bin/pikuri-tui-computer+ with +(:default, :computer)+.
# NOTE: a single Gemfile.lock still resolves all groups together, and +bundle
# install+ installs them all unless +--without+ is configured — the
# grouping buys runtime/load-path selection and documents intent, not
# separate dependency trees.

# Shared by the coding AND computer shells. Line- and character-level LCS
# diffing for the conversation-pane diff view of the edit / write tools
# (Code::DiffRenderer, which the computer shell reuses). The de-facto
# standard Ruby diff library (rspec depends on it too). The chat shell
# never renders a diff, so +groups:+ keeps it off chat's +(:default)+ load
# path while +(:default, :code)+ and +(:default, :computer)+ both activate it.
gem 'diff-lcs', '~> 2.0', groups: %i[code computer]

# Shared by the coding AND computer shells. pikuri-workspace (the five file
# tools) and pikuri-code (Bash + the bubblewrap / FullFsNoNet sandbox +
# plan mode) back both: the coding shell composes them directly, the computer
# shell gets them transitively through pikuri-os and reuses the same
# Code:: adapters (ConfirmerPopup, the edit/write diff formatters). Shared
# via +groups:+ so each shell activates them and chat does not.
gem 'pikuri-code', **pikuri, groups: %i[code computer]
gem 'pikuri-workspace', **pikuri, groups: %i[code computer]

# Shared by the coding AND computer shells. The privilege-separated sub-agent
# personas + the `agent` tool. The coding shell spawns FILE_MINER /
# RESEARCHER / GIT_REPO_RESEARCHER; the computer shell wires the RESEARCHER
# persona so its otherwise network-severed agent can delegate web research to
# an isolated sub-agent (web tools, no filesystem) — see bin/pikuri-tui-computer.
# +groups:+ so each shell activates it and chat does not.
gem 'pikuri-subagents', **pikuri, groups: %i[code computer]

# Shared by the coding AND computer shells. pikuri-skills carries two surfaces
# on one scan of .pikuri/… / .claude/…: the skill catalog (which only the
# coding shell wires) and Pikuri::Command::Registry, the human-invoked slash
# commands both shells list in their palette. Its sole dependency is
# pikuri-core, so the computer shell pays a load-path line and nothing more.
gem 'pikuri-skills', **pikuri, groups: %i[code computer]

# Coding-shell-only runtime: git_clone + toolchain paths (pikuri-code,
# above), the in-context task list (pikuri-tasks), and MCP wiring
# (pikuri-mcp). The computer shell wires none of these, so they stay off its
# load path.
group :code do
  gem 'pikuri-mcp', **pikuri
  gem 'pikuri-tasks', **pikuri
end

# Computer-shell-only runtime. pikuri-os is the OS-integration layer +
# +Pikuri::Os::Extension+ (the five file tools + sandboxed bash + the
# machine facts / MACHINE.md system-prompt sections); pikuri-thunderbird adds
# +Pikuri::Thunderbird::Extension+ (local mail + calendar search/read + the
# two human-gated outbound hand-offs). Both pull in pikuri-core + -workspace
# + -code transitively. Grouped so +bin/pikuri-tui-computer+ opts in with
# +Bundler.setup(:default, :computer)+ while chat and code never load them.
group :computer do
  gem 'pikuri-os', **pikuri
  gem 'pikuri-thunderbird', **pikuri
end

# Types are written once, as YARD tags; sord compiles them into the committed
# sig/pikuri_tui.rbs, and `rake sig` (part of `rake check`) fails on any tag
# sord cannot type. redcarpet renders the Markdown that .yardopts selects.
group :development do
  gem 'redcarpet', '~> 3.6'
  gem 'rubocop', '~> 1.92', require: false
  gem 'sord', '~> 7.1', require: false
  gem 'yard', '~> 0.9.45'
end

group :test do
  # Line + branch coverage of the suite, written to coverage/ by spec_helper.
  gem 'simplecov', '~> 1.3', require: false

  # Runs the Rakefile's `check` task — the cross-repo standard entry
  # point (`bundle exec rake check`; also the default task).
  gem 'rake', '~> 13.3'

  # Test runner. We use the rspec-core describe/it harness but write
  # assertions in minitest style — see AGENTS.md. Matches pikuri's
  # convention so the two codebases read side-by-side.
  gem 'rspec-core', '~> 3.13'

  # Provides the minitest-style assertion methods (assert_equal,
  # assert_includes, refute, …) used throughout spec/.
  gem 'minitest', '~> 6.0'
end
