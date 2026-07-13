# frozen_string_literal: true

# +IO+-shaped sink that tees boot-time log lines to a passthrough stream
# (+$stderr+) *and* remembers them, so they can be replayed into the
# diagnostic {Tuile::Component::LogWindow} once it exists.
#
# == Why this exists
#
# +Pikuri.log_io+ defaults to +$stderr+, and each bin's +App+ later swaps
# it to a {Shared::Log::CountingIO} feeding the +LogWindow+. +Pikuri.log_io=+ rewires
# already-handed-out loggers in place, so *future* lines follow to the
# pane — but lines emitted *before* the swap (config-file reads,
# +chmod 600+ advisories, model wiring) only ever hit +$stderr+, which is
# invisible for the whole session once +Tuile::Screen+ takes the alternate
# screen buffer. Installing this as the boot-time +Pikuri.log_io+ keeps the
# live +$stderr+ output (so a crash before the screen still prints) while
# capturing every line for a one-shot {#replay_into} at handover.
#
# == Replay contract
#
# {#replay_into} re-feeds the buffered lines through the new sink's +#write+
# (the {Shared::Log::CountingIO}), so a buffered error line both renders in the pane
# and bumps the +Ctrl+K+ menu "something broke" counter, exactly as a live error
# would. The buffered strings are the stdlib +Logger+-formatted lines
# (severity prefix + trailing newline), so +Shared::Log::CountingIO+'s severity
# sniffing and newline chomping work unchanged. +#puts+-origin lines (no
# stdlib logger wires one today) replay through +#write+ too; the cosmetic
# difference of a chomped trailing newline is acceptable.
#
# == Thread-safety
#
# Thread-safe: writes are +Mutex+-guarded, so even a stray background
# write can't corrupt the buffer (boot is effectively single-threaded —
# every logger reaching this object runs on the main thread before any
# worker starts — but the lock makes the guarantee unconditional).
# {#replay_into} delegates marshaling to the {Shared::Log::CountingIO} sink
# (which submits each line to the UI thread) rather than touching the
# +LogWindow+ directly.
class Shared::Log::BufferingIO
  # Default cap on retained lines. Boot volume is a handful of lines; the
  # cap is a backstop against an unexpected pre-screen log loop, not a tuning
  # knob. Oldest lines drop first and {#replay_into} notes the drop.
  #
  # @return [Integer]
  DEFAULT_LIMIT = 1000

  # @param passthrough [#write] stream every line is written to live,
  #   immediately. Defaults to +$stderr+ (pikuri's own default sink), so the
  #   pre-screen lifecycle is unchanged from a bare +Pikuri.log_io = $stderr+.
  # @param limit [Integer] maximum retained lines; oldest drop past it.
  def initialize(passthrough: $stderr, limit: DEFAULT_LIMIT)
    @passthrough = passthrough
    @limit = limit
    @buffer = []
    @dropped = 0
    @mutex = Mutex.new
  end

  # Stdlib +Logger+'s write path: tee to the passthrough and retain.
  #
  # @param string [String] formatted log line (severity prefix + newline).
  # @return [void]
  def write(string)
    @passthrough.write(string)
    @mutex.synchronize { retain(string) }
  end

  # +TTY::Logger+'s +puts+ path; kept for parity with {Shared::Log::CountingIO}.
  # No stdlib logger wires this, but retain the line so a stray +puts+
  # still survives to replay.
  #
  # @param string [String] log line (no trailing newline expected).
  # @return [void]
  def puts(string)
    @passthrough.puts(string)
    @mutex.synchronize { retain(string) }
  end

  # Stdlib +Logger+ treats an object as an IO target only when it responds
  # to both +#write+ and +#close+. Never closes the passthrough — +$stderr+
  # outlives this object.
  #
  # @return [void]
  def close; end

  # Replay every buffered line through +sink+, then clear the buffer so a
  # second call is a no-op. Called once at handover, after +Pikuri.log_io+
  # has already been pointed at +sink+, so no live line is lost in between.
  #
  # @param sink [#write] the new log sink (a {Shared::Log::CountingIO}); each buffered
  #   line is re-fed through its +#write+ so it renders and counts like a
  #   live line.
  # @return [void]
  def replay_into(sink)
    lines, dropped = @mutex.synchronize { drain }
    sink.write(dropped_notice(dropped)) if dropped.positive?
    lines.each { |line| sink.write(line) }
  end

  private

  # Append a line, evicting the oldest (and counting it) past the cap.
  # @return [void]
  def retain(string)
    @buffer << string
    while @buffer.size > @limit
      @buffer.shift
      @dropped += 1
    end
  end

  # @return [Array(Array<String>, Integer)] the retained lines and the
  #   dropped count, resetting both.
  def drain
    lines = @buffer
    dropped = @dropped
    @buffer = []
    @dropped = 0
    [lines, dropped]
  end

  # A warn-class line (so it renders but never bumps the error counter)
  # standing in for the lines evicted past the cap before the pane opened.
  # @param dropped [Integer] number of evicted lines.
  # @return [String]
  def dropped_notice(dropped)
    "W, [buffering] #{dropped} earlier boot log line(s) dropped before the diagnostic pane opened\n"
  end
end
