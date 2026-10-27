# frozen_string_literal: true

RSpec.describe Shared::Log::UI do
  let(:screen) { Tuile::Screen.instance }
  let(:status_bar) { Shared::StatusBar.new }
  let(:log_ui) { described_class.new(screen: screen, status_bar: status_bar) }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  # Shared::Log::UI owns only the bar's :menu segment; nothing else writes here.
  def status_bar_text
    Tuile::Testing.loop
    status_bar.text.to_s
  end

  # Install the Ctrl+K shortcut (App's register_shortcuts seam) and wire the
  # counting sink so Tuile.logger routes through the Shared::Log::UI's Shared::Log::CountingIO.
  def boot(&open_menu)
    log_ui.wire!
    log_ui.install_shortcut(&(open_menu || -> {}))
    log_ui
  end

  it 'eager-constructs the diagnostic LogDialog' do
    assert_kind_of Shared::Log::Dialog, log_ui.log_dialog
  end

  it 'advertises a discoverable "^K menu" hint with no errors and no warning glyph' do
    boot
    assert_includes status_bar_text, '^K menu'
    refute_includes status_bar_text, '⚠'
  end

  it 'routes an error logged through Tuile.logger into "^K ⚠ menu (N)"' do
    boot
    Tuile.logger.error('boom')
    assert_includes status_bar_text, '^K ⚠ menu (1)'
  end

  it 'bumps the tally once per error line, not per log line' do
    boot
    Tuile.logger.error('one')
    Tuile.logger.info('two')   # info shouldn't bump
    Tuile.logger.warn('three') # warn shouldn't bump either
    Tuile.logger.fatal('four') # fatal does (same bracket as error)
    assert_includes status_bar_text, '^K ⚠ menu (2)'
  end

  it 'clears the tally when the log popup is dismissed (diagnostics now read)' do
    boot
    Tuile.logger.error('boom')
    assert_includes status_bar_text, '^K ⚠ menu (1)'

    log_ui.open
    log_ui.log_dialog.close
    assert_includes status_bar_text, '^K menu'
    refute_includes status_bar_text, '⚠'
  end

  it 'Ctrl+K fires the supplied open-menu action' do
    opened = false
    boot { opened = true }
    screen.key(Tuile::Keys::CTRL_K)
    assert opened, 'expected the Ctrl+K action to run the supplied block'
  end

  it '#open opens the popup and is a no-op when already open' do
    boot
    log_ui.open
    assert log_ui.log_dialog.open?
    log_ui.open # second call must not raise or re-open
    assert log_ui.log_dialog.open?
  end

  it 'replays a Shared::Log::BufferingIO boot sink into the LogDialog on wire!' do
    prior = Shared::Log::BufferingIO.new(passthrough: StringIO.new)
    Logger.new(prior).info('pre-screen line')
    Pikuri.log_io = prior

    log_ui.wire!
    Tuile::Testing.loop
    assert_includes log_ui.log_dialog.content.text.to_s, 'pre-screen line'
  end
end
