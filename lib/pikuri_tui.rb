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
  loader.setup
  loader.eager_load
end
