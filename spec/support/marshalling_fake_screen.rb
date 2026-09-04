# frozen_string_literal: true

# A +Tuile::FakeScreen+ whose event queue marshals off-thread work the way a
# live event loop does, plus the +wait_until+ helper that drives it.
#
# Why this exists: Tuile confines the UI to one thread — the event loop's while
# a loop runs, the thread that created the screen when none does (tuile 0.10.0
# removed +FakeScreen+'s bypass of that check, so a spec now raises exactly
# where an app would). +Tuile::FakeEventQueue#submit+ runs its block *inline on
# the calling thread*, which is fine for the example thread but wrong for the
# threads production code legitimately spawns: +Shared::AgentSession+'s
# per-turn worker and the tool thread that blocks in
# +Code::TranscriptConfirmer#ask+ both submit UI work from off the UI thread, and
# inline execution there means +check_locked+ raises and the worker dies.
#
# {MarshallingEventQueue} closes that gap: an off-thread submit is queued
# instead of run, and the example thread drains it from {ThreadedUi#wait_until}
# — the manual equivalent of the real loop draining its queue. Submits from the
# UI thread itself still run inline (the stock fake's behavior), so specs that
# only press keys and assert need no pumping.
class MarshallingEventQueue < Tuile::FakeEventQueue
  def initialize
    super
    @ui_thread = Thread.current
    @pending = Queue.new
  end

  # Inline when called on the UI thread, queued for {#pump} otherwise.
  def submit(&block)
    return yield if Thread.current.equal?(@ui_thread)

    @pending << block
  end

  # Runs every block submitted from off the UI thread, in submission order.
  # Must be called on the UI thread (that's the whole point). A raise
  # propagates to the caller rather than going to +screen.on_error+ — under
  # test a broken render should fail the example, loudly.
  def pump
    @pending.pop(true).call until @pending.empty?
  end
end

# Screen used by specs that let production code run on a worker thread. Swaps
# in {MarshallingEventQueue}; everything else is the stock fake screen.
class MarshallingFakeScreen < Tuile::FakeScreen
  def initialize
    super
    @event_queue = MarshallingEventQueue.new
  end
end

# Mixed into every example (see spec_helper).
module ThreadedUi
  # Mounts a {MarshallingFakeScreen} as the +Tuile::Screen+ singleton. Drop-in
  # replacement for +Tuile::Screen.fake+ in specs that cross a thread.
  # @return [MarshallingFakeScreen]
  def fake_screen = MarshallingFakeScreen.new

  # Runs any UI work a worker submitted. No-op on a stock fake screen (or
  # before one exists), so it's safe to call from the shared {#wait_until}.
  def pump_ui
    queue = Tuile::Screen.instance.event_queue
    queue.pump if queue.respond_to?(:pump)
  rescue Tuile::Error
    nil # no screen mounted
  end

  # Drain pending UI work, then spin until the block yields truthy. The turn
  # lifecycle crosses a real worker thread (+Shared::AgentSession+'s per-turn
  # +Thread.new+, or the thread driving +Code::TranscriptConfirmer#ask+), so a spec
  # observing what the worker rendered must both pump and wait.
  def wait_until(timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      pump_ui
      break if yield
      raise 'timed out waiting for condition' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.005
    end
  end
end
