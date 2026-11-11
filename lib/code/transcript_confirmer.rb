# frozen_string_literal: true

require 'pikuri-core'
require 'pikuri-workspace'
require 'tuile'

module Code
  # A {Pikuri::Workspace::Confirmer} that asks the human in the transcript: the
  # question lands as a block in the conversation pane, the status rule lights
  # its parked-decision badge, and the calling thread parks until a key answers.
  #
  #   confirmer = Code::TranscriptConfirmer.new(screen: screen, conversation: conversation,
  #                                             status_rule: status_rule, input: input)
  #   # ... a tool, on the agent worker thread:
  #   case decision = confirmer.ask(request: request)   # parks until the human answers
  #   in Pikuri::Workspace::Confirmer::Approved then run_it
  #   in Pikuri::Workspace::Confirmer::Rejected | Pikuri::Workspace::Confirmer::Redirected
  #     return decision.observation('the bash command')
  #   end
  #
  #   ⏵ OK to run this command?
  #   rm -rf build
  #   (y) approve   (n) reject   (r) redirect
  #
  # +y+ approves the payload unchanged, +n+ rejects (the model stops), and +r+
  # borrows the prompt for words the model gets as guidance — a redirect. An
  # *editable* request (only the +agent+ tool's delegation sets that) also offers
  # +e+, which borrows the prompt to rewrite the payload the tool then acts on —
  # the "author, not approver" seat. Both typing outcomes go through
  # {Shared::InputPane#capture}; there is deliberately no text-entry popup.
  #
  # Those keys answer only while the conversation pane holds focus — which is
  # what lets them be spelled +y+ / +n+ at all, since prose typed at the prompt
  # is a different focus target and can never reach a decision. The one
  # obligation that puts on a caller: *dismissal is not decline.* Tabbing away
  # leaves the decision parked, and a parked decision holds the agent's worker
  # thread, so +Ctrl+C+ and quit must both call {#cancel_pending!} or they do
  # nothing visible while a question waits. That cancels rather than rejects:
  # the parked {#ask} raises +Cancellable::Cancelled+, so the turn ends there
  # instead of running on for one more model reply.
  #
  # == Sanitizing
  #
  # +request.question+, +request.detail+ and the change's bytes are RAW
  # LLM-composed bytes (see {Pikuri::Workspace::Confirmer::Request}), so {#ask}
  # runs them through {Pikuri::Sanitizer} — the same chrome-independent primitive
  # +Confirmer::Terminal+ uses. Dangerous bytes are neutralized for literal
  # display (a command carrying +"\rrm -rf ~/"+ can't redraw the line after the
  # user has read it), and each attack class detected returns a warning
  # {ConfirmRenderer} surfaces above the question.
  #
  # The verdict also gates the edit pre-fill, which is the subtle part: the
  # edited payload must be RAW bytes (it is what the sub-agent receives), so
  # pre-filling the prompt with it would hand the attack straight back. A
  # *clean* task pre-fills; a *flagged* one forces a full retype and loses the
  # bare-approve key — forced authorship exactly where it matters most.
  #
  # == Threading
  #
  # UI-thread-confined, with one exception (the method a tool calls parks the
  # *caller's* thread, and carries its own rule).
  #
  # The hand-off is a one-shot +Queue+: the question is submitted onto the UI
  # thread, and the worker parks on +Queue#pop+ until a key resolves it. Parking
  # the worker is the point — it is exactly the thread that should wait while the
  # human decides, leaving the UI thread free to paint and to process the
  # keypress that unblocks it.
  class TranscriptConfirmer < Pikuri::Workspace::Confirmer
    # Marker the {Shared::InputPane} wears while it holds a captured answer
    # rather than a message, so a borrowed prompt doesn't look like an idle one.
    #
    # @return [String]
    CAPTURE_MARKER = '✎'

    # What {#cancel_pending!} wakes a parked {#ask} with, in place of a decision.
    #
    # @return [Object]
    CANCELLED = Object.new.freeze
    private_constant :CANCELLED

    # @param screen [Tuile::Screen] the screen whose +event_queue+ marshals the
    #   question onto the UI thread.
    # @param conversation [Shared::ConversationTextView] the pane the question is
    #   asked in and answered at.
    # @param status_rule [Shared::StatusRuleLabel] the rule whose parked-decision
    #   badge says a turn is waiting on a human.
    # @param input [Shared::InputPane] the prompt borrowed for the edit / redirect
    #   text, and the focus target the answer returns to.
    def initialize(screen:, conversation:, status_rule:, input:)
      super()
      @screen = screen
      @conversation = conversation
      @status_rule = status_rule
      @input = input
      # The parked answer channel, owned by the UI thread: #ask hands it over
      # inside the submit and never touches it again.
      @pending = nil
      # Set by #cancel_pending! while a capture in flight unwinds, so #finish
      # turns that capture's nil answer into a cancel rather than a reject.
      @cancelling = false
    end

    # Ask +request+ in the transcript and block the calling (worker) thread
    # until the user answers.
    #
    # Safe to call from any thread *except* the UI thread — calling it there
    # would deadlock, since the submitted block can't run until the event loop
    # drains and the event loop would be parked here. Tools always call it from
    # the worker, so this holds.
    #
    # @param request [Pikuri::Workspace::Confirmer::Request] semantic content
    #   composed by the calling tool; sanitized and rendered here.
    # @return [Pikuri::Workspace::Confirmer::Approved,
    #   Pikuri::Workspace::Confirmer::Rejected,
    #   Pikuri::Workspace::Confirmer::Redirected] the resolved decision.
    # @raise [Pikuri::Agent::Control::Cancellable::Cancelled] when
    #   {#cancel_pending!} ends the wait.
    def ask(request:)
      question = Pikuri::Sanitizer.sanitize(request.question)
      detail   = request.detail ? Pikuri::Sanitizer.sanitize(request.detail) : nil
      change, change_warnings = sanitize_change(request.change)
      warnings = question.warnings + (detail ? detail.warnings : []) + change_warnings

      channel = Queue.new
      @screen.event_queue.submit do
        park(channel, request: request, question: question, detail: detail,
                      warnings: warnings, change: change)
      end
      decision = channel.pop
      raise Pikuri::Agent::Control::Cancellable::Cancelled if decision.equal?(CANCELLED)

      decision
    end

    # @return [Boolean] whether a tool is parked waiting for an answer. Read on
    #   the UI thread.
    def pending? = !@pending.nil?

    # Cancel whatever is parked, so a +Ctrl+C+ or a quit isn't swallowed by a
    # decision the user never noticed: the parked {#ask} raises
    # +Cancellable::Cancelled+. Pair it with cancelling the agent's
    # +Cancellable+, so a sub-agent tree stops too.
    #
    # @return [Boolean] +false+ when nothing was parked, +true+ when a decision
    #   was cancelled.
    def cancel_pending!
      return false if @pending.nil?

      if @input.capturing?
        # The capture resolves through its own callback with a nil answer;
        # @cancelling makes #finish read that as this cancel, not as ESC.
        @cancelling = true
        @input.cancel_capture
      else
        finish(CANCELLED, 'cancelled')
      end
      true
    end

    private

    # Ask the question and light the badge, arming the transcript's keys.
    #
    # @param channel [Queue] the one-shot channel the parked caller is popping.
    # @param request [Pikuri::Workspace::Confirmer::Request] the original,
    #   *unsanitized* request. Needed alongside the display copies below because
    #   an approval passes its +detail+ through verbatim and an edit pre-fills
    #   the prompt with it — both want the raw bytes the tool will act on.
    # @param question [Pikuri::Sanitizer::Result] the sanitized question.
    # @param detail [Pikuri::Sanitizer::Result, nil] the sanitized payload.
    # @param warnings [Array<Pikuri::Sanitizer::Warning>] what the sanitizer
    #   flagged; empty when clean.
    # @param change [Pikuri::Workspace::Confirmer::Change, nil] the sanitized
    #   file change to diff.
    # @return [void]
    def park(channel, request:, question:, detail:, warnings:, change:)
      @pending = channel
      clean = warnings.empty?
      editable = request.editable && !request.detail.nil?
      body = ConfirmRenderer.render(question: question, detail: detail, warnings: warnings,
                                    change: change, width: @conversation.buffer_width,
                                    theme: @screen.theme)
      @conversation.pending_decision = Shared::PendingDecision.new(
        body: body, choices: choices(editable: editable, clean: clean),
        on_choice: ->(outcome) { decide(outcome, payload: request.detail, clean: clean) }
      )
      @status_rule.decision_pending = true
    end

    # The outcomes on offer. An editable request whose payload the sanitizer
    # flagged loses the bare-approve key: authorship is forced.
    #
    # @param editable [Boolean] whether the payload may be rewritten.
    # @param clean [Boolean] whether the sanitizer flagged nothing.
    # @return [Array<Shared::PendingDecision::Choice>]
    def choices(editable:, clean:)
      choice = Shared::PendingDecision::Choice
      offered = []
      offered << choice.new(key: 'y', label: 'approve', outcome: :approve) unless editable && !clean
      offered << choice.new(key: 'e', label: 'edit', outcome: :edit) if editable
      offered << choice.new(key: 'n', label: 'reject', outcome: :reject)
      offered << choice.new(key: 'r', label: 'redirect', outcome: :redirect)
      offered
    end

    # Act on the picked outcome: resolve it, or borrow the prompt for the text
    # the outcome still needs.
    #
    # @param outcome [Symbol] +:approve+, +:edit+, +:reject+, +:redirect+.
    # @param payload [String, nil] the raw +Request#detail+.
    # @param clean [Boolean] whether the sanitizer flagged nothing.
    # @return [void]
    def decide(outcome, payload:, clean:)
      case outcome
      when :approve then finish(Approved.new(new_request_detail: payload), 'approved')
      when :reject then finish(Rejected.new, 'rejected')
      when :edit then capture_task(payload: payload, clean: clean)
      when :redirect then capture_redirect
      end
    end

    # Hand the prompt the task to rewrite. Submitting approves the
    # human-authored text (an emptied buffer included — a deliberately cleared
    # task); cancelling declines.
    #
    # @param payload [String, nil] the raw task, pre-filled only when clean.
    # @param clean [Boolean] whether the sanitizer flagged nothing; a flagged
    #   task starts from an empty buffer.
    # @return [void]
    def capture_task(payload:, clean:)
      @conversation.settle_pending_decision('editing the task — Enter sends it, Esc rejects')
      @input.capture(marker: CAPTURE_MARKER, initial: clean ? payload : '') do |text|
        if text.nil?
          finish(Rejected.new, 'rejected')
        else
          finish(Approved.new(new_request_detail: text), 'approved, task rewritten')
        end
      end
    end

    # Hand the prompt the words a redirect sends the model. A blank answer or
    # an ESC is a plain reject.
    #
    # @return [void]
    def capture_redirect
      @conversation.settle_pending_decision('redirecting — tell the agent, Enter sends it, Esc just rejects')
      @input.capture(marker: CAPTURE_MARKER) do |text|
        message = text&.strip
        if message.nil? || message.empty?
          finish(Rejected.new, 'rejected')
        else
          finish(Redirected.new(message: message), "redirected: #{message}")
        end
      end
    end

    # Settle the transcript block and wake the parked tool. The wake goes last,
    # so the UI is finished before the worker resumes rendering into that same
    # pane.
    #
    # @param decision [Pikuri::Workspace::Confirmer::Approved,
    #   Pikuri::Workspace::Confirmer::Rejected,
    #   Pikuri::Workspace::Confirmer::Redirected, Object] a decision, or
    #   {CANCELLED}.
    # @param note [String] the outcome as the transcript records it.
    # @return [void]
    def finish(decision, note)
      if @cancelling
        decision = CANCELLED
        note = 'cancelled'
        @cancelling = false
      end
      channel = @pending
      @pending = nil
      @conversation.settle_pending_decision(note)
      @status_rule.decision_pending = false
      @input.focus
      channel << decision
    end

    # Neutralize a change's bytes for display, returning a +Change+ carrying the
    # sanitized old/new text alongside the warnings they raised.
    #
    # Old/new are sanitized *before* diffing rather than the diff sanitized
    # after ({Pikuri::Workspace::Confirmer::Terminal} does the latter):
    # {DiffRenderer} emits ANSI, which a later sanitize pass would escape into
    # visible +\x1b+ noise. The mapping is per-character and newline-preserving,
    # so the two orders align line for line.
    #
    # @param change [Pikuri::Workspace::Confirmer::Change, nil]
    # @return [Array(Pikuri::Workspace::Confirmer::Change, nil),
    #   Array<Pikuri::Sanitizer::Warning>] the display-safe change (+nil+ when
    #   the request carried none) and its warnings.
    def sanitize_change(change)
      return [nil, []] if change.nil?

      old = change.old ? Pikuri::Sanitizer.sanitize(displayable(change.old)) : nil
      fresh = Pikuri::Sanitizer.sanitize(displayable(change.new))
      [Change.new(path: change.path, old: old&.text, new: fresh.text),
       (old ? old.warnings : []) + fresh.warnings]
    end

    # Force file bytes into valid UTF-8 for display.
    #
    # The file tools hand back BINARY strings ({Pikuri::Workspace::Edit} matches
    # in LF space via +String#b+), and matching one against the sanitizer's
    # UTF-8 regexp raises +Encoding::CompatibilityError+ the moment the file
    # holds a non-ASCII byte.
    #
    # @param bytes [String] raw file content.
    # @return [String] UTF-8 with undecodable bytes replaced by U+FFFD.
    def displayable(bytes)
      bytes.dup.force_encoding(Encoding::UTF_8).scrub
    end
  end
end
