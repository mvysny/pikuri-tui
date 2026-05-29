# frozen_string_literal: true

source 'https://rubygems.org'

ruby '>= 3.4'

# Component-oriented terminal UI framework. Pinned to a local checkout
# alongside this project (and pikuri) so changes in the UI framework can be
# co-developed without a release dance; swap to the released gem once the
# shared API has stabilized.
gem 'tuile', '~> 0.5.0'

# Convention-based autoloader for lib/. Wired up in lib/pikuri_tui.rb so
# every file under lib/pikuri_tui/ declares exactly the constant matching
# its path without per-file require_relative ceremony.
gem 'zeitwerk', '~> 2.7'

# The pikuri-core gem — Agent, Tool, prompts, listeners. The lean
# foundation of pikuri's seven-gem monorepo split (the +pikuri+
# metagem also exists and pulls in every sibling; we only need
# core for the chat shell). Bundled bin scripts in this repo wire
# +Pikuri::Agent+ + +Pikuri::Tool::*+ into Tuile TUIs.
gem 'pikuri-core', '~> 0.0.4'

group :test do
  # Test runner. We use the rspec-core describe/it harness but write
  # assertions in minitest style — see CLAUDE.md. Matches pikuri's
  # convention so the two codebases read side-by-side.
  gem 'rspec-core', '~> 3.13'

  # Provides the minitest-style assertion methods (assert_equal,
  # assert_includes, refute, …) used throughout spec/.
  gem 'minitest', '~> 6.0'
end
