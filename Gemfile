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
