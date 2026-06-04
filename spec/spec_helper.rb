# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

# Disable ANSI colorisation in +PikuriTui::MarkdownRenderer::AnsiConverter+
# for the suite. Spec assertions about Markdown output target *structure*
# — bullet markers, blank-line placement, table-separator rewriting —
# not the surrounding ANSI styling. Specs that *are* about styling
# (ansi_converter_spec.rb) re-enable color per render.
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
