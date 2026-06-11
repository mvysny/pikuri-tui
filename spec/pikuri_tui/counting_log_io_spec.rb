# frozen_string_literal: true

RSpec.describe PikuriTui::CountingLogIO do
  let(:log_window) { Tuile::Component::LogWindow.new('Log') }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  it 'forwards each Logger-style write to the LogWindow (with the trailing newline stripped)' do
    io = described_class.new(log_window: log_window)
    logger = Logger.new(io)
    logger.info('hello')
    rendered = log_window.content.lines.map(&:to_s).join("\n")
    assert_includes rendered, 'INFO'
    assert_includes rendered, 'hello'
  end

  it 'invokes on_error for ERROR-class writes' do
    errors = []
    io = described_class.new(log_window: log_window, on_error: ->(line) { errors << line })
    logger = Logger.new(io)
    logger.error('boom')
    assert_equal 1, errors.size
    assert_includes errors.first, 'boom'
  end

  it 'invokes on_error for FATAL-class writes (same severity bracket as ERROR)' do
    errors = []
    io = described_class.new(log_window: log_window, on_error: ->(_line) { errors << :tick })
    logger = Logger.new(io)
    logger.fatal('worse')
    assert_equal [:tick], errors
  end

  it 'does not invoke on_error for INFO/DEBUG/WARN writes (UI badge only spikes on real errors)' do
    errors = []
    io = described_class.new(log_window: log_window, on_error: ->(_line) { errors << :tick })
    logger = Logger.new(io)
    logger.info('ok')
    logger.debug('detail')
    logger.warn('careful')
    assert_equal [], errors
  end

  it 'tolerates a raising on_error callback (logging must never crash the worker that called it)' do
    io = described_class.new(log_window: log_window, on_error: ->(_line) { raise 'callback bug' })
    logger = Logger.new(io)
    log = capture_log { logger.error('boom') }
    assert_includes log, 'CountingLogIO on_error callback raised'
  end

  it 'leaves on_error unset by default (no counting wired = silent)' do
    io = described_class.new(log_window: log_window)
    logger = Logger.new(io)
    logger.error('boom')
    # No assertion to make on the on_error path — proves no NoMethodError on nil.
    assert true
  end

  it 'provides a no-op #close so stdlib Logger treats it as a real IO target' do
    io = described_class.new(log_window: log_window)
    assert_respond_to io, :close
    io.close
  end
end
