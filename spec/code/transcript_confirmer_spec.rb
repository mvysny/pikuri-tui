# frozen_string_literal: true

RSpec.describe Code::TranscriptConfirmer do
  let(:screen)       { Tuile::Screen.instance }
  let(:conversation) { Shared::ConversationTextView.new }
  let(:status_rule)  { Shared::StatusRuleLabel.new(token_log: Pikuri::Agent::Listener::TokenLog.new) }
  let(:input)        { Shared::InputPane.new(on_submit: ->(_text) {}) }

  let(:confirmer) do
    described_class.new(screen: screen, conversation: conversation,
                        status_rule: status_rule, input: input)
  end

  before do
    fake_screen
    # Mounted for real: #finish hands focus back to the prompt, and
    # Screen#focused= refuses a component that isn't on this screen's tree.
    screen.content = Chat::Layout.new(conversation: conversation, status_rule: status_rule, input: input)
    input.focus
  end

  after { Tuile::Screen.close }

  def approved(detail) = Pikuri::Workspace::Confirmer::Approved.new(new_request_detail: detail)
  def rejected(reason = nil) = Pikuri::Workspace::Confirmer::Rejected.new(reason: reason)

  def request(question: 'OK to run this?', detail: nil, editable: false, change: nil)
    Pikuri::Workspace::Confirmer::Request.new(question: question, detail: detail,
                                              editable: editable, change: change)
  end

  def change(path: 'MACHINE.md', old: "one\ntwo\n", new: "one\nTWO\n")
    Pikuri::Workspace::Confirmer::Change.new(path: path, old: old, new: new)
  end

  # Run +ask+ (or +confirm?+) on a worker and answer it from the example thread
  # via the block (which calls #decide / #type), returning what it produced.
  def run(req, method: :ask, &block)
    result = nil
    worker = Thread.new { result = confirmer.public_send(method, request: req) }
    block&.call
    worker.join(2) || raise("#{method} never returned")
    result
  end

  # Wait for the question to land, then answer it with +key+ — sent to the
  # conversation pane, which is where a focused transcript receives it.
  def decide(key)
    wait_until { conversation.pending_decision }
    conversation.handle_key?(key)
  end

  # Type +text+ into the captured prompt and send it (+key:+ instead for the
  # ESC path).
  def type(text: nil, key: nil)
    wait_until { input.capturing? }
    if key
      input.area.handle_key?(key)
    else
      input.area.text = text if text
      input.area.handle_key?(Tuile::Keys::ENTER)
    end
  end

  # The transcript's rendered lines.
  def transcript_lines = conversation.text.to_s.split("\n")

  it 'is a Pikuri::Workspace::Confirmer (drops into the same tool slot as Terminal)' do
    assert_kind_of Pikuri::Workspace::Confirmer, confirmer
  end

  describe '#ask — non-editable (write / bash)' do
    it 'approves with the detail unchanged on y' do
      assert_equal approved('ls -la'), run(request(detail: 'ls -la')) { decide('y') }
    end

    it 'rejects with no reason on n' do
      assert_equal rejected, run(request) { decide('n') }
    end

    it 'rejects with a typed reason on r' do
      result = run(request) do
        decide('r')
        type(text: 'use the other library')
      end
      assert_equal rejected('use the other library'), result
    end

    it 'treats a blank reason as no reason' do
      result = run(request) do
        decide('r')
        type(text: '   ')
      end
      assert_equal rejected, result
    end

    it 'skips the reason (a bare decline) when the reason prompt is ESC-cancelled' do
      result = run(request) do
        decide('r')
        type(key: Tuile::Keys::ESC)
      end
      assert_equal rejected, result
    end

    it 'offers no edit path: e is inert on a non-editable request' do
      result = run(request) do
        decide('e') # ignored — the question stays parked
        assert conversation.pending_decision, 'e must not resolve a non-editable request'
        decide('n')
      end
      assert_equal rejected, result
    end
  end

  describe '#ask — editable (agent delegation)' do
    let(:editable) { request(detail: 'summarize CVEs', editable: true) }

    it 'approves the original task unchanged on y (clean task)' do
      assert_equal approved('summarize CVEs'), run(editable) { decide('y') }
    end

    it 'approves the human-edited task on e (author seat)' do
      result = run(editable) do
        decide('e')
        type(text: 'summarize openssl CVEs only')
      end
      assert_equal approved('summarize openssl CVEs only'), result
    end

    it 'pre-fills the prompt with the raw task when clean' do
      run(editable) do
        decide('e')
        wait_until { input.capturing? }
        assert_equal 'summarize CVEs', input.area.text
        input.area.handle_key?(Tuile::Keys::ENTER)
      end
    end

    it 'forces a retype on a flagged task: no pre-fill, and no bare-approve key' do
      flagged = request(detail: "do this\rand that", editable: true)
      run(flagged) do
        wait_until { conversation.pending_decision }
        cue = conversation.pending_decision.cue
        refute_includes cue, '(y)'
        assert_includes cue, '(e) edit'
        decide('e')
        wait_until { input.capturing? }
        assert_equal '', input.area.text
        input.area.handle_key?(Tuile::Keys::ENTER)
      end
    end

    it 'declines when the edit prompt is ESC-cancelled' do
      result = run(editable) do
        decide('e')
        type(key: Tuile::Keys::ESC)
      end
      assert_equal rejected, result
    end
  end

  describe '#confirm? — the derived boolean the mutation gates use' do
    it 'is true on approve' do
      assert_equal true, run(request, method: :confirm?) { decide('y') }
    end

    it 'is false on reject' do
      assert_equal false, run(request, method: :confirm?) { decide('n') }
    end
  end

  describe 'the transcript block' do
    it 'asks in the conversation pane, not in a popup' do
      run(request(detail: 'ls -la')) do
        wait_until { conversation.pending_decision }
        assert_empty screen.popups
        assert_includes transcript_lines, '⏵ OK to run this?'
        assert_includes transcript_lines, 'ls -la'
        decide('y')
      end
    end

    it 'spells out the keys on offer under the question' do
      run(request) do
        wait_until { conversation.pending_decision }
        assert_equal '(y) approve   (n) reject   (r) reject w/ reason',
                     conversation.pending_decision.cue
        decide('y')
      end
    end

    it 'keeps the question and records the outcome under it once answered' do
      run(request) { decide('n') }
      assert_includes transcript_lines, '⏵ OK to run this?'
      assert_includes transcript_lines, '· rejected'
      refute_includes transcript_lines.join("\n"), '(y) approve'
    end

    it 'records the steering reason it sent the model' do
      run(request) do
        decide('r')
        type(text: 'wrong directory')
      end
      assert_includes transcript_lines, '· rejected: wrong directory'
    end

    it 'diffs a write request so the user sees the change, not just the headline' do
      run(request(question: 'OK to edit MACHINE.md (1 occurrence)?', change: change)) do
        wait_until { conversation.pending_decision }
        assert_includes transcript_lines, '- two'
        assert_includes transcript_lines, '+ TWO'
        decide('y')
      end
    end

    it 'shows a new file as all-additions (old is nil on create)' do
      run(request(change: change(old: nil, new: "fresh\n"))) do
        wait_until { conversation.pending_decision }
        assert_includes transcript_lines, '+ fresh'
        decide('y')
      end
    end

    it 'diffs BINARY file bytes carrying non-ASCII (the tools hand back String#b)' do
      run(request(change: change(old: "café\n".b, new: "cafés\n".b))) do
        wait_until { conversation.pending_decision }
        assert_includes transcript_lines, '- café'
        assert_includes transcript_lines, '+ cafés'
        decide('y')
      end
    end

    it 'neutralizes control bytes and says why the content is suspicious' do
      run(request(detail: "echo hi\rrm -rf ~/")) do
        wait_until { conversation.pending_decision }
        body = transcript_lines.join("\n")
        refute_includes body, "\r"
        assert_includes body, '\\x0d'
        assert_includes body, 'Suspicious content detected'
        decide('n')
      end
    end
  end

  describe 'keystrokes it must not be able to steal' do
    it 'ignores decision keys typed at the prompt — they are text' do
      result = run(request) do
        wait_until { conversation.pending_decision }
        input.area.handle_key?('n')
        input.area.handle_key?('o')
        assert_equal 'no', input.area.text
        assert conversation.pending_decision, 'typing at the prompt must not answer a decision'
        decide('y')
      end
      assert_equal approved(nil), result
    end

    it 'hands focus back to the prompt once answered, so typing resumes' do
      run(request) do
        decide('y')
        wait_until { !conversation.pending_decision }
      end
      assert_same input.area, screen.focused
    end
  end

  describe 'staying answerable — #pending? / #reject_pending!' do
    it 'is not pending with nothing parked, and rejects nothing' do
      refute_predicate confirmer, :pending?
      assert_equal false, confirmer.reject_pending!
    end

    it 'declines the parked question (what Ctrl+C and quit call)' do
      result = run(request) do
        wait_until { confirmer.pending? }
        assert_equal true, confirmer.reject_pending!
      end
      assert_equal rejected, result
      refute_predicate confirmer, :pending?
    end

    it 'declines a question whose reason is still being typed' do
      result = run(request) do
        decide('r')
        wait_until { input.capturing? }
        assert_equal true, confirmer.reject_pending!
      end
      assert_equal rejected, result
      refute_predicate input, :capturing?
    end
  end

  describe 'the status rule badge' do
    it 'lights while parked and drops once answered' do
      run(request) do
        wait_until { conversation.pending_decision }
        assert_predicate status_rule, :decision_pending
        decide('y')
        wait_until { !conversation.pending_decision }
      end
      refute_predicate status_rule, :decision_pending
    end
  end
end
