# frozen_string_literal: true

# SimpleCov first, so loading lib/ is measured; the report lands in coverage/.
require 'simplecov'
SimpleCov.start do
  enable_coverage :branch
  add_filter '/spec/'
end

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

# Disable ANSI colorisation in +Shared::Markdown::AnsiConverter+
# for the suite. Spec assertions about Markdown output target *structure*
# — bullet markers, blank-line placement, table-separator rewriting —
# not the surrounding ANSI styling. Specs that *are* about styling
# (ansi_converter_spec.rb) re-enable color per render.
ENV['NO_COLOR'] = '1'

require 'rspec/core'
require 'stringio'

require 'pikuri-core'
require 'pikuri-pdf'     # default dep; every App registers Extractors::PDF
require 'pikuri-web'
require 'pikuri-conversations'
require 'pikuri/testing' # scripted-HTTP fake LLM (Pikuri::Testing.fake_transport)

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

# wait_until, for the specs that let production code run on a
# worker thread (App turns, the confirmer's blocking #ask).
require_relative 'support/wait_until'

# ToolCall / ToolResult fixture builders (both events carry display strings a
# tool composes, which most fixtures don't want to spell out).
require_relative 'support/tool_events'

# +paint+ / +painted_region+ — one component painted through its own
# Tuile::Canvas, for the specs that read rows back off the buffer.
require_relative 'support/paint_one'

# +wait_until_idle+ / +booted_agent+, and the shutdown of every App's
# conversation after each example.
require_relative 'support/conversations'
[Chat::App, Code::App, Computer::App].each { |app| app.prepend(ConversationApps::Tracked) }
Tuile::Screen.singleton_class.prepend(ConversationApps::ClosesWithScreen)

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

  # Shared::RequestPermits.install writes a process-global registry, and an App
  # spec calls it on every build — so one example's [[server]] ceiling would
  # ration another's server. The probe's answers are process-global too.
  config.after do
    Pikuri::Conversations::Throttle.reset!
    Pikuri::Conversations::Probe.reset!
  end

  # A conversation asks its server about the model — /v1/models at boot, /props
  # at a turn's start — and a fake transport's server does not exist. Every
  # example gets "the server told nothing", which leaves a fake transport's
  # stated cap and modalities in charge. A spec about the probe stubs over this.
  config.before do
    detector = Pikuri::Conversations::Probe::Detector
    detector.define_singleton_method(:detect) { |*, **| detector::Props::NONE }
    detector.define_singleton_method(:detect_modalities) { |*, **| nil }
  end

  # Minitest's assert_* in every example, with the assertion counter they need.
  config.expect_with :minitest
  config.include ThreadedUi
  config.include ToolEvents
  config.include PaintOne
  config.include ConversationApps
  config.after { ConversationApps.close_all }

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
