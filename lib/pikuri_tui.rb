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
# dialog), and the two IO sinks read naturally next to Tuile's own
# +LogDialog::IO+.
loader.inflector.inflect(
  'ui'             => 'UI',
  'ui_toggle_menu' => 'UIToggleMenu',
  'counting_io'    => 'CountingIO',
  'buffering_io'   => 'BufferingIO'
)

# The coding ({Code}) and computer ({Computer}) shells depend on the heavier
# pikuri gems — pikuri-code and pikuri-skills, both outside the chat shell's
# +Bundler.setup(:default)+. The computer subtree reuses the +Code::*+ adapters
# (confirmer / diff formatters) and so needs the same gems; it references no
# +Pikuri::Os::*+ or +Pikuri::Thunderbird::*+ constant at load time, so it gates
# on the same +Pikuri::Code+ presence. Eager-loading either subtree in the chat
# process would raise at its first +require 'pikuri-code'+. Gate both on that
# runtime being present — true iff the bin (or spec_helper) required those gems
# *before* requiring pikuri_tui. Not on +Pikuri::Workspace+: pikuri-web pulls
# that one into every shell, chat included.
unless defined?(Pikuri::Code)
  loader.ignore("#{__dir__}/code.rb")
  loader.ignore("#{__dir__}/code")
  loader.ignore("#{__dir__}/computer.rb")
  loader.ignore("#{__dir__}/computer")
end

loader.setup
loader.eager_load
