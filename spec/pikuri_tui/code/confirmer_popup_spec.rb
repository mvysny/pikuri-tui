# frozen_string_literal: true

RSpec.describe PikuriTui::Code::ConfirmerPopup do
  let(:screen) { Tuile::Screen.instance }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  def request(question: 'OK to run this?', detail: nil)
    Pikuri::Workspace::Confirmer::Request.new(question: question, detail: detail)
  end

  # Spin until the block yields truthy. confirm? blocks the calling
  # thread on Queue#pop, so the integration specs drive it from a worker
  # and answer the dialog from the main thread.
  def wait_until(timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise 'timed out waiting for condition' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.005
    end
  end

  # Run confirm? on a worker, wait for the modal to open, dispatch +key+
  # to it, and return the Boolean confirm? produced.
  def answer_with(confirmer, req, key)
    result = nil
    worker = Thread.new { result = confirmer.confirm?(request: req) }
    wait_until { screen.popups.any? }
    screen.popups.last.handle_key(key)
    worker.join(2) || raise('confirm? never returned')
    result
  end

  it 'is a Pikuri::Workspace::Confirmer (drops into the same tool slot as Terminal)' do
    assert_kind_of Pikuri::Workspace::Confirmer, described_class.new(screen: screen)
  end

  it 'returns true when the user presses y' do
    assert_equal true, answer_with(described_class.new(screen: screen), request, 'y')
  end

  it 'returns false when the user presses n' do
    assert_equal false, answer_with(described_class.new(screen: screen), request, 'n')
  end

  it 'declines (false) when the popup is dismissed with ESC — decline-by-default' do
    assert_equal false, answer_with(described_class.new(screen: screen), request, Tuile::Keys::ESC)
  end

  it 'declines (false) when the popup is dismissed with q' do
    assert_equal false, answer_with(described_class.new(screen: screen), request, 'q')
  end

  it 'closes the popup once an answer is given (no lingering modal)' do
    confirmer = described_class.new(screen: screen)
    answer_with(confirmer, request, 'y')
    assert_empty screen.popups
  end

  describe described_class::Dialog do
    let(:answer) { Queue.new }

    def dialog(req)
      described_class.new(request: req, answer: answer, screen: screen)
    end

    it 'pushes true exactly once on y, even though resolve also closes' do
      d = dialog(request)
      d.open
      d.handle_key('y')
      assert_equal true, answer.pop
      assert answer.empty?, 'expected exactly one answer pushed'
    end

    it 'pushes false on a bare close (the ESC/q dismissal path)' do
      d = dialog(request)
      d.open
      d.close
      assert_equal false, answer.pop
      assert answer.empty?
    end

    it 'is a no-op double-close: the second close does not push again' do
      d = dialog(request)
      d.open
      d.handle_key('n') # resolves false and closes
      assert_equal false, answer.pop
      d.close           # already closed/resolved
      assert answer.empty?, 'a second close must not push a second answer'
    end

    it 'accepts uppercase Y/N and the long forms yes/no' do
      %w[Y yes YES].each do |k|
        a = Queue.new
        d = described_class.new(request: request, answer: a, screen: screen)
        d.open
        d.handle_key(k)
        assert_equal true, a.pop
      end
    end

    # The body is a TextView; its #text is a single StyledString whose
    # #to_s joins the hard lines with "\n", so split on "\n" to recover
    # the rendered (pre-wrapped) lines.
    def body_lines(dialog)
      dialog.content.content.text.to_s.split("\n")
    end

    it 'neutralizes control bytes in the detail (no raw \r reaches the body)' do
      lines = body_lines(dialog(request(detail: "echo hi\rrm -rf ~/"))).join("\n")
      refute_includes lines, "\r"
      assert_includes lines, '\\x0d'
    end

    it 'surfaces a sanitizer warning when the LLM text carries suspicious bytes' do
      lines = body_lines(dialog(request(detail: "echo hi\rrm -rf ~/"))).join("\n")
      assert_includes lines, 'Suspicious content detected'
      assert_includes lines, 'control bytes'
    end

    it 'shows no warning banner for clean content' do
      lines = body_lines(dialog(request(question: 'OK to overwrite foo.rb?'))).join("\n")
      refute_includes lines, 'Suspicious content detected'
    end

    it 'omits the detail block entirely when detail is nil (the Write case)' do
      lines = body_lines(dialog(request(question: 'OK to overwrite foo.rb?', detail: nil)))
      assert_equal ['OK to overwrite foo.rb?', '(y) yes   (n) no'], lines
    end

    it 'word-wraps a long single-line command instead of clipping it' do
      cmd = 'find . -type f -name "*.rb" -exec grep -l "needle" {} + | ' \
            'xargs wc -l | sort -n | head -20 | awk "{ print \$2 }" | ' \
            'tr "\\n" " " | sed "s/  */ /g" | cut -c1-200'
      lines = body_lines(dialog(request(question: 'Run this?', detail: cmd)))
      # The command is longer than the wrapped body width (126 cols on the
      # 160-wide fake screen), so it spans more than one rendered line — the
      # question + ≥2 detail rows + the y/n cue.
      assert_operator lines.length, :>, 3
      # Every rendered line stays within the wrapped body width.
      assert(lines.all? { |l| l.length <= 126 }, "a line exceeded the wrap width: #{lines.inspect}")
      # Both ends of the command survive the wrap.
      detail = lines.first(lines.length - 1).join("\n")
      assert_includes detail, 'find .'
      assert_includes detail, 'tr'
    end
  end
end
