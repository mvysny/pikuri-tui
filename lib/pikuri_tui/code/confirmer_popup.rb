# frozen_string_literal: true

require 'pikuri-core'
require 'pikuri-workspace'
require 'tuile'

module Code
  # A {Pikuri::Workspace::Confirmer} that asks the user via a modal
  # Tuile popup instead of stdin — the TUI equivalent of
  # {Pikuri::Workspace::Confirmer::Terminal}. Wired into the coding and
  # OS shells' +Write+ / +Pikuri::Code::Bash+ / +agent+ (sub-agent
  # delegation) tools so a write-overwrite, a bash command, or a
  # network-reaching delegation pauses for a decision before it runs.
  #
  # == The decision: approve / edit / reject
  #
  # Upstream pikuri replaced the boolean confirmer with the richer
  # {Pikuri::Workspace::Confirmer#ask} primitive, which returns a sum
  # type — {Pikuri::Workspace::Confirmer::Approved} (carrying the
  # possibly-edited {Pikuri::Workspace::Confirmer::Request#detail}) or
  # {Pikuri::Workspace::Confirmer::Rejected} (carrying an optional
  # steering reason). This popup implements {#ask} (the base derives
  # {#confirm?} from it for the mutation gates that need only a Boolean).
  # It surfaces three outcomes across up to two stacked popups:
  #
  # * *Approve* (+y+) — run the operation with +detail+ unchanged.
  # * *Edit* (+e+, editable requests only) — the human rewrites the
  #   verbatim payload (the +agent+ task) in a second popup; the edited
  #   text is what the tool acts on. The "author, not approver" seat (see
  #   +ideas/more-confirmers.md+ in pikuri).
  # * *Reject* — +n+ declines immediately with no reason; +r+ opens a
  #   second popup for an optional steering reason the tool folds into
  #   the model's next observation. Two keys keep a plain "no" friction-
  #   free while making reason-giving an explicit choice (a cleaner UX
  #   than +Confirmer::Terminal+'s always-prompt-then-skip).
  #
  # Only the +agent+ delegation gate sets {Request#editable}; +Write+ and
  # +Bash+ requests are non-editable, so their decision popup offers only
  # approve / reject.
  #
  # == Threading (the hard part)
  #
  # {#ask} is called *synchronously by the tool*, and the tool runs on
  # the agent worker thread (per CLAUDE.md the agent loop never runs on
  # the UI thread). But every UI mutation — building a popup, opening it —
  # must run on the thread that owns +run_event_loop+. So each popup step
  # (the decision, then optionally an edit / reason prompt) is one
  # round-trip: {#ask}
  #
  # 1. creates a one-shot +Queue+ as the cross-thread answer channel,
  # 2. +screen.event_queue.submit+s a block that builds and opens the
  #    popup on the UI thread, and
  # 3. blocks the worker on +Queue#pop+ until a key on the UI thread
  #    resolves it.
  #
  # The blocking is deliberate and correct: the worker thread is exactly
  # the one that should park while the user decides — the UI thread stays
  # free to paint the popup and process the keypress that unblocks it.
  # +Queue+ (not a bare ivar + flag) gives a memory-safe hand-off with no
  # busy-wait.
  #
  # == Sanitizing
  #
  # +request.question+ and +request.detail+ are RAW LLM-composed bytes
  # (see {Pikuri::Workspace::Confirmer::Request}). {#ask} runs them
  # through {Pikuri::Sanitizer} once (off the UI thread — it is pure) —
  # the same chrome-independent primitive +Confirmer::Terminal+ uses —
  # which (a) neutralizes the dangerous bytes for literal display (control
  # bytes → +\xNN+, bidi/zero-width → +\u{NNNN}+, tab → +\t+, newline
  # preserved) so a crafted command containing +"\rrm -rf ~/"+ can't
  # visually overwrite the echoed line after the user has read it, and (b)
  # returns a {Pikuri::Sanitizer::Warning} per attack class detected. The
  # {Dialog} surfaces those warnings — bold-yellow header + each
  # plain-English explanation — above the question, so the user reads
  # *why* the content is suspicious before answering.
  #
  # The sanitizer verdict also gates the edit pre-fill (mirroring
  # +Confirmer::Terminal+): the edited payload must be RAW bytes (it is
  # what the sub-agent receives), but pre-filling an editable buffer with
  # raw bytes would reintroduce the very control-byte attack the sanitizer
  # defends against. So a *clean* task pre-fills the edit field with the
  # raw task; a *flagged* one refuses the pre-fill and forces a full
  # retype (and drops the bare-approve path — forced authorship exactly
  # where it matters most).
  #
  # == Decline-by-default
  #
  # Dismissing the decision popup any other way (the base +Popup+ closes
  # on ESC/q) declines with no reason — {Dialog#close} resolves +:reject+
  # if no explicit choice was made, mirroring +Confirmer::Terminal+'s
  # EOF-is-decline rule. Cancelling (ESC) the edit prompt likewise
  # declines; cancelling the reason prompt skips the reason (a bare
  # rejection). A destructive or network-reaching operation never runs
  # because the user looked away.
  class ConfirmerPopup < Pikuri::Workspace::Confirmer
    # @param screen [Tuile::Screen] the screen whose +event_queue+
    #   marshals popup construction to the UI thread. The same screen
    #   the host runs its event loop on.
    def initialize(screen:)
      super()
      @screen = screen
    end

    # Pose +request+ as one or two modal popups and block the calling
    # (worker) thread until the user resolves it. Safe to call from any
    # thread *except* the UI thread — calling it there would deadlock,
    # since the submitted block can't run until the event loop drains and
    # the event loop is blocked here on +Queue#pop+. Tools always call it
    # from the worker, so this holds.
    #
    # @param request [Pikuri::Workspace::Confirmer::Request] semantic
    #   content composed by the calling tool; sanitized and rendered here.
    # @return [Pikuri::Workspace::Confirmer::Approved,
    #   Pikuri::Workspace::Confirmer::Rejected] the resolved decision —
    #   {Approved} carrying the (possibly edited) detail, or {Rejected}
    #   carrying the optional steering reason.
    def ask(request:)
      question = Pikuri::Sanitizer.sanitize(request.question)
      detail   = request.detail ? Pikuri::Sanitizer.sanitize(request.detail) : nil
      warnings = question.warnings + (detail ? detail.warnings : [])
      clean    = warnings.empty?
      editable = request.editable && !request.detail.nil?

      case ask_decision(question: question, detail: detail, warnings: warnings,
                        editable: editable, clean: clean)
      when :approve
        Approved.new(new_request_detail: request.detail)
      when :edit
        edit(request, clean: clean)
      when :reject
        Rejected.new(reason: nil)
      when :reject_reason
        reject_with_reason
      end
    end

    private

    # Open the decision popup and block until the user picks an outcome.
    #
    # @return [Symbol] one of +:approve+, +:edit+, +:reject+,
    #   +:reject_reason+ (a dismissal resolves +:reject+).
    def ask_decision(**kwargs)
      channel = Queue.new
      @screen.event_queue.submit do
        Dialog.new(channel: channel, screen: @screen, **kwargs).open
      end
      channel.pop
    end

    # Run the edit prompt and fold its result into a decision. A clean
    # task pre-fills the raw payload; a flagged one forces a retype. ESC
    # (cancel) declines; submitting (even an empty buffer — a deliberately
    # cleared task) approves the human-authored text.
    #
    # @param request [Pikuri::Workspace::Confirmer::Request]
    # @param clean [Boolean] whether the payload passed the sanitizer.
    # @return [Pikuri::Workspace::Confirmer::Approved,
    #   Pikuri::Workspace::Confirmer::Rejected]
    def edit(request, clean:)
      edited = ask_prompt(caption: 'Edit task — Enter to submit, Esc to cancel',
                          initial: clean ? request.detail : '', rows: 6)
      return Rejected.new(reason: nil) if edited == :cancel

      Approved.new(new_request_detail: edited)
    end

    # Run the reason prompt and wrap its result in a {Rejected}. A blank
    # buffer or ESC (skip) yields a reasonless decline.
    #
    # @return [Pikuri::Workspace::Confirmer::Rejected]
    def reject_with_reason
      entered = ask_prompt(caption: 'Reason — Enter to submit, Esc to skip',
                           initial: '', rows: 3)
      reason = entered == :cancel || entered.strip.empty? ? nil : entered.strip
      Rejected.new(reason: reason)
    end

    # Open a text-entry popup and block until the user submits or cancels.
    #
    # @param caption [String] the window caption / instruction line.
    # @param initial [String] pre-fill text ("" for none).
    # @param rows [Integer] the field's visible height in rows.
    # @return [String, Symbol] the submitted text, or +:cancel+ on ESC /
    #   dismissal.
    def ask_prompt(caption:, initial:, rows:)
      channel = Queue.new
      @screen.event_queue.submit do
        PromptDialog.new(caption: caption, initial: initial, rows: rows,
                         channel: channel, screen: @screen).open
      end
      channel.pop
    end

    # The decision popup: a framed +Window+ captioned "Confirm", wrapping
    # a +TextView+ of any sanitizer warnings, the sanitized question, the
    # optional sanitized detail, and the key cue. Owns the answer channel;
    # its {#handle_key} maps keys to outcome symbols and the inherited
    # ESC/q close declines.
    #
    # Built and driven entirely on the UI thread — constructed inside the
    # {ConfirmerPopup#ask_decision} +submit+ block, and its {#handle_key}
    # / {#close} fire from Tuile's key dispatch, which is the UI thread.
    class Dialog < Tuile::Component::Popup
      # @param question [Pikuri::Sanitizer::Result] the sanitized question.
      # @param detail [Pikuri::Sanitizer::Result, nil] the sanitized detail.
      # @param warnings [Array<Pikuri::Sanitizer::Warning>] the flagged
      #   warnings across question + detail (empty when clean).
      # @param editable [Boolean] whether the request offers an edit path.
      # @param clean [Boolean] whether the payload passed the sanitizer
      #   (an editable+flagged request drops the bare-approve path).
      # @param channel [Queue] one-shot channel; the resolved outcome
      #   symbol is pushed exactly once (see {#close}).
      # @param screen [Tuile::Screen] the screen whose {Shared::AppTheme} colors
      #   the body — read here at build time on the UI thread.
      def initialize(question:, detail:, warnings:, editable:, clean:, channel:, screen:)
        @channel = channel
        @resolved = false
        @editable = editable
        @clean = clean
        window = Tuile::Component::Window.new('Confirm')
        window.content = build_body(question, detail, warnings, screen)
        super(content: window)
      end

      # Maps a key to an outcome and resolves. +y+/+yes+ approve (dropped
      # when editable+flagged — the sanitizer flagged the payload, so the
      # user must (re)author it), +e+ edit (editable only), +n+/+no+
      # reject, +r+ reject-with-reason. Everything else falls through to
      # {Tuile::Component::Popup#handle_key}, whose ESC/q declines (via
      # {#close}); other keys are swallowed by the modal so the user must
      # make an explicit choice.
      #
      # @param key [String]
      # @return [Boolean]
      def handle_key(key)
        case key.downcase
        when 'y', 'yes'
          return super if @editable && !@clean

          resolve(:approve)
        when 'e'
          return super unless @editable

          resolve(:edit)
        when 'n', 'no'
          resolve(:reject)
        when 'r'
          resolve(:reject_reason)
        else
          return super
        end
        true
      end

      # Closes the popup, then resolves +:reject+ (the decline-by-default)
      # if no explicit choice was made. Reached either via {#resolve}
      # (which has already set +@resolved+ and pushed, so the guard skips)
      # or the inherited ESC/q dismissal. +super+ is guarded by +open?+
      # because the base +Popup#close+ raises on a second call; together
      # with the +@resolved+ guard this makes a double-close safe.
      #
      # @return [void]
      def close
        super if open?
        return if @resolved

        @resolved = true
        @channel << :reject
      end

      private

      # @param outcome [Symbol] the user's explicit choice.
      # @return [void]
      def resolve(outcome)
        @resolved = true
        @channel << outcome
        close
      end

      # Build the body lines: sanitizer warnings (bold +:notice+ header +
      # one +:notice+ explanation each) when anything was flagged, then the
      # sanitized question (bold, default fg), the sanitized detail
      # (+:detail+ tone, per line) when present, and the key cue. Colors
      # come from the {Shared::AppTheme} +theme+ so they track light/dark; lines
      # are ANSI strings the +TextView+ re-parses via +StyledString.parse+.
      #
      # A +TextView+ (not a +List+) so long lines word-wrap and scroll
      # inside the popup instead of clipping. The popup is sized top-down
      # (half the screen; see {#initialize}), so the +TextView+ wraps to its
      # own granted width — no pre-wrapping here.
      #
      # @param question [Pikuri::Sanitizer::Result]
      # @param detail [Pikuri::Sanitizer::Result, nil]
      # @param warnings [Array<Pikuri::Sanitizer::Warning>]
      # @param screen [Tuile::Screen] supplies the {Shared::AppTheme} tones.
      # @return [Tuile::Component::TextView] the sanitized body.
      def build_body(question, detail, warnings, screen)
        theme = screen.theme
        lines = []
        unless warnings.empty?
          lines << Tuile::StyledString.styled('⚠ Suspicious content detected — read carefully before approving:',
                                              fg: theme[:notice], bold: true).to_ansi
          warnings.each { |w| lines << theme.notice("  ! #{w.explanation}") }
        end
        lines << Tuile::StyledString.styled(question.text, bold: true).to_ansi
        detail&.text&.split("\n")&.each { |line| lines << theme.detail(line) }
        lines << cue

        view = Tuile::Component::TextView.new
        view.text = lines.join("\n")
        view
      end

      # The key cue, tailored to the request. Editable+flagged omits +y+:
      # the payload was flagged, so authorship (edit) is forced.
      #
      # @return [String]
      def cue
        if @editable
          if @clean
            '(y) approve   (e) edit   (n) reject   (r) reject w/ reason'
          else
            '(e) edit   (n) reject   (r) reject w/ reason'
          end
        else
          '(y) approve   (n) reject   (r) reject w/ reason'
        end
      end
    end

    # A text-entry popup: a framed +Window+ (its caption doubles as the
    # instruction line) wrapping one editable {Tuile::Component::TextArea}.
    # Reused for both the edit prompt and the reason prompt. Enter submits
    # the field's text; ESC (or dismissal) cancels. Owns the answer channel,
    # resolving it exactly once.
    #
    # The popup is sized top-down: a wide box +rows+ tall (plus the +Window+'s
    # two border rows), so the field fills it and wraps/scrolls within.
    #
    # Built and driven on the UI thread — constructed inside the
    # {ConfirmerPopup#ask_prompt} +submit+ block.
    class PromptDialog < Tuile::Component::Popup
      # @param caption [String] window caption / instruction line.
      # @param initial [String] pre-fill text ("" for none).
      # @param rows [Integer] the field's visible height in rows.
      # @param channel [Queue] one-shot channel; the submitted text or
      #   +:cancel+ is pushed exactly once.
      # @param screen [Tuile::Screen] the screen the popup mounts on; its
      #   size sets the prompt's top-down width.
      def initialize(caption:, initial:, rows:, channel:, screen:)
        @channel = channel
        @resolved = false
        @field = Tuile::Component::TextArea.new
        @field.text = initial unless initial.empty?
        @field.on_key = method(:field_key)
        @field.on_escape = -> { resolve(:cancel) }
        window = Tuile::Component::Window.new(caption)
        window.content = @field
        # Wide box, rows tall + the Window's top/bottom border rows.
        super(content: window, size: Tuile::Size.new(screen.size.width * 4 / 5, rows + 2))
      end

      # Opens the popup and moves focus onto the field so keystrokes edit
      # it (the modal open focuses the popup itself; the field is deeper on
      # the focus chain, so focus it explicitly).
      #
      # @return [void]
      def open
        super
        screen.focused = @field
      end

      # Resolves +:cancel+ on a bare close (ESC/q dismissal) if the user
      # never submitted. Same double-close discipline as {Dialog#close}.
      #
      # @return [void]
      def close
        super if open?
        return if @resolved

        @resolved = true
        @channel << :cancel
      end

      # @return [Tuile::Component::TextArea] the entry field (for specs).
      attr_reader :field

      private

      # The +on_key+ interceptor: Enter submits the current text (the
      # field would otherwise insert a newline); every other key falls
      # through to normal editing.
      #
      # @param key [String]
      # @return [Boolean] true iff the key was consumed (Enter).
      def field_key(key)
        return false unless key == Tuile::Keys::ENTER

        resolve(@field.text)
        true
      end

      # @param value [String, Symbol] the submitted text or +:cancel+.
      # @return [void]
      def resolve(value)
        @resolved = true
        @channel << value
        close
      end
    end
  end
end
