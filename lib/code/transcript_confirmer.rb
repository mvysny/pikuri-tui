# frozen_string_literal: true

require 'pikuri-core'
require 'pikuri-workspace'
require 'tuile'

module Code
  # A {Pikuri::Workspace::Confirmer} that asks the user *in the transcript*
  # instead of in a modal popup — wired into the +write+ / +Pikuri::Code::Bash+
  # / +agent+ tools so a write, a bash command or a network-reaching delegation
  # parks for a decision before it runs:
  #
  #   confirmer = Code::TranscriptConfirmer.new(screen: screen, conversation: conversation,
  #                                             status_rule: status_rule, input: input)
  #   # ... a tool, on the agent worker thread:
  #   case confirmer.ask(request: request)   # blocks until the human answers
  #   in Pikuri::Workspace::Confirmer::Approved then run_it
  #   in Pikuri::Workspace::Confirmer::Rejected(reason:) then tell_the_model(reason)
  #   end
  #
  # The question lands as a block in the conversation pane, the status rule
  # lights its parked-decision badge, and the answer keys go live only while the
  # transcript holds focus:
  #
  #   ⏵ OK to run this command?
  #   rm -rf build
  #   (y) approve   (n) reject   (r) reject w/ reason
  #
  # == Why not a popup
  #
  # A confirmation is the one surface in these shells that opens *unbidden*, so
  # it is the one that must not be able to steal a keystroke. Focus is what
  # solves that: prose goes to the prompt, decisions go to the transcript, and no
  # amount of typing can answer a question the user has not looked at. A modal
  # popup instead put +y+ / +n+ in the path of ordinary typing, where a key that
  # arrived a moment after the popup opened decided a question nobody had read.
  #
  # Three properties fall out, and each is load-bearing:
  #
  # * *Dismissal is not decline.* Tabbing away or scrolling leaves the decision
  #   parked. Only an explicit key answers it — plus {#reject_pending!}, which is
  #   how +Ctrl+C+ and quit stay responsive while a tool is parked.
  # * *The context stays readable.* The tool calls that explain *why* the agent
  #   wants this are still on screen, and the diff scrolls with the transcript.
  # * *The decision is a record.* Once answered, the block keeps the question
  #   with its outcome written underneath.
  #
  # == The decision: approve / edit / reject
  #
  # {#ask} implements the confirmer primitive, returning
  # {Pikuri::Workspace::Confirmer::Approved} (carrying the possibly-edited
  # +detail+) or {Pikuri::Workspace::Confirmer::Rejected} (carrying an optional
  # steering reason); the base derives +confirm?+ from it for the mutation gates
  # that need only a Boolean. Four outcomes are on offer:
  #
  # * *Approve* (+y+) — run the operation with +detail+ unchanged.
  # * *Edit* (+e+, editable requests only) — the human rewrites the verbatim
  #   payload (the +agent+ task) in the prompt; the edited text is what the tool
  #   acts on. The "author, not approver" seat.
  # * *Reject* — +n+ declines immediately; +r+ borrows the prompt for an optional
  #   steering reason the tool folds into the model's next observation. Two keys
  #   keep a plain "no" friction-free while making reason-giving a choice.
  #
  # Only the +agent+ delegation gate sets +Request#editable+, so +write+ and
  # +bash+ offer approve / reject only. Text for the two typing outcomes is
  # captured by the {Shared::InputPane} ({Shared::InputPane#capture}) rather than
  # a text-entry popup: prose belongs in the one place prose is safe.
  #
  # == Sanitizing
  #
  # +request.question+, +request.detail+ and the change's bytes are RAW
  # LLM-composed bytes (see {Pikuri::Workspace::Confirmer::Request}). {#ask} runs
  # them through {Pikuri::Sanitizer} once — the same chrome-independent primitive
  # +Confirmer::Terminal+ uses — which (a) neutralizes the dangerous bytes for
  # literal display, so a command containing +"\rrm -rf ~/"+ can't visually
  # overwrite the line after the user has read it, and (b) returns a warning per
  # attack class detected, which {ConfirmRenderer} surfaces above the question.
  #
  # The verdict also gates the edit pre-fill: the edited payload must be RAW
  # bytes (it is what the sub-agent receives), but pre-filling the prompt with
  # raw bytes would reintroduce the very attack the sanitizer defends against. So
  # a *clean* task pre-fills; a *flagged* one forces a full retype, and drops the
  # bare-approve key entirely — forced authorship exactly where it matters most.
  #
  # == Threading
  #
  # {#ask} is called synchronously by a tool on the agent worker thread, and
  # every UI mutation must run on the thread that owns +run_event_loop+. So
  # {#ask} creates a one-shot +Queue+, submits the block that asks the question
  # onto the UI thread, and parks the worker on +Queue#pop+ until a key resolves
  # it. Parking the worker is the point: it is exactly the thread that should
  # wait while the user decides, and the UI thread stays free to paint and to
  # process the keypress that unblocks it.
  #
  # UI-thread-confined, with one exception ({#ask}, which must be called from
  # the worker and would deadlock on the UI thread).
  class TranscriptConfirmer < Pikuri::Workspace::Confirmer
    # Marker the {Shared::InputPane} wears while it holds a captured answer
    # rather than a message, so a borrowed prompt doesn't look like an idle one.
    #
    # @return [String]
    CAPTURE_MARKER = '✎'

    # @param screen [Tuile::Screen] the screen whose +event_queue+ marshals the
    #   question onto the UI thread.
    # @param conversation [Shared::ConversationTextView] the pane the question is
    #   asked in and answered at.
    # @param status_rule [Shared::StatusRuleLabel] the rule whose parked-decision
    #   badge says a turn is waiting on a human.
    # @param input [Shared::InputPane] the prompt borrowed for the edit / reason
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
    #   Pikuri::Workspace::Confirmer::Rejected] the resolved decision.
    def ask(request:)
      question = Pikuri::Sanitizer.sanitize(request.question)
      detail   = request.detail ? Pikuri::Sanitizer.sanitize(request.detail) : nil
      change, change_warnings = sanitize_change(request.change)
      warnings = question.warnings + (detail ? detail.warnings : []) + change_warnings
      editable = request.editable && !request.detail.nil?

      channel = Queue.new
      @screen.event_queue.submit do
        park(channel, question: question, detail: detail, warnings: warnings, change: change,
                      editable: editable, clean: warnings.empty?, payload: request.detail)
      end
      channel.pop
    end

    # @return [Boolean] whether a tool is parked waiting for an answer. Read on
    #   the UI thread.
    def pending? = !@pending.nil?

    # Reject whatever is parked, so a +Ctrl+C+ or a quit isn't swallowed by a
    # decision the user never noticed — the decline-by-default a modal popup got
    # from its ESC dismissal, moved to the two places that actually mean "stop".
    #
    # @return [Boolean] +false+ when nothing was parked (the caller should fall
    #   through to its normal handling), +true+ when a decision was declined.
    def reject_pending!
      return false if @pending.nil?

      # A capture in flight resolves through its own callback, which rejects on
      # a nil answer — the same path ESC takes.
      if @input.capturing?
        @input.cancel_capture
      else
        finish(Rejected.new(reason: nil), 'rejected')
      end
      true
    end

    private

    # Ask the question and light the badge, arming the transcript's keys.
    #
    # @param channel [Queue] the one-shot answer channel {#ask} is parked on.
    # @param payload [String, nil] the RAW (unsanitized) +request.detail+ — what
    #   an approval passes through and an edit pre-fills.
    # @return [void]
    def park(channel, question:, detail:, warnings:, change:, editable:, clean:, payload:)
      @pending = channel
      body = ConfirmRenderer.render(question: question, detail: detail, warnings: warnings,
                                    change: change, width: @conversation.buffer_width,
                                    theme: @screen.theme)
      @conversation.pending_decision = Shared::PendingDecision.new(
        body: body, choices: choices(editable: editable, clean: clean),
        on_choice: ->(outcome) { decide(outcome, payload: payload, clean: clean) }
      )
      @status_rule.decision_pending = true
    end

    # The outcomes on offer. An editable request whose payload the sanitizer
    # flagged loses the bare-approve key: authorship is forced.
    #
    # @return [Array<Shared::PendingDecision::Choice>]
    def choices(editable:, clean:)
      choice = Shared::PendingDecision::Choice
      offered = []
      offered << choice.new(key: 'y', label: 'approve', outcome: :approve) unless editable && !clean
      offered << choice.new(key: 'e', label: 'edit', outcome: :edit) if editable
      offered << choice.new(key: 'n', label: 'reject', outcome: :reject)
      offered << choice.new(key: 'r', label: 'reject w/ reason', outcome: :reject_reason)
      offered
    end

    # Act on the picked outcome: resolve it, or borrow the prompt for the text
    # the outcome still needs.
    #
    # @param outcome [Symbol] +:approve+, +:edit+, +:reject+, +:reject_reason+.
    # @return [void]
    def decide(outcome, payload:, clean:)
      case outcome
      when :approve then finish(Approved.new(new_request_detail: payload), 'approved')
      when :reject then finish(Rejected.new(reason: nil), 'rejected')
      when :edit then capture_task(payload: payload, clean: clean)
      when :reject_reason then capture_reason
      end
    end

    # Hand the prompt the task to rewrite. Submitting approves the
    # human-authored text (an emptied buffer included — a deliberately cleared
    # task); cancelling declines.
    #
    # @return [void]
    def capture_task(payload:, clean:)
      @conversation.settle_pending_decision('editing the task — Enter sends it, Esc rejects')
      @input.capture(marker: CAPTURE_MARKER, initial: clean ? payload : '') do |text|
        if text.nil?
          finish(Rejected.new(reason: nil), 'rejected')
        else
          finish(Approved.new(new_request_detail: text), 'approved, task rewritten')
        end
      end
    end

    # Hand the prompt the steering reason. A blank answer or a cancel is a
    # reasonless decline.
    #
    # @return [void]
    def capture_reason
      @conversation.settle_pending_decision('rejecting — type a reason, Enter sends it, Esc skips')
      @input.capture(marker: CAPTURE_MARKER) do |text|
        reason = text.nil? || text.strip.empty? ? nil : text.strip
        finish(Rejected.new(reason: reason), reason ? "rejected: #{reason}" : 'rejected')
      end
    end

    # Write the outcome into the transcript block, drop the badge, hand focus
    # back to the prompt, and wake the parked tool — in that order, so the UI is
    # settled before the worker resumes rendering into the same pane.
    #
    # @param decision [Pikuri::Workspace::Confirmer::Approved,
    #   Pikuri::Workspace::Confirmer::Rejected]
    # @param note [String] the outcome as the transcript records it.
    # @return [void]
    def finish(decision, note)
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
