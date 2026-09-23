# frozen_string_literal: true

source 'https://rubygems.org'

ruby '>= 3.3'

# Component-oriented terminal UI framework.
#
# TEMPORARILY on `path: '../tuile'`: this side is ported onto master's
# post-0.16.0 API, which the released 0.16.0 gem no longer builds. Three
# breaking changes reach us — every container divides its rect in a protected
# `relayout` instead of a `rect=` override, in coordinates measured *inside*
# the parent; that pass is deferred, so a rect read in the turn that dirtied it
# wants `Component#flush_layout`; and a listener slot is an append-only list
# with no setter (`screen.on_error << …`, `field.on_change { |e| … }`), each
# firing one event object. Since then only a parent may write `rect=` (specs
# use `Tuile::Testing.place`), an overlay opens with an `Overlay::Placement`,
# a module the placement includes whose declared `anchor` the pane itself
# resolves and follows, and a fake screen raises on an unsettled rect read — so
# width-derived output is built where the width is settled, in `repaint` or
# `relayout`. A string field's one writer and change slot are `value=` /
# `on_value_change` (`text=` and `on_change` are gone), and its event's
# `from_user?` tells typing from a `value=` write. `handle_width_changed` is
# gone too: size-derived state is rebuilt in `relayout`. `Code::Layout` hiding
# its sidebar from its own `relayout` needs tuile#50's fix. The mouse rework
# misses us (nothing here handles a mouse event).
#
# CI can't build against a path gem, so whichever comes first, the cut of
# tuile 0.17 is what un-blocks CI, and that commit reverts this line to
# `'~> 0.17'`.
#
# 0.15 still matters underneath it: Code::Layout hides the sidebar column with
# Component#visible=, which landed there (tuile#17) and now also marks the
# parent's `relayout` — that is what stops a hidden pane painting back at stale
# coordinates on the next full repaint.
gem 'tuile', '~> 0.17'

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
#
# TEMPORARILY on `path: '../pikuri/<gem>'` — and so is every other pikuri-*
# gem below — for co-development of the `[[server]]` config schema, whose
# `max_concurrent_requests` key pairs with pikuri's +decisions.md+ →
# +probe_when_unknown+
# (an explicit +context_window+ no longer suppresses the +/props+ slot count
# that seeds +ServerPermits+).
#
# This side has since absorbed master's post-0.1.0 API too (the step limit and
# its FallbackNotice are gone; the two tool events carry the display strings a
# tool composes), so the released 0.1.0 gems no longer build this repo. CI
# can't build against a path gem either: whichever comes first, the cut of
# pikuri 0.2.0 is what un-blocks CI, and that commit reverts every one of
# these to `'~> 0.2'`.
gem 'pikuri-core', path: '../pikuri/pikuri-core'

# In-process, pure-Ruby (pdf-reader) PDF text extraction with lazy
# windowed paging. Shared by both shells in :default: zero infra
# (no docker / host CLIs), so the lightweight chat shell still runs
# against a bare local llama.cpp. Richer document formats
# (DOCX/XLSX/EPUB/…) via the sandboxed pikuri-extractors gem are
# deliberately deferred until a concrete need — see AGENTS.md.
gem 'pikuri-pdf', path: '../pikuri/pikuri-pdf'

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
gem 'pikuri-workspace', path: '../pikuri/pikuri-workspace', groups: %i[code computer]
gem 'pikuri-code', path: '../pikuri/pikuri-code', groups: %i[code computer]

# Shared by the coding AND computer shells. The privilege-separated sub-agent
# personas + the `agent` tool. The coding shell spawns FILE_MINER /
# RESEARCHER / GIT_REPO_RESEARCHER; the computer shell wires the RESEARCHER
# persona so its otherwise network-severed agent can delegate web research to
# an isolated sub-agent (web tools, no filesystem) — see bin/pikuri-tui-computer.
# +groups:+ so each shell activates it and chat does not.
gem 'pikuri-subagents', path: '../pikuri/pikuri-subagents', groups: %i[code computer]

# Shared by the coding AND computer shells. pikuri-skills carries two surfaces
# on one scan of .pikuri/… / .claude/…: the skill catalog (which only the
# coding shell wires) and Pikuri::Command::Registry, the human-invoked slash
# commands both shells list in their palette. Its sole dependency is
# pikuri-core, so the computer shell pays a load-path line and nothing more.
gem 'pikuri-skills', path: '../pikuri/pikuri-skills', groups: %i[code computer]

# Coding-shell-only runtime: git_clone + toolchain paths (pikuri-code,
# above), the in-context task list (pikuri-tasks), and MCP wiring
# (pikuri-mcp). The computer shell wires none of these, so they stay off its
# load path.
group :code do
  gem 'pikuri-tasks', path: '../pikuri/pikuri-tasks'
  gem 'pikuri-mcp', path: '../pikuri/pikuri-mcp'
end

# Computer-shell-only runtime. pikuri-os is the OS-integration layer +
# +Pikuri::Os::Extension+ (the five file tools + sandboxed bash + the
# machine facts / MACHINE.md system-prompt sections); pikuri-thunderbird adds
# +Pikuri::Thunderbird::Extension+ (local mail + calendar search/read + the
# two human-gated outbound hand-offs). Both pull in pikuri-core + -workspace
# + -code transitively. Grouped so +bin/pikuri-tui-computer+ opts in with
# +Bundler.setup(:default, :computer)+ while chat and code never load them.
group :computer do
  gem 'pikuri-os', path: '../pikuri/pikuri-os'
  gem 'pikuri-thunderbird', path: '../pikuri/pikuri-thunderbird'
end

group :test do
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
