# frozen_string_literal: true

require 'logger'
require 'stringio'

RSpec.describe Shared::AgentSession do
  # Minimal +Pikuri::Agent+ stand-in: the session only reaches for
  # +run_loop+ (from the worker thread), +cancellable+ (from {#interrupt}),
  # +interloper+ (mid-turn queueing) and +clear_conversation+.
  #
  # +run_loop+ records each +user_message:+ / +transport:+; after
  # {#block_turns!} it additionally parks on an internal queue until the
  # spec calls {#finish_turn!}, so a spec can hold a turn open and observe
  # the mid-turn paths.
  class TurnAgentStub
    attr_reader :cancellable, :interloper, :messages, :transports, :clear_count

    def initialize(interloper: Pikuri::Agent::Control::Interloper.new)
      @cancellable = Pikuri::Agent::Control::Cancellable.new
      @interloper = interloper
      @messages = []
      @transports = []
      @clear_count = 0
      @gate = Queue.new
      @blocking = false
    end

    def block_turns! = @blocking = true

    def finish_turn! = @gate << :done

    def clear_conversation = @clear_count += 1

    def run_loop(user_message:, transport: nil)
      @messages << user_message
      @transports << transport
      @gate.pop if @blocking
    end
  end

  # Records the spinner / error verbs the session drives, so a spec can
  # assert the coordinator poked the conversation window without standing up
  # the real {Shared::ConversationWindow} (token log, markdown, panes).
  class FakeConversationWindow
    attr_reader :animation, :errors

    def initialize
      @animation = []
      @errors = []
    end

    def start_animation = @animation << :start
    def stop_animation = @animation << :stop
    def render_turn_error(exception) = @errors << exception
  end

  # A one-shot pending-switch source: hands out +pending+ in order, then
  # +nil+ — the only surface the session uses ({#take_pending}).
  class FakePicker
    def initialize(pending: [])
      @pending = pending.dup
    end

    def take_pending = @pending.shift
  end

  let(:agent) { TurnAgentStub.new }
  let(:conversation_window) { FakeConversationWindow.new }
  let(:picker) { FakePicker.new }
  let(:log_io) { StringIO.new }
  let(:logger) { Logger.new(log_io) }

  subject(:session) { new_session }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  it 'runs the submitted message through the agent loop' do
    session.submit('hello')
    wait_until { agent.messages == ['hello'] }
    wait_until { !session.turn_in_progress? }
  end

  it 'drives the conversation spinner: start on submit, stop when the turn ends' do
    agent.block_turns!
    session.submit('work')
    wait_until { agent.messages.size == 1 }
    assert_equal [:start], conversation_window.animation
  ensure
    agent.finish_turn!
    wait_until { conversation_window.animation == %i[start stop] }
  end

  it 'reports turn_in_progress? true while a turn runs, false once it settles' do
    agent.block_turns!
    session.submit('work')
    wait_until { agent.messages.size == 1 }
    assert session.turn_in_progress?
  ensure
    agent.finish_turn!
    wait_until { !session.turn_in_progress? }
  end

  it 'queues a mid-turn submission into the interloper instead of a second run_loop' do
    agent.block_turns!
    session.submit('first')
    wait_until { agent.messages.size == 1 }

    session.submit('second')
    assert_equal ['second'], agent.interloper.peek
    assert_equal ['first'], agent.messages
  ensure
    # One release for the held turn, one for the leftover-delivery turn.
    2.times { agent.finish_turn! }
    wait_until { agent.messages.size == 2 && !session.turn_in_progress? }
  end

  it 'delivers injections still queued when the turn ends as a fresh turn (in order)' do
    agent.block_turns!
    session.submit('first')
    wait_until { agent.messages.size == 1 }

    session.submit('queued while busy')
    agent.finish_turn!
    wait_until { agent.messages.size == 2 }
    assert_equal ['first', 'queued while busy'], agent.messages
    assert_empty agent.interloper.peek
  ensure
    agent.finish_turn! # release the leftover-delivery turn
    wait_until { !session.turn_in_progress? }
  end

  it 'joins multiple leftover injections into one delivery turn, in submission order' do
    agent.block_turns!
    session.submit('first')
    wait_until { agent.messages.size == 1 }

    session.submit('also this')
    session.submit('and this')
    agent.finish_turn!
    wait_until { agent.messages.size == 2 }
    assert_equal ['first', "also this\n\nand this"], agent.messages
  ensure
    agent.finish_turn! # release the leftover-delivery turn
    wait_until { !session.turn_in_progress? }
  end

  it 'drops a mid-turn submission with a warn when the agent has no interloper wired' do
    no_interloper = TurnAgentStub.new(interloper: nil)
    no_interloper.block_turns!
    session = new_session(agent: no_interloper)
    session.submit('first')
    wait_until { no_interloper.messages.size == 1 }

    session.submit('second')
    no_interloper.finish_turn!
    wait_until { !session.turn_in_progress? }
    assert_equal ['first'], no_interloper.messages
    assert_includes log_io.string, 'mid-turn message dropped'
  end

  describe '#clear_conversation' do
    it "kicks the agent's clear_conversation when idle" do
      session.clear_conversation
      assert_equal 1, agent.clear_count
    end

    it 'is a no-op (logged) while a turn is running' do
      agent.block_turns!
      session.submit('work')
      wait_until { agent.messages.size == 1 }

      session.clear_conversation
      assert_equal 0, agent.clear_count
      assert_includes log_io.string, 'clear conversation ignored'
    ensure
      agent.finish_turn!
      wait_until { !session.turn_in_progress? }
    end
  end

  describe '#interrupt' do
    it 'cancels the in-flight turn when a turn is running' do
      agent.block_turns!
      session.submit('work')
      wait_until { agent.messages.size == 1 }

      session.interrupt
      assert agent.cancellable.cancelled?
    ensure
      agent.finish_turn!
      wait_until { !session.turn_in_progress? }
    end

    it 'drops focus when idle and something is focused (first press)' do
      area = Tuile::Component::TextArea.new
      screen.content = area
      screen.focused = area
      refute_nil screen.focused

      session.interrupt
      assert_nil screen.focused
    end

    it 'stops the event loop when idle and nothing is focused (second press)' do
      screen.focused = nil
      stopped = false
      screen.event_queue.define_singleton_method(:stop) { stopped = true }

      session.interrupt
      assert stopped, 'expected the event loop to be stopped'
    end
  end

  it 'consumes the picker pending switch once, passing it to the next run_loop then clearing it' do
    switched = transport(model: 'other')
    session = new_session(picker: FakePicker.new(pending: [switched]))

    session.submit('go')
    wait_until { agent.messages.size == 1 }
    assert_equal switched, agent.transports[0]

    session.submit('again')
    wait_until { agent.messages.size == 2 }
    assert_nil agent.transports[1], 'a switch must apply at most once'
  ensure
    wait_until { !session.turn_in_progress? }
  end

  private

  def screen = Tuile::Screen.instance

  def new_session(agent: self.agent, picker: self.picker)
    Shared::AgentSession.new(
      screen: screen, conversation_window: conversation_window,
      model_picker: picker, logger: logger
    ).tap { |s| s.agent = agent }
  end

  def transport(model:)
    Pikuri::Agent::ChatTransport.new(
      model: model, provider: :openai, assume_model_exists: true,
      api_base: 'http://x/v1', api_key: 'k'
    )
  end

  # Spin until the block yields truthy. The turn lifecycle crosses a real
  # worker thread (AgentSession's per-turn Thread.new) even under FakeScreen
  # — the fake event queue runs submits inline on whichever thread calls
  # them — so specs that observe post-turn state must wait for the worker.
  def wait_until(timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise 'timed out waiting for condition' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.005
    end
  end
end
