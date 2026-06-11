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

  # The coding shell ({PikuriTui::Code}) depends on the :code-group
  # pikuri gems — pikuri-workspace defines +Pikuri::Workspace::Confirmer+
  # (the {Code::ConfirmerPopup} superclass), and pikuri-code / -tasks /
  # -subagents back the rest of the boot wiring. The chat shell runs
  # +Bundler.setup(:default)+ and never loads those gems, so eager-loading
  # the code subtree there would raise at class-definition time (NameError
  # on +Pikuri::Workspace+). Gate it on the :code runtime being present —
  # true iff the bin (or spec_helper) required those gems *before*
  # requiring pikuri_tui. When absent, ignore the subtree so the lean chat
  # process neither autoloads nor eager-loads it; when present, it
  # participates normally and the fail-fast eager-load guarantee still
  # holds for it.
  unless defined?(Pikuri::Workspace)
    loader.ignore("#{__dir__}/pikuri_tui/code.rb")
    loader.ignore("#{__dir__}/pikuri_tui/code")
  end

  loader.setup
  loader.eager_load
end
