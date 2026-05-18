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
  loader.inflector.inflect('counting_log_io' => 'CountingLogIO')
  loader.setup
  loader.eager_load
end
