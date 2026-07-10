# frozen_string_literal: true

module Shared
  # The diagnostic-log subsystem shared by all three shells: the eager
  # +LogWindow+ wrapper and its popup ({Log::UI} / {Log::Popup}), plus the
  # +IO+-shaped sinks that route every pikuri / Tuile log line into that
  # window — {Log::CountingIO} (live, counting error-class writes for the
  # +Ctrl+K+ hint) and {Log::BufferingIO} (the boot-time sink that retains
  # pre-screen lines for replay once the window exists).
  module Log
  end
end
