# frozen_string_literal: true

# The +wait_until+ helper for specs that let production code run on a real
# worker thread.
#
# +Tuile::FakeEventQueue+ queues every +submit+, from any thread, and runs
# nothing until the spec plays a loop turn with +Tuile::Testing.loop+ — so a
# worker's UI hand-off (a conversation's turn thread, the tool
# thread parked in +Code::TranscriptConfirmer#ask+) lands on the example thread,
# as it would on the event loop's. What a spec cannot know is *when* the worker
# has submitted; +wait_until+ keeps playing turns until the effect shows.
#
# Mixed into every example (see spec_helper).
module ThreadedUi
  # Play loop turns, then spin until the block yields truthy. A spec observing
  # what a worker rendered must both drain and wait.
  def wait_until(timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      Tuile::Testing.loop if Tuile::Screen.instance?
      break if yield
      raise 'timed out waiting for condition' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.005
    end
  end
end
