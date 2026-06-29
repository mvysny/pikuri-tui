# frozen_string_literal: true

require 'zeitwerk'

# Boot file: configures Zeitwerk for everything under +lib/pikuri_tui/+
# and eager-loads it. After +require 'pikuri_tui'+, every constant
# declared in this tree is defined and resolvable. Eager-loading at
# boot keeps the rule "filename matches CamelCase constant" honest
# (any mismatch fails fast at startup, not at first reference inside
# the event loop).
module PikuriTui
  loader = Zeitwerk::Loader.for_gem
  # +CountingLogIO+ pairs with +Tuile::Component::LogWindow::IO+; the
  # default camelizer would resolve +counting_log_io.rb+ to +CountingLogIo+
  # and the all-caps reads naturally next to Tuile's own +IO+. Zeitwerk's
  # inflector matches the *whole* basename rather than per-segment, so
  # the mapping has to spell the full word — segment-only rules like
  # +'io' => 'IO'+ aren't consulted.
  loader.inflector.inflect(
    'counting_log_io'  => 'CountingLogIO',
    'buffering_log_io' => 'BufferingLogIO'
  )

  # The coding ({PikuriTui::Code}) and OS-assistant ({PikuriTui::Os})
  # shells depend on the heavier pikuri gems — pikuri-workspace defines
  # +Pikuri::Workspace::Confirmer+ (the {Code::ConfirmerPopup} superclass),
  # and pikuri-code backs the rest of the boot wiring. The OS subtree
  # reuses the +Code::*+ adapters (confirmer / diff formatters) and so
  # needs the same gems; it references no +Pikuri::Os::*+ constant at load
  # time (only +Code::*+ / +Pikuri::Agent::*+), so it gates on the same
  # +Pikuri::Workspace+ presence rather than on +Pikuri::Os+. The chat
  # shell runs +Bundler.setup(:default)+ and never loads those gems, so
  # eager-loading either subtree there would raise at class-definition time
  # (NameError on +Pikuri::Workspace+). Gate both on that runtime being
  # present — true iff the bin (or spec_helper) required those gems
  # *before* requiring pikuri_tui. When absent, ignore the subtrees so the
  # lean chat process neither autoloads nor eager-loads them; when present,
  # they participate normally and the fail-fast eager-load guarantee still
  # holds.
  unless defined?(Pikuri::Workspace)
    loader.ignore("#{__dir__}/pikuri_tui/code.rb")
    loader.ignore("#{__dir__}/pikuri_tui/code")
    loader.ignore("#{__dir__}/pikuri_tui/os.rb")
    loader.ignore("#{__dir__}/pikuri_tui/os")
  end

  loader.setup
  loader.eager_load
end
