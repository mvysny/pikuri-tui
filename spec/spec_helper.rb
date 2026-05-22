# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

# Disable ANSI colorisation in +TTY::Markdown+ (via +Pastel+ / +tty-color+)
# for the suite. Spec assertions about Markdown output target *structure*
# — bullet markers, blank-line placement, table-separator rewriting —
# not the surrounding ANSI styling. Colour bytes vary by terminal and by
# +tty-color+'s auto-detection (TTY vs piped), which would make the same
# spec pass in CI and fail interactively. Pin both ends to the no-colour
# branch so the suite is deterministic everywhere. Must be set before
# +tty-markdown+ is loaded so +Pastel.new+ sees it.
ENV['NO_COLOR'] = '1'

require 'rspec/core'
require 'minitest'
require 'minitest/assertions'

require 'pikuri-core'
require 'pikuri_tui'

# Silence pikuri's default $stderr logging during the suite so production
# log lines don't bleed into rspec output. Specs that exercise logging
# swap +Pikuri.log_io+ to a +StringIO+ or a +CountingLogIO+ wired against
# a +Tuile::FakeScreen+, then restore it.
Pikuri.log_io = File.open(File::NULL, 'w')

RSpec.configure do |config|
  config.include Minitest::Assertions
  config.include(Module.new do
    attr_writer :assertions

    def assertions
      @assertions ||= 0
    end
  end)
end
