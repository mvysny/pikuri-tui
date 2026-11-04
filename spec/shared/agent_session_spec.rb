# frozen_string_literal: true

require 'logger'
require 'stringio'

RSpec.describe Shared::AgentSession do
  # Minimal +Pikuri::Agent+ stand-in: the session only reaches for
  # +run_loop+ (from the worker thread), +cancellable+ (from {#interrupt}),
  # +interloper+ (mid-turn queueing) and +clear_conversation+.
  #
  # +run_loop+ records each +user_message:+ / +attachments:+ / +transport:+; after
  # {#block_turns!} it additionally parks on an internal queue until the
  # spec calls {#finish_turn!}, so a spec can hold a turn open and observe
  # the mid-turn paths.
  class TurnAgentStub
    attr_reader :cancellable, :interloper, :messages, :attachments, :transports, :clear_count, :drained
    attr_accessor :modalities

    def transport = Pikuri::Agent::ChatTransport.new(model: 'running', provider: :openai)

    def initialize(interloper: Pikuri::Agent::Control::Interloper.new)
      @cancellable = Pikuri::Agent::Control::Cancellable.new
      @interloper = interloper
      @messages = []
      @attachments = []
      @transports = []
      @drained = []
      @clear_count = 0
      @gate = Queue.new
      @blocking = false
    end

    def block_turns! = @blocking = true

    def finish_turn! = @gate << :done

    # Make the next +run_loop+ raise {Pikuri::Agent::EmptyTurnError} (a bare turn
    # on a system-hoisting provider), still recording the +user_message+ first.
    def raise_empty_turn!(provider = 'anthropic') = @empty_turn_provider = provider

    def clear_conversation = @clear_count += 1

    def run_loop(user_message:, attachments: [], transport: nil)
      @messages << user_message
      @attachments << attachments
      @transports << transport
      # Mirror the real agent draining its interloper at turn start, so a
      # re-injected :system leftover is consumed here (recorded for specs)
      # instead of looping back into another delivery turn.
      @drained.concat(@interloper&.drain! || [])
      raise Pikuri::Agent::EmptyTurnError, @empty_turn_provider if @empty_turn_provider

      @gate.pop if @blocking
    end
  end

  # Records the error / notice verbs the session drives on the transcript, so a
  # spec can assert the coordinator poked it without standing up the real
  # {Shared::ConversationTextView} (markdown, streaming buffers, regions).
  class FakeConversation
    attr_reader :errors, :notices

    def initialize
      @errors = []
      @notices = []
    end

    def render_turn_error(exception) = @errors << exception
    def render_notice(text) = @notices << text
  end

  # The other half of what the session drives: the status rule's spinner.
  class FakeStatusRule
    attr_reader :animation

    def initialize = @animation = []

    def start_animation = @animation << :start
    def stop_animation = @animation << :stop
  end

  # A one-shot pending-switch source: hands out +pending+ in order, then
  # +nil+ — the surface the session uses ({#take_pending}, {#pending}).
  class FakePicker
    def initialize(pending: [])
      @pending = pending.dup
    end

    def pending = @pending.first
    def take_pending = @pending.shift
  end

  let(:agent) { TurnAgentStub.new }
  let(:conversation) { FakeConversation.new }
  let(:status_rule) { FakeStatusRule.new }
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
    assert_equal [:start], status_rule.animation
  ensure
    agent.finish_turn!
    wait_until { status_rule.animation == %i[start stop] }
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
    assert_equal ['second'], agent.interloper.peek.map(&:content)
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

  describe 'attachments' do
    let(:png) { Pikuri::Attachment.new(mime: 'image/png', filename: 'a.png', bytes: "\x89PNG\r\n\x1a\n") }
    let(:gif) { Pikuri::Attachment.new(mime: 'image/gif', filename: 'b.gif', bytes: 'GIF89a') }

    it "reports the model's refusal on the UI thread, not as a turn error" do
      refused = []
      session.on_attachment_refused { |reason| refused << [reason, Thread.current] }
      error = Pikuri::Agent::UnsupportedAttachmentError.new(png, 'model m takes no vision input')
      agent.define_singleton_method(:run_loop) { |**| raise error }
      session.submit('look', attachments: [png])
      wait_until { !session.turn_in_progress? }
      assert_equal [['a.png (image/png): model m takes no vision input', Thread.current]], refused
      assert_empty conversation.errors
    end

    describe '#attachment_refusal' do
      def transport(model, modalities) = Pikuri::Agent::ChatTransport.new(model: model, provider: :openai,
                                                                          modalities: modalities)

      it "refuses an image to a model reported blind, in run_loop's words" do
        agent.modalities = { vision: false }
        assert_equal 'a.png (image/png): model running takes no vision input', session.attachment_refusal([png])
      end

      it 'lets it through while vision is unknown or reported' do
        [nil, {}, { audio: false }, { vision: true }].each do |modalities|
          agent.modalities = modalities
          assert_nil session.attachment_refusal([png]), modalities.inspect
        end
      end

      it 'asks nothing without an image' do
        agent.modalities = { vision: false }
        assert_nil session.attachment_refusal([])
      end

      it "answers for a pending switch's model between turns" do
        agent.modalities = { vision: true }
        session = new_session(picker: FakePicker.new(pending: [transport('blind', { vision: false })]))
        assert_equal 'a.png (image/png): model blind takes no vision input', session.attachment_refusal([png])
      end

      it 'stands down while the pending switch is still being looked up' do
        agent.modalities = { vision: false }
        session = new_session(picker: FakePicker.new(pending: [transport('new', nil)]))
        assert_nil session.attachment_refusal([png])
      end

      it 'answers for the running model mid-turn, a pending switch notwithstanding' do
        agent.block_turns!
        agent.modalities = { vision: false }
        session = new_session(picker: FakePicker.new(pending: [nil, transport('sighted', { vision: true })]))
        session.submit('first')
        wait_until { agent.messages.size == 1 }
        assert_equal 'a.png (image/png): model running takes no vision input', session.attachment_refusal([png])
      ensure
        agent.finish_turn!
        wait_until { !session.turn_in_progress? }
      end
    end

    it 'hands them to run_loop with the message' do
      session.submit('look', attachments: [png])
      wait_until { agent.attachments == [[png]] }
      wait_until { !session.turn_in_progress? }
    end

    it 'queues a mid-turn submission with its attachments, even an attachment-only one' do
      agent.block_turns!
      session.submit('first')
      wait_until { agent.messages.size == 1 }

      session.submit('', attachments: [png])
      assert_equal [[png]], agent.interloper.peek.map(&:attachments)
    ensure
      2.times { agent.finish_turn! }
      wait_until { agent.messages.size == 2 && !session.turn_in_progress? }
    end

    it 'keeps leftover attachments when the leftovers become a fresh turn' do
      agent.block_turns!
      session.submit('first')
      wait_until { agent.messages.size == 1 }

      session.submit('this', attachments: [png])
      session.submit('and this', attachments: [gif])
      agent.finish_turn!
      wait_until { agent.messages.size == 2 }
      assert_equal [[], [png, gif]], agent.attachments
    ensure
      agent.finish_turn!
      wait_until { !session.turn_in_progress? }
    end
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

  describe 'blank submit (a skill bare-load)' do
    it 'runs a bare turn when idle' do
      session.submit('')
      wait_until { agent.messages == [''] }
      wait_until { !session.turn_in_progress? }
    end

    it 'is a no-op while a turn is running (the scheduled skill already rides it)' do
      agent.block_turns!
      session.submit('first')
      wait_until { agent.messages.size == 1 }

      session.submit('')
      session.submit('   ')
      assert_empty agent.interloper.peek, 'a blank mid-turn submit must not queue anything'
    ensure
      agent.finish_turn!
      wait_until { !session.turn_in_progress? }
    end

    it 'renders a dim notice (not an error) when the bare turn raises EmptyTurnError' do
      agent.raise_empty_turn!
      session.submit('')
      wait_until { !session.turn_in_progress? }

      assert_equal 1, conversation.notices.size
      assert_empty conversation.errors, 'EmptyTurnError must not red-line as a turn failure'
    end
  end

  it 're-injects a leftover :system item as system context instead of folding it into a user turn' do
    agent.block_turns!
    session.submit('first')
    wait_until { agent.messages.size == 1 }

    agent.interloper.inject_system_message('<skill>x</skill>') # a skill scheduled mid-turn, never drained
    session.submit('a user correction')                        # plus a user leftover
    agent.finish_turn!
    wait_until { agent.messages.size == 2 }

    # the user leftover is the fresh turn's message, clean (not the Item struct)...
    assert_equal 'a user correction', agent.messages.last
    # ...and the system leftover rode the queue into that turn's run_loop as :system.
    assert_equal([[:system, '<skill>x</skill>']], agent.drained.map { |i| [i.kind, i.content] })
  ensure
    agent.finish_turn!
    wait_until { !session.turn_in_progress? }
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
      screen: screen, conversation: conversation, status_rule: status_rule,
      model_picker: picker, logger: logger
    ).tap { |s| s.agent = agent }
  end

  def transport(model:)
    Pikuri::Agent::ChatTransport.new(
      model: model, provider: :openai, assume_model_exists: true,
      api_base: 'http://x/v1', api_key: 'k'
    )
  end
end
