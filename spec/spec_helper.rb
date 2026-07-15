# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

# Disable ANSI colorisation in +Shared::Markdown::AnsiConverter+
# for the suite. Spec assertions about Markdown output target *structure*
# — bullet markers, blank-line placement, table-separator rewriting —
# not the surrounding ANSI styling. Specs that *are* about styling
# (ansi_converter_spec.rb) re-enable color per render.
ENV['NO_COLOR'] = '1'

require 'rspec/core'
require 'minitest'
require 'minitest/assertions'
require 'stringio'

require 'pikuri-core'

# Load the :code-group gems too, BEFORE pikuri_tui, so its loader sees
# the :code runtime and eager-loads the Code subtree (see the
# gate in lib/pikuri_tui.rb) — the suite exercises both shells. +bundle
# exec+ puts these on the load path; the production chat bin, which runs
# +Bundler.setup(:default)+, never loads them.
require 'pikuri-workspace'
require 'pikuri-code'
require 'pikuri-tasks'
require 'pikuri-skills'
require 'pikuri-mcp'
require 'pikuri-subagents'
# Also pull in pikuri-os + pikuri-thunderbird so a computer-shell spec can
# build the real Pikuri::Os::Extension / Pikuri::Thunderbird::Extension. The
# Computer subtree itself eager-loads via the +Pikuri::Workspace+ gate (it
# reuses the Code:: adapters and references no Pikuri::Os::* /
# Pikuri::Thunderbird::* constant at load time), so these requires are for
# the extensions, not the subtree.
require 'pikuri-os'
require 'pikuri-thunderbird'

require 'pikuri_tui'

# Point the construction-time theme default at the app's theme pair so
# every +Tuile::Screen.fake+ a spec builds resolves pikuri-tui's custom
# tokens (+theme[:tool]+, +theme.error(…)+, …); without this a component
# reading one would +KeyError+ against the stock Tuile default. Production
# bins assign +screen.theme_def=+ once at boot instead.
Tuile::ThemeDef.default = Shared::AppTheme::THEME_DEF

# Silence pikuri's default $stderr logging during the suite so production
# log lines don't bleed into rspec output. Specs that exercise logging
# swap +Pikuri.log_io+ to a +StringIO+ (see +capture_log+ below) or a
# +Shared::Log::CountingIO+ wired against a +Tuile::FakeScreen+. A per-example reset
# (see RSpec.configure) returns it here afterward, so an App spec that wires
# a now-dead FakeScreen into +Pikuri.log_io+ can't leak it into the next
# example's logger writes.
NULL_LOG = File.open(File::NULL, 'w')
Pikuri.log_io = NULL_LOG

RSpec.configure do |config|
  # Reset the shared pikuri log sink before each example so a prior example's
  # swap (esp. an App's screen-bound Shared::Log::CountingIO) never leaks across.
  config.before { Pikuri.log_io = NULL_LOG }

  config.include Minitest::Assertions
  config.include(Module.new do
    attr_writer :assertions

    def assertions
      @assertions ||= 0
    end
  end)

  # Capture pikuri log output for the duration of the block and return it as
  # a String. pikuri-tui logs through per-class LOG constants
  # (Pikuri.logger_for), never Tuile.logger, and Pikuri.log_io= rewires those
  # loggers in place — so redirecting the shared sink captures them. The
  # previous sink (NULL by default; see above) is restored after.
  config.include(Module.new do
    def capture_log
      sink = StringIO.new
      previous = Pikuri.log_io
      Pikuri.log_io = sink
      yield
      sink.string
    ensure
      Pikuri.log_io = previous
    end
  end)
end
