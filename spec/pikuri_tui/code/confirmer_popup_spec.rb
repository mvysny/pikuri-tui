# frozen_string_literal: true

RSpec.describe PikuriTui::Code::ConfirmerPopup do
  let(:screen) { Tuile::Screen.instance }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  def approved(detail) = Pikuri::Workspace::Confirmer::Approved.new(new_request_detail: detail)
  def rejected(reason = nil) = Pikuri::Workspace::Confirmer::Rejected.new(reason: reason)

  def request(question: 'OK to run this?', detail: nil, editable: false)
    Pikuri::Workspace::Confirmer::Request.new(question: question, detail: detail, editable: editable)
  end

  # Spin until the block yields truthy. decide blocks the calling thread on
  # Queue#pop, so the integration specs drive it from a worker and answer the
  # popups from the main thread.
  def wait_until(timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise 'timed out waiting for condition' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.005
    end
  end

  # Run +decide+ (or +confirm?+) on a worker and drive its popups from the
  # main thread via the block (which calls #decision / #prompt), returning
  # what the confirmer produced.
  def run(confirmer, req, method: :decide)
    result = nil
    worker = Thread.new { result = confirmer.public_send(method, request: req) }
    yield
    worker.join(2) || raise("#{method} never returned")
    result
  end

  # Wait for the decision popup, then send it +key+. Sends straight to the
  # Dialog (the popup): in the live app keys bubble up the focus chain to the
  # popup, but a direct handle_key in a test must target it, since focus
  # cascades down onto the inner read-only TextView.
  def decision(key)
    wait_until { screen.popups.last.is_a?(described_class::Dialog) }
    screen.popups.last.handle_key(key)
  end

  # Wait for a text-entry popup; type +text+ (nil = leave empty) then press
  # Enter, or send +key:+ instead for the ESC / dismiss paths. Drives the
  # popup's editable field directly.
  def prompt(text: nil, key: nil)
    wait_until { screen.popups.last.is_a?(described_class::PromptDialog) }
    field = screen.popups.last.field
    if key
      field.handle_key(key)
    else
      field.text = text if text
      field.handle_key(Tuile::Keys::ENTER)
    end
  end

  it 'is a Pikuri::Workspace::Confirmer (drops into the same tool slot as Terminal)' do
    assert_kind_of Pikuri::Workspace::Confirmer, described_class.new(screen: screen)
  end

  describe '#decide — non-editable (Write / Bash)' do
    it 'approves with the detail unchanged on y' do
      result = run(described_class.new(screen: screen), request(detail: 'ls -la')) { decision('y') }
      assert_equal approved('ls -la'), result
    end

    it 'rejects with no reason on n' do
      result = run(described_class.new(screen: screen), request) { decision('n') }
      assert_equal rejected, result
    end

    it 'rejects with a typed reason on r' do
      result = run(described_class.new(screen: screen), request) do
        decision('r')
        prompt(text: 'use the other library')
      end
      assert_equal rejected('use the other library'), result
    end

    it 'treats a blank reason as no reason' do
      result = run(described_class.new(screen: screen), request) do
        decision('r')
        prompt(text: '   ')
      end
      assert_equal rejected, result
    end

    it 'skips the reason (no reason) when the reason prompt is ESC-dismissed' do
      result = run(described_class.new(screen: screen), request) do
        decision('r')
        prompt(key: Tuile::Keys::ESC)
      end
      assert_equal rejected, result
    end

    it 'declines (no reason) when the decision popup is dismissed with ESC' do
      result = run(described_class.new(screen: screen), request) { decision(Tuile::Keys::ESC) }
      assert_equal rejected, result
    end

    it 'offers no edit path: e falls through to the modal (no resolution)' do
      # 'e' is inert on a non-editable request — the popup stays open, so we
      # follow with an explicit reject to let the worker finish.
      result = run(described_class.new(screen: screen), request) do
        decision('e')
        decision('n')
      end
      assert_equal rejected, result
    end
  end

  describe '#decide — editable (agent delegation)' do
    it 'approves the original task unchanged on y (clean task)' do
      result = run(described_class.new(screen: screen), request(detail: 'summarize CVEs', editable: true)) do
        decision('y')
      end
      assert_equal approved('summarize CVEs'), result
    end

    it 'approves the human-edited task on e (author seat)' do
      result = run(described_class.new(screen: screen), request(detail: 'summarize CVEs', editable: true)) do
        decision('e')
        prompt(text: 'summarize openssl CVEs only')
      end
      assert_equal approved('summarize openssl CVEs only'), result
    end

    it 'pre-fills the edit field with the raw task when clean' do
      run(described_class.new(screen: screen), request(detail: 'summarize CVEs', editable: true)) do
        decision('e')
        wait_until { screen.popups.last.is_a?(described_class::PromptDialog) }
        assert_equal 'summarize CVEs', screen.popups.last.field.text # inspect before submitting
        screen.popups.last.field.handle_key(Tuile::Keys::ENTER)
      end
    end

    it 'declines (no reason) when the edit prompt is ESC-cancelled' do
      result = run(described_class.new(screen: screen), request(detail: 'summarize CVEs', editable: true)) do
        decision('e')
        prompt(key: Tuile::Keys::ESC)
      end
      assert_equal rejected, result
    end
  end

  describe '#confirm? — the derived boolean the mutation gates use' do
    it 'is true on approve' do
      assert_equal true, run(described_class.new(screen: screen), request, method: :confirm?) { decision('y') }
    end

    it 'is false on reject' do
      assert_equal false, run(described_class.new(screen: screen), request, method: :confirm?) { decision('n') }
    end

    it 'is false on an ESC dismissal' do
      assert_equal false,
                   run(described_class.new(screen: screen), request, method: :confirm?) { decision(Tuile::Keys::ESC) }
    end
  end

  it 'closes the popup once a decision is given (no lingering modal)' do
    confirmer = described_class.new(screen: screen)
    run(confirmer, request) { decision('y') }
    assert_empty screen.popups
  end

  describe described_class::Dialog do
    # Build a decision Dialog the way #decide does: sanitize first, then hand
    # the results (and editable/clean) to the constructor.
    def dialog(question: 'OK to run this?', detail: nil, editable: false)
      q = Pikuri::Sanitizer.sanitize(question)
      d = detail ? Pikuri::Sanitizer.sanitize(detail) : nil
      warnings = q.warnings + (d ? d.warnings : [])
      described_class.new(question: q, detail: d, warnings: warnings,
                          editable: editable, clean: warnings.empty?, channel: Queue.new, screen: screen)
    end

    # The body is a TextView; its #text joins the hard lines with "\n", so
    # split on "\n" to recover the rendered (pre-wrapped) lines.
    def body_lines(dialog)
      dialog.content.content.text.to_s.split("\n")
    end

    it 'neutralizes control bytes in the detail (no raw \r reaches the body)' do
      lines = body_lines(dialog(detail: "echo hi\rrm -rf ~/")).join("\n")
      refute_includes lines, "\r"
      assert_includes lines, '\\x0d'
    end

    it 'surfaces a sanitizer warning when the LLM text carries suspicious bytes' do
      lines = body_lines(dialog(detail: "echo hi\rrm -rf ~/")).join("\n")
      assert_includes lines, 'Suspicious content detected'
      assert_includes lines, 'control bytes'
    end

    it 'shows no warning banner for clean content' do
      lines = body_lines(dialog(question: 'OK to overwrite foo.rb?')).join("\n")
      refute_includes lines, 'Suspicious content detected'
    end

    it 'omits the detail block entirely when detail is nil (the Write case)' do
      lines = body_lines(dialog(question: 'OK to overwrite foo.rb?', detail: nil))
      assert_equal ['OK to overwrite foo.rb?', '(y) approve   (n) reject   (r) reject w/ reason'], lines
    end

    it 'shows the edit key on an editable, clean request' do
      cue = body_lines(dialog(detail: 'summarize CVEs', editable: true)).last
      assert_equal '(y) approve   (e) edit   (n) reject   (r) reject w/ reason', cue
    end

    it 'drops the bare-approve key on an editable, flagged request (forced authorship)' do
      cue = body_lines(dialog(detail: "do this\rand that", editable: true)).last
      assert_equal '(e) edit   (n) reject   (r) reject w/ reason', cue
      refute_includes cue, '(y)'
    end

    it 'word-wraps a long single-line command instead of clipping it' do
      cmd = 'find . -type f -name "*.rb" -exec grep -l "needle" {} + | ' \
            'xargs wc -l | sort -n | head -20 | awk "{ print \$2 }" | ' \
            'tr "\\n" " " | sed "s/  */ /g" | cut -c1-200'
      lines = body_lines(dialog(question: 'Run this?', detail: cmd))
      # The command is longer than the wrapped body width (126 cols on the
      # 160-wide fake screen), so it spans more than one rendered line.
      assert_operator lines.length, :>, 3
      assert(lines.all? { |l| l.length <= 126 }, "a line exceeded the wrap width: #{lines.inspect}")
      detail = lines.first(lines.length - 1).join("\n")
      assert_includes detail, 'find .'
      assert_includes detail, 'tr'
    end
  end

  describe described_class::PromptDialog do
    let(:channel) { Queue.new }

    def prompt_dialog(caption: 'Edit', initial: '', rows: 4)
      described_class.new(caption: caption, initial: initial, rows: rows, channel: channel, screen: screen)
    end

    it 'pre-fills the field with the initial text' do
      assert_equal 'hello world', prompt_dialog(initial: 'hello world').field.text
    end

    it 'resolves the current text on Enter' do
      p = prompt_dialog(initial: 'draft')
      p.open
      p.field.text = 'final'
      p.field.handle_key(Tuile::Keys::ENTER)
      assert_equal 'final', channel.pop
      assert channel.empty?, 'expected exactly one resolution'
    end

    it 'resolves :cancel on ESC' do
      p = prompt_dialog(initial: 'draft')
      p.open
      p.field.handle_key(Tuile::Keys::ESC)
      assert_equal :cancel, channel.pop
    end

    it 'resolves :cancel on a bare close (dismissal)' do
      p = prompt_dialog
      p.open
      p.close
      assert_equal :cancel, channel.pop
      assert channel.empty?
    end

    it 'is a no-op double-close: the second close does not resolve again' do
      p = prompt_dialog
      p.open
      p.field.handle_key(Tuile::Keys::ESC) # resolves :cancel and closes
      assert_equal :cancel, channel.pop
      p.close
      assert channel.empty?, 'a second close must not push a second answer'
    end

    it 'focuses the field on open so keystrokes edit it' do
      p = prompt_dialog
      p.open
      assert_same p.field, screen.focused
    end
  end
end
