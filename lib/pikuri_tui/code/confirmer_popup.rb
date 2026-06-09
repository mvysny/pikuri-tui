# frozen_string_literal: true

require 'pikuri-core'
require 'pikuri-workspace'
require 'tuile'

module PikuriTui
  module Code
    # A {Pikuri::Workspace::Confirmer} that asks the user via a modal
    # Tuile popup instead of stdin — the TUI equivalent of
    # {Pikuri::Workspace::Confirmer::Terminal}. Wired into the coding
    # shell's +Write+ and +Pikuri::Code::Bash+ tools so a write-overwrite
    # or a bash command pauses for a y/n before it runs.
    #
    # == Threading (the hard part)
    #
    # {#confirm?} is called *synchronously by the tool*, and the tool runs
    # on the agent worker thread (per CLAUDE.md the agent loop never runs
    # on the UI thread). But every UI mutation — building the popup,
    # opening it — must run on the thread that owns +run_event_loop+. So
    # {#confirm?}:
    #
    # 1. creates a one-shot +Queue+ as the cross-thread answer channel,
    # 2. +screen.event_queue.submit+s a block that builds and opens the
    #    {Dialog} on the UI thread, and
    # 3. blocks the worker on +Queue#pop+ until a key on the UI thread
    #    resolves the dialog.
    #
    # The blocking is deliberate and correct: the tool's contract is a
    # synchronous Boolean return, and the worker thread is exactly the one
    # that should park while the user decides — the UI thread stays free
    # to paint the popup and process the keypress that unblocks it.
    # +Queue+ (not a bare ivar + flag) gives a memory-safe hand-off with
    # no busy-wait.
    #
    # == Sanitizing
    #
    # +request.question+ and +request.detail+ are RAW LLM-composed bytes
    # (see {Pikuri::Workspace::Confirmer::Request}). They pass through
    # {Pikuri::Sanitizer} — the same chrome-independent primitive
    # +Confirmer::Terminal+ uses — which (a) neutralizes the dangerous
    # bytes for literal display (control bytes → +\xNN+, bidi/zero-width →
    # +\u{NNNN}+, tab → +\t+, newline preserved) so a crafted command
    # containing +"\rrm -rf ~/"+ can't visually overwrite the echoed line
    # after the user has read it, and (b) returns a
    # {Pikuri::Sanitizer::Warning} per attack class detected. The
    # {Dialog} surfaces those warnings — bold-yellow header + each
    # plain-English explanation — above the question, so the user reads
    # *why* the content is suspicious before answering. Rendering the
    # warnings is this TUI chrome's call; the +Warning+ carries plain
    # text only.
    #
    # == Decline-by-default
    #
    # Pressing +y+/+yes+ approves; +n+/+no+, +ESC+, or +q+ decline.
    # Dismissing the popup any other way (the base +Popup+ closes on
    # ESC/q) also declines — {Dialog#close} pushes +false+ if no explicit
    # answer was given, mirroring +Confirmer::Terminal+'s EOF-is-+false+
    # rule. There is no "approve" default: a destructive operation should
    # never run because the user looked away.
    class ConfirmerPopup < Pikuri::Workspace::Confirmer
      # @param screen [Tuile::Screen] the screen whose +event_queue+
      #   marshals popup construction to the UI thread. The same screen
      #   the host runs its event loop on.
      def initialize(screen:)
        super()
        @screen = screen
      end

      # Pose +request+ as a modal popup and block the calling (worker)
      # thread until the user answers. Safe to call from any thread
      # *except* the UI thread — calling it there would deadlock, since
      # the submitted block can't run until the event loop drains and the
      # event loop is blocked here on +Queue#pop+. Tools always call it
      # from the worker, so this holds.
      #
      # @param request [Pikuri::Workspace::Confirmer::Request] semantic
      #   content composed by the calling tool; rendered (escaped) here.
      # @return [Boolean] +true+ iff the user approved.
      def confirm?(request:)
        answer = Queue.new
        @screen.event_queue.submit do
          Dialog.new(request: request, answer: answer, screen: @screen).open
        end
        answer.pop
      end

      # The modal dialog itself: a framed +Window+ captioned "Confirm",
      # wrapping a +TextView+ of any sanitizer warnings, the sanitized
      # question, the optional sanitized detail (split per line), and a
      # y/n cue. Owns the answer channel: +y+/+n+ resolve it; the
      # inherited ESC/q close declines.
      #
      # Built and driven entirely on the UI thread — constructed inside
      # the {ConfirmerPopup#confirm?} +submit+ block, and its
      # {#handle_key} / {#close} fire from Tuile's key dispatch, which is
      # the UI thread.
      class Dialog < Tuile::Component::Popup
        # @param request [Pikuri::Workspace::Confirmer::Request]
        # @param answer [Queue] one-shot channel; the resolved Boolean is
        #   pushed exactly once (see {#close}).
        # @param screen [Tuile::Screen] the screen whose {AppTheme} colors
        #   the body — read here at build time on the UI thread.
        def initialize(request:, answer:, screen:)
          @answer = answer
          @resolved = false
          window = Tuile::Component::Window.new('Confirm')
          window.content = build_body(request, screen)
          super(content: window)
        end

        # +y+/+yes+ approve, +n+/+no+ decline — both resolve and close.
        # Everything else falls through to
        # {Tuile::Component::Popup#handle_key}, whose ESC/q closes the
        # popup (declining via {#close}); other keys are swallowed by the
        # modal and ignored, so the user must make an explicit choice.
        #
        # @param key [String]
        # @return [Boolean]
        def handle_key(key)
          case key.downcase
          when 'y', 'yes'
            resolve(true)
            true
          when 'n', 'no'
            resolve(false)
            true
          else
            super
          end
        end

        # Closes the popup, then pushes the answer to the channel exactly
        # once. Reached either via {#resolve} (which has already set
        # +@resolved+ and pushed, so the guard skips the push) or via the
        # inherited ESC/q dismissal (+@resolved+ still false → push
        # +false+, the decline-by-default). +super+ is guarded by +open?+
        # because the base +Popup#close+ raises on a second call rather
        # than no-opping; together with the +@resolved+ guard this makes
        # a double-close safe (no second push, no raise).
        #
        # @return [void]
        def close
          super if open?
          return if @resolved

          @resolved = true
          @answer << false
        end

        private

        # @param value [Boolean] the user's explicit choice
        # @return [void]
        def resolve(value)
          @resolved = true
          @answer << value
          close
        end

        # Build the body lines: sanitizer warnings (bold +:notice+ header +
        # one +:notice+ explanation each) when anything was flagged, then
        # the sanitized question (bold, default fg), the sanitized detail
        # (+:detail+ tone, split per line) when present, and the y/n cue.
        # Colors come from the {AppTheme} +theme+ so they track light/dark;
        # lines are ANSI strings (built via {Tuile::StyledString}) that the
        # +TextView+ re-parses via +StyledString.parse+, matching
        # +Confirmer::Terminal+'s rendering and {App}'s own error line.
        #
        # A +TextView+ (not a +List+) so long lines — a multi-line bash
        # command, a wide path — word-wrap inside the popup instead of being
        # clipped at the right edge. Each logical line is pre-wrapped here to
        # the popup's eventual inner width: the +Popup+ derives its height
        # from {Tuile::Component::TextView#content_size}, which counts
        # *unwrapped* hard lines, so feeding raw long lines would size the
        # popup too short and push the y/n cue out of view. Wrapping up front
        # makes the hard-line count match the rendered row count.
        #
        # No blank spacer lines: the dialog is intentionally compact.
        #
        # @param request [Pikuri::Workspace::Confirmer::Request]
        # @param screen [Tuile::Screen] supplies the {AppTheme} +:notice+ /
        #   +:detail+ tones and the width the body is pre-wrapped to.
        # @return [Tuile::Component::TextView] the sanitized, wrapped body
        def build_body(request, screen)
          theme = screen.theme
          question = Pikuri::Sanitizer.sanitize(request.question)
          detail   = request.detail ? Pikuri::Sanitizer.sanitize(request.detail) : nil
          warnings = question.warnings + (detail ? detail.warnings : [])

          lines = []
          unless warnings.empty?
            lines << Tuile::StyledString.styled('⚠ Suspicious content detected — read carefully before approving:',
                                                fg: theme[:notice], bold: true).to_ansi
            warnings.each { |w| lines << theme.notice("  ! #{w.explanation}") }
          end
          lines << Tuile::StyledString.styled(question.text, bold: true).to_ansi
          detail&.text&.split("\n")&.each { |line| lines << theme.detail(line) }
          lines << '(y) yes   (n) no'

          view = Tuile::Component::TextView.new
          view.text = wrap_lines(lines, body_width(screen)).join("\n")
          view
        end

        # Word-wrap each ANSI +line+ to +width+ columns, preserving its
        # styling across the wrap (via {Tuile::StyledString#wrap}), and
        # return the flattened list of physical lines as ANSI strings.
        #
        # @param lines [Array<String>] ANSI-encoded logical lines.
        # @param width [Integer] column width to wrap to.
        # @return [Array<String>] ANSI-encoded physical (wrapped) lines.
        def wrap_lines(lines, width)
          lines.flat_map do |line|
            Tuile::StyledString.parse(line).wrap(width).map(&:to_ansi)
          end
        end

        # The inner content width the body is pre-wrapped to: the popup grows
        # to at most 4/5 of the screen width (see
        # +Tuile::Component::Popup#update_rect+), minus the +Window+'s two
        # border columns. Floored at a sane minimum so a tiny terminal still
        # wraps rather than dividing by a non-positive width.
        #
        # @param screen [Tuile::Screen]
        # @return [Integer]
        def body_width(screen)
          [(screen.size.width * 4 / 5) - 2, 20].max
        end
      end
    end
  end
end
