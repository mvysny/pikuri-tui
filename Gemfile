# frozen_string_literal: true

source "https://rubygems.org"

ruby ">= 3.4"

# Component-oriented terminal UI framework.
gem "tuile"

# Convention-based autoloader for lib/. Wired up in lib/pikuri_tui.rb so
# every file under lib/pikuri_tui/ declares exactly the constant matching
# its path without per-file require_relative ceremony.
gem "zeitwerk", "~> 2.7"

# The pikuri library — Agent, Tool, prompts, listeners. Bundled bin
# scripts in this repo wire pikuri into Tuile TUIs. Pinned to a local
# checkout for now; swap to the released gem (or git source) once a
# compatible version is published.
gem "pikuri", path: "../pikuri"

group :test do
  # Test runner. We use the rspec-core describe/it harness but write
  # assertions in minitest style — see CLAUDE.md. Matches pikuri's
  # convention so the two codebases read side-by-side.
  gem "rspec-core", "~> 3.13"

  # Provides the minitest-style assertion methods (assert_equal,
  # assert_includes, refute, …) used throughout spec/.
  gem "minitest", "~> 6.0"
end
