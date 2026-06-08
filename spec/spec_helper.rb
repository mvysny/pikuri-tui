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

# Load the :code-group gems too, BEFORE pikuri_tui, so its loader sees
# the :code runtime and eager-loads the PikuriTui::Code subtree (see the
# gate in lib/pikuri_tui.rb) — the suite exercises both shells. +bundle
# exec+ puts these on the load path; the production chat bin, which runs
# +Bundler.setup(:default)+, never loads them.
require 'pikuri-workspace'
require 'pikuri-code'
require 'pikuri-tasks'
require 'pikuri-skills'
require 'pikuri-mcp'
require 'pikuri-subagents'

require 'pikuri_tui'

# Point the construction-time theme default at the app's theme pair so
# every +Tuile::Screen.fake+ a spec builds resolves pikuri-tui's custom
# tokens (+theme[:tool]+, +theme.error(…)+, …); without this a component
# reading one would +KeyError+ against the stock Tuile default. Production
# bins assign +screen.theme_def=+ once at boot instead.
Tuile::ThemeDef.default = PikuriTui::AppTheme::THEME_DEF

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
