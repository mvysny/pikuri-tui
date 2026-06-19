# frozen_string_literal: true

require 'tuile'

module PikuriTui
  # +IO+-shaped sink for stdlib +Logger+ that forwards every line to a
  # {Tuile::Component::LogWindow} (same contract as
  # +Tuile::Component::LogWindow::IO+) *and* counts severity-+ERROR+ and
  # +FATAL+ writes so the +Ctrl+L+ status-bar hint can advertise
  # "press Ctrl+L, something broke."
  #
  # == How the severity is detected
  #
  # Stdlib +Logger+'s default formatter prefixes each line with a single
  # severity letter and a comma: +"D, "+ / +"I, "+ / +"W, "+ / +"E, "+ /
  # +"F, "+. We sniff that prefix on +#write+ to decide whether a line is
  # error-class. This couples us to the default formatter — if pikuri or
  # +Tuile.logger+ ever swaps in a custom one (e.g. +TTY::Logger+) the
  # counter goes dark while the lines still render. Acceptable: it's a UI
  # hint, not a correctness signal, and pikuri-tui controls both logger
  # constructions in {ChatApp}.
  #
  # == Threading
  #
  # +#write+ and +#puts+ are called from arbitrary threads (stdlib +Logger+
  # writes synchronously on the thread that invoked +#error+, which may be
  # the agent's worker thread or any background thread). Both methods
  # forward to {Tuile::Component::LogWindow} via +event_queue.submit+, so
  # the actual UI mutation lands on the event-loop thread. The on-error
  # callback is invoked synchronously on the caller's thread and is
  # responsible for marshaling its own UI work back.
  class CountingLogIO
    # Default-formatter prefixes that mark a write as error-class. +ERROR+
    # is +"E,"+; +FATAL+ is +"F,"+. Frozen so prefix comparisons stay
    # cheap.
    #
    # @return [Array<String>]
    ERROR_PREFIXES = ['E,', 'F,'].freeze

    # Re-enters this object's #write once Pikuri.log_io is wired here; safe
    # because the only line we emit is warn-class, so it can't re-trigger
    # #bump_error_count.
    LOG = Pikuri.logger_for('log')
    private_constant :LOG

    # @param log_window [Tuile::Component::LogWindow] the diagnostic window
    #   that receives every line, regardless of severity. Same role as the
    #   +window+ argument to +Tuile::Component::LogWindow::IO.new+.
    # @param on_error [Proc, Method, nil] one-arg callable invoked on each
    #   error-class write. Receives the (un-chomped) line so the callback
    #   can inspect it if it wants; pikuri-tui's wiring ignores the
    #   argument and just bumps a counter. +nil+ disables counting.
    def initialize(log_window:, on_error: nil)
      @log_window = log_window
      @on_error = on_error
      @log_file = File.open(Pikuri::Paths.state.join('pikuri.log'), 'w')
    end

    # @return [Tuile::Component::LogWindow] the destination window.
    attr_reader :log_window

    # +Logger+'s +write+ path: receives a fully formatted line. We strip
    # the trailing newline for the +LogWindow+'s row-oriented model (one
    # entry == one row) and forward.
    #
    # @param string [String] formatted log line, typically terminated by
    #   +"\n"+
    # @return [void]
    def write(string)
      @log_file.write(string)
      @log_file.flush
      bump_error_count(string) if ERROR_PREFIXES.any? { |p| string.start_with?(p) }
      @log_window.log(string.chomp)
    end

    # +TTY::Logger+'s +puts+ path; included for parity with
    # +Tuile::Component::LogWindow::IO+ even though pikuri-tui doesn't
    # currently wire any +puts+-shaped logger. No severity sniffing here —
    # +puts+-mode loggers don't follow the stdlib +Logger+ format.
    #
    # @param string [String] log line; the +LogWindow+ adds no extra
    #   newline so callers should not include one
    # @return [void]
    def puts(string)
      @log_file.puts(string)
      @log_file.flush
      @log_window.log(string)
    end

    # Stdlib +Logger+ treats an object as an IO target only when it
    # responds to both +#write+ and +#close+; otherwise it tries to
    # interpret it as a filename. No-op.
    #
    # @return [void]
    def close
      @log_file.close
    end

    private

    # Invoke the error callback, guarded against caller misbehavior. A
    # raise from a logger callback would tear down whatever thread was
    # logging — typically the agent's worker — which is far worse than
    # losing an error tick.
    #
    # @param string [String] the offending log line
    # @return [void]
    def bump_error_count(string)
      @on_error&.call(string)
    rescue StandardError => e
      LOG.warn(
        "CountingLogIO on_error callback raised (#{e.class}: #{e.message}); " \
        'error count may be stale'
      )
    end
  end
end
