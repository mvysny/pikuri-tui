# frozen_string_literal: true

RSpec.describe Shared::Log::BufferingIO do
  let(:passthrough) { StringIO.new }
  let(:sink) { StringIO.new }

  it 'tees every write to the passthrough stream immediately' do
    io = described_class.new(passthrough: passthrough)
    logger = Logger.new(io)
    logger.info('boot line')
    assert_includes passthrough.string, 'boot line'
  end

  it 'replays buffered lines through the sink in order' do
    io = described_class.new(passthrough: passthrough)
    logger = Logger.new(io)
    logger.info('first')
    logger.warn('second')
    io.replay_into(sink)
    assert_operator sink.string.index('first'), :<, sink.string.index('second')
  end

  it 'replays into a Shared::Log::CountingIO so a buffered error still renders and counts' do
    Tuile::Screen.fake
    log_window = Tuile::Component::LogWindow.new('Log')
    errors = []
    counting = Shared::Log::CountingIO.new(log_window: log_window, on_error: ->(line) { errors << line })

    io = described_class.new(passthrough: passthrough)
    Logger.new(io).error('boot boom')
    io.replay_into(counting)

    rendered = log_window.content.text.to_s
    assert_includes rendered, 'boot boom'
    assert_equal 1, errors.size
    assert_includes errors.first, 'boot boom'
  ensure
    Tuile::Screen.close
  end

  it 'clears the buffer after replay so a second replay is a no-op' do
    io = described_class.new(passthrough: passthrough)
    Logger.new(io).info('once')
    io.replay_into(sink)
    sink.truncate(0)
    sink.rewind
    io.replay_into(sink)
    assert_empty sink.string
  end

  it 'drops the oldest lines past the cap and notes the drop on replay' do
    io = described_class.new(passthrough: passthrough, limit: 2)
    logger = Logger.new(io)
    logger.info('first')
    logger.info('second')
    logger.info('aaa') # evicts the first line
    io.replay_into(sink)
    refute_includes sink.string, 'first'
    assert_includes sink.string, '1 earlier boot log line(s) dropped'
    assert_includes sink.string, 'second'
    assert_includes sink.string, 'aaa'
  end

  it 'does not emit a dropped-lines notice when nothing was evicted' do
    io = described_class.new(passthrough: passthrough)
    Logger.new(io).info('only')
    io.replay_into(sink)
    refute_includes sink.string, 'dropped'
  end

  it 'provides a no-op #close that never closes the passthrough' do
    io = described_class.new(passthrough: passthrough)
    io.close
    refute passthrough.closed?
  end
end
