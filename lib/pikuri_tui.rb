# frozen_string_literal: true

require 'zeitwerk'

# Boot file: configures Zeitwerk over +lib/+ and eager-loads it. After
# +require 'pikuri_tui'+ every constant in this tree is defined and
# resolvable.
#
# This is an *end app*, never a published gem, so it carries no umbrella
# namespace: the loader's root is +lib/+ itself, which maps each file to a
# TOP-LEVEL constant — +chat/app.rb+ → +Chat::App+, +shared/log/ui.rb+ →
# +Shared::Log::UI+. Nothing external ever depends on this project, so there
# is nothing to shield from constant clashes.
#
# This file is the sole bootstrap, and it lives *inside* the pushed root, so
# it must exclude itself (+loader.ignore(__FILE__)+) — otherwise Zeitwerk
# would demand a +PikuriTui+ constant to match +lib/pikuri_tui.rb+. Its
# basename is only the app's require target (+require 'pikuri_tui'+), not a
# namespace; no +PikuriTui+ constant exists.
#
# Eager-loading at boot keeps the rule "filename matches CamelCase constant"
# honest (any mismatch fails fast at startup, not at first reference inside
# the event loop).
loader = Zeitwerk::Loader.new
loader.push_dir(__dir__)
loader.ignore(__FILE__)

# Zeitwerk's inflector matches the *whole* basename rather than per-segment,
# so acronym mappings spell the full word. +ui+ → +UI+ (the diagnostic-log
# window), and the two IO sinks read naturally next to Tuile's own
# +LogWindow::IO+.
loader.inflector.inflect(
  'ui'           => 'UI',
  'counting_io'  => 'CountingIO',
  'buffering_io' => 'BufferingIO'
)

# The coding ({Code}) and computer ({Computer}) shells depend on the heavier
# pikuri gems — pikuri-workspace defines +Pikuri::Workspace::Confirmer+ (the
# {Code::ConfirmerPopup} superclass), and pikuri-code backs the rest of the
# boot wiring. The computer subtree reuses the +Code::*+ adapters (confirmer /
# diff formatters) and so needs the same gems; it references no +Pikuri::Os::*+
# or +Pikuri::Thunderbird::*+ constant at load time (only +Code::*+ /
# +Pikuri::Agent::*+), so it gates on the same +Pikuri::Workspace+ presence
# rather than on +Pikuri::Os+ / +Pikuri::Thunderbird+. The chat
# shell runs +Bundler.setup(:default)+ and never loads those gems, so
# eager-loading either subtree there would raise at class-definition time
# (NameError on +Pikuri::Workspace+). Gate both on that runtime being present —
# true iff the bin (or spec_helper) required those gems *before* requiring
# pikuri_tui. When absent, ignore the subtrees so the lean chat process
# neither autoloads nor eager-loads them; when present, they participate
# normally and the fail-fast eager-load guarantee still holds.
unless defined?(Pikuri::Workspace)
  loader.ignore("#{__dir__}/code.rb")
  loader.ignore("#{__dir__}/code")
  loader.ignore("#{__dir__}/computer.rb")
  loader.ignore("#{__dir__}/computer")
end

loader.setup
loader.eager_load
