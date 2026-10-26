# frozen_string_literal: true

require 'tuile'

# The bottom input pane: a borderless, permanently tinted well framing an
# editable {Area} (Enter submits, blank buffers are a no-op), with a static
# {MARKER} hanging off its left edge.
#
#   ❯ what about lifetimes                   <- MARKER, then the Area
#                                            <- HEIGHT rows, all editable
#
# The whole rect paints +:pane_bg+ — this is a *secondary* surface, set off
# against the untinted {Shared::ConversationTextView} above it — and it does so
# regardless of focus. Left alone, Tuile's
# {Tuile::Component::AbstractStringField} would paint a well of its own
# (+active_bg_color+ focused, +input_bg_color+ otherwise) — a second shade
# inside the pane, flipping as focus moves — so the {Area} is built with
# +bg_color = ComponentBackground::INHERIT+ and takes this pane's tint instead.
#
# The well is a permanent spatial anchor, not a focus cue — the *caret* is the
# focus cue, and it does the whole job. Focus leaves the prompt only for the
# {Shared::ConversationTextView} (to answer a {Shared::PendingDecision}), and an
# unfocused {Tuile::Component::TextView} publishes no cursor position, so the
# caret simply vanishes: "your keys go to the transcript now", stated without
# the labeled chips a multi-pane borderless app would need.
#
# The host builds one, drops it into the layout, and focuses it — {#focus}
# forwards to the private {Area}, since a {Tuile::Component::Layout} has no
# Window→content focus cascade to do it:
#
#   menu = Shared::SlashMenuPopup.new(screen:, commands:, conversation:)
#   pane = Shared::InputPane.new(on_submit: session.method(:submit),
#                                slash_menu: menu, conversation: conversation)
#   layout = Chat::Layout.new(conversation: conversation, status_rule: rule, input: pane)
#   pane.focus   # lands the caret in the Area
#
# With a +slash_menu+, the prompt also owns slash-command entry: the {Area}
# opens/filters the palette as the buffer changes, arbitrates Enter (a
# leading-+/+ buffer runs a command instead of submitting a turn), and forwards
# Up/Down/ESC to the palette while it's shown. The prompt is the natural owner —
# it already holds Enter and the buffer, and the {Area} is private, so nothing
# outside could arbitrate them.
#
# With a +conversation+, PageUp/PageDown page that pane half a screen — the
# transcript reads back without the caret leaving the prompt. A visible palette
# gets those keys first, to page its own list.
#
# {#capture} borrows the prompt for a one-off answer instead of a turn — a
# reason for rejecting a tool call, a rewritten sub-agent task. Prose is typed
# here and nowhere else, which is what keeps it away from anything that treats
# a keystroke as a decision.
#
# Shared by all three shells.
#
# UI-thread-confined.
class Shared::InputPane < Tuile::Component::Layout
  # The static prompt marker, drawn at the pane's very left edge in the
  # theme's {Shared::AppTheme::TALUS} hint accent. One row only — a wrapped
  # second line of the buffer sits under blank marker columns, so the marker
  # reads as the prompt's start rather than a per-line bullet.
  #
  # @return [String]
  MARKER = '❯'

  # Columns the marker owns: the glyph plus the space after it. The buffer
  # starts at this column, so it doubles as the prompt's *text* column — which
  # is what each shell's `Layout` insets the transcript by, lining the two up
  # with the marker hanging into the margin.
  #
  # @return [Integer]
  MARKER_WIDTH = 2

  # Columns of tinted padding at the right edge, so a full line doesn't butt
  # against the terminal's side. There is deliberately none on the left: the
  # marker sits flush, and the buffer's own left margin is {MARKER_WIDTH}.
  #
  # @return [Integer]
  TRAILING_PAD = 2

  # Rows the pane asks its layout for; all of them editable — the buffer
  # scrolls within them once a message runs longer.
  #
  # @return [Integer]
  HEIGHT = 3

  # @param on_submit [Proc, Method] one-arg callable invoked with the
  #   buffer text when the user presses Enter on a non-blank line; handed
  #   straight to the wrapped {Area}.
  # @param slash_menu [Shared::SlashMenuPopup, nil] the slash-command palette
  #   this prompt drives, or nil for a plain input. This pane becomes its
  #   anchor (the palette floats just above it).
  # @param conversation [Shared::ConversationTextView, nil] the transcript
  #   PageUp/PageDown page while the prompt holds focus, or nil to leave those
  #   keys to the {Tuile::Component::TextArea}.
  def initialize(on_submit:, slash_menu: nil, conversation: nil)
    super()
    @marker = Tuile::Component::Label.new
    @area = Area.new(on_submit: on_submit, slash_menu: slash_menu, conversation: conversation)
    add(@marker)
    add(@area)
    # A Theme::Ref re-resolves against the theme on every paint, so the tint
    # follows a light/dark flip with no hook of our own; the marker's tone is
    # baked into its text and does need {#handle_theme_changed}.
    self.bg_color = Tuile::Theme.ref(:pane_bg)
    @area.bg_color = Tuile::ComponentBackground::INHERIT
    slash_menu.anchor = self if slash_menu
    @capture_marker = nil
    rebuild_marker
  end

  # @return [Tuile::Component::TextArea] the editable area. Exposed for tests;
  #   production drives the prompt through +on_submit+ and {#focus}, and the
  #   {Area} class itself stays private so nothing outside can re-arbitrate the
  #   keys it owns.
  attr_reader :area

  # Focuses the editable area. The pane itself is passive layout; the {Area} is
  # what owns the caret and the keyboard, and unlike a
  # {Tuile::Component::Window} a {Tuile::Component::Layout} cascades nothing.
  #
  # @return [void]
  def focus = @area.focus

  # Borrow the prompt for one answer instead of a turn: swap the marker, hand
  # the buffer +initial+, and route the next Enter (or ESC) to +on_finish+
  # rather than to +on_submit+. The answer is not recorded in the history and a
  # leading +/+ stays literal — it is text, not a command.
  #
  #   input.capture(marker: '✎', initial: task) do |text|
  #     text.nil? ? reject : approve(text)   # nil = the user pressed ESC
  #   end
  #
  # @param marker [String] glyph shown in place of {MARKER} while capturing, so
  #   the prompt doesn't look like it is waiting for a message.
  # @param initial [String] pre-fill text.
  # @yieldparam text [String, nil] the submitted text (+""+ when the user sent
  #   an empty buffer), or +nil+ when the user cancelled with ESC.
  # @return [void]
  def capture(marker:, initial: '', &on_finish)
    @capture_marker = marker
    rebuild_marker
    @area.capture(initial: initial) do |text|
      @capture_marker = nil
      rebuild_marker
      on_finish.call(text)
    end
    # The caller may be answering from another pane, and a borrowed prompt with
    # no caret in it would look inert.
    focus
  end

  # @return [Boolean] whether the prompt is currently borrowed by {#capture}.
  def capturing? = @area.capturing?

  # End a {#capture} as if the user had pressed ESC — its callback runs with
  # +nil+. A no-op when the prompt isn't captured.
  #
  # @return [void]
  def cancel_capture
    @area.finish_capture(nil) if @area.capturing?
  end

  # The editable content: a {Tuile::Component::TextArea} that rebinds Enter
  # from "insert a newline" to "submit the buffer and clear it".
  #
  #   # Enter on "hi"   → on_submit.call("hi"), then the field clears
  #   # Enter on "   "  → no-op (a blank buffer can't burn a turn)
  #
  # Enter is line-at-a-time because pikuri's turn is, and Shift+Enter is not
  # used for a newline: most terminals don't distinguish it from a plain
  # Enter on the wire. Everything submitted also lands in a
  # {Shared::PromptHistory}: Up/Down recall it once the caret has nowhere left
  # to go in that direction, and ESC goes back to the draft. All other
  # TextArea behaviour (caret motion, word-jumps, backspace/delete) is
  # inherited unchanged. Private to {Shared::InputPane} — the pane is the only
  # public handle.
  class Area < Tuile::Component::TextArea
    # @param on_submit [Proc, Method] one-arg callable invoked when the
    #   user presses Enter on a non-blank buffer. Receives the buffer text
    #   *before* it is cleared; this class owns the clear, so callers don't
    #   wipe the input in their handler.
    # @param slash_menu [Shared::SlashMenuPopup, nil] the palette to drive, or
    #   nil for a plain input (then every slash branch below is skipped).
    # @param conversation [Shared::ConversationTextView, nil] the pane the page
    #   keys scroll, or nil to leave them unclaimed.
    def initialize(on_submit:, slash_menu:, conversation:)
      super()
      @on_submit = on_submit
      @slash_menu = slash_menu
      @conversation = conversation
      @history = Shared::PromptHistory.new
      @capture = nil
      # The palette follows the user's edits only: a recall or a clear is this
      # class's own write, and the paths that clear already closed it. No
      # palette while capturing either: a captured answer is prose, so a
      # leading slash is a character and not the start of a command. :eager,
      # because the palette filters per keystroke, not once the user is done.
      if slash_menu
        self.value_change_mode = :eager
        on_value_change { |e| slash_menu.sync(e.value) if e.from_user? && !@capture }
      end
      # ESC is history-then-clear here, never a blur: #escape owns all of it, so
      # the field's own blur is turned off rather than followed.
      self.escape_clears_focus = false
      on_escape << method(:escape)
    end

    # Route the next Enter / ESC to +on_finish+ instead of submitting a turn.
    #
    # @param initial [String] pre-fill text.
    # @yieldparam text [String, nil] submitted text, or +nil+ on ESC.
    # @return [void]
    def capture(initial:, &on_finish)
      # A palette left open by the abandoned draft would claim ESC, and ESC is
      # how the capture is cancelled. Closed before the flag goes up, since the
      # flag is what suppresses the sync.
      @slash_menu&.sync('')
      @capture = on_finish
      set_text_quietly(initial)
    end

    # @return [Boolean] whether a {#capture} is in progress.
    def capturing? = !@capture.nil?

    # End the capture, empty the buffer, then hand +value+ to its callback — in
    # that order, so a callback that starts a second capture wins.
    #
    # @param value [String, nil] the answer, or +nil+ when cancelled.
    # @return [Boolean] always true; Enter/ESC during a capture is ours.
    def finish_capture(value)
      capture = @capture
      @capture = nil
      set_text_quietly('')
      capture.call(value)
      true
    end

    # Route keys with the slash palette in mind, then fall through to
    # {Tuile::Component::TextArea#handle_key?}. Returns +true+ on a consumed key
    # so it isn't re-dispatched up the tree as something else. While a palette
    # is present: Up/Down/ESC drive it *only when shown* (otherwise they edit
    # normally), and Enter on a leading-+/+ buffer runs a command instead of
    # submitting a turn.
    #
    # @param key [String]
    # @return [Boolean] +true+ if the key was consumed here.
    def handle_key?(key)
      # A capture owns Enter outright: no palette, no blank-buffer no-op — an
      # empty answer is a meaningful one (a reason skipped, a task cleared).
      return finish_capture(text.dup) if @capture && key == Tuile::Keys::ENTER && active?

      if @slash_menu
        return @slash_menu.handle_nav_key(key) if nav_key?(key) && @slash_menu.visible?
        return submit_command if key == Tuile::Keys::ENTER && active? && text.start_with?('/')
      end
      return submit if key == Tuile::Keys::ENTER && active?
      return scroll_conversation(key) if @conversation && PAGE_KEYS.include?(key) && active?

      super
    end

    protected

    # Claim Up/Down for history recall, but only in the first/last row and only
    # when the store has something to give. Anything else — an exhausted edge
    # included — falls through to +super+, so with no history the prompt is a
    # plain {Tuile::Component::TextArea}, edge-snap included.
    #
    # @param key [String]
    # @return [Boolean] +true+ if the key was consumed here.
    def handle_text_input_key?(key)
      return super if @capture # a captured answer isn't a turn, so it has no history to walk

      if key == Tuile::Keys::UP_ARROW && caret_row.zero?
        return true if recall_older
      elsif key == Tuile::Keys::DOWN_ARROW && caret_row == row_count - 1
        return true if recall_newer
      end

      super
    end

    private

    # The keys that page the conversation pane, and that a visible palette
    # claims ahead of it for its own list — hence the two uses below.
    #
    # @return [Array<String>]
    PAGE_KEYS = [Tuile::Keys::PAGE_UP, Tuile::Keys::PAGE_DOWN].freeze
    private_constant :PAGE_KEYS

    # @param key [String]
    # @return [Boolean] whether the palette claims this key while shown.
    def nav_key?(key)
      [Tuile::Keys::UP_ARROW, Tuile::Keys::DOWN_ARROW, Tuile::Keys::ESC, *PAGE_KEYS].include?(key)
    end

    # Page the conversation pane by half a screen.
    #
    # @param key [String] +PAGE_UP+ or +PAGE_DOWN+.
    # @return [Boolean] always true — a scroll clamped at either edge still
    #   consumed the key.
    def scroll_conversation(key)
      if key == Tuile::Keys::PAGE_UP
        @conversation.scroll_half_page_up
      else
        @conversation.scroll_half_page_down
      end
      true
    end

    # ESC outside the palette, in place of the inherited blur (turned off with
    # {Tuile::Component::AbstractStringField#escape_clears_focus} in the
    # constructor): leave history if browsing, otherwise wipe the buffer.
    #
    # @return [void]
    def escape
      if @capture
        finish_capture(nil)
      elsif @history.at_draft?
        self.value = ''
      else
        recall(@history.jump_to_draft)
      end
    end

    # Step to the older entry, preserving the buffer as the draft first if
    # we're leaving it.
    #
    # @return [Boolean] whether an entry was recalled.
    def recall_older
      @history.draft = text.dup if @history.at_draft?
      recall(@history.older)
    end

    # @return [Boolean] whether an entry (or the draft) was recalled.
    def recall_newer = recall(@history.newer)

    # Show +entry+ with the caret at its end, without letting the slash palette
    # react — a recall is not typing, so a recalled +/command+ sits inert until
    # the user edits it or sends it.
    #
    # @param entry [String, nil] the text to show; +nil+ when the store had
    #   nothing at that end.
    # @return [Boolean] whether anything was recalled.
    def recall(entry)
      return false if entry.nil?

      set_text_quietly(entry)
      true
    end

    # Replace the buffer with the caret at its end. A +value=+ write is not the
    # user's, so the slash palette does not react.
    #
    # @param value [String]
    # @return [void]
    def set_text_quietly(value)
      self.value = value
      self.caret = text.length
    end

    # Record and run the slash command in the buffer, then clear the field.
    # Order matters:
    # {Shared::SlashMenuPopup#submit} resolves against the still-open palette
    # (so the highlighted row wins) *before* the clear closes it.
    #
    # @return [Boolean] always true; Enter on a slash buffer is ours.
    def submit_command
      command = text.dup
      @history.append(command)
      @slash_menu.submit(command)
      self.value = ''
      true
    end

    # Capture the buffer, record it, clear it, then hand off to the host
    # callback — in that order, so a handler that redraws synchronously sees an
    # empty input, and one that *raises* costs neither the clear nor the
    # history entry.
    #
    # @return [Boolean] always true; the host has decided Enter is a
    #   meaningful key for the input.
    def submit
      message = text.dup
      return true if message.strip.empty?

      @history.append(message)
      self.value = ''
      @on_submit.call(message)
      true
    end
  end

  private_constant :Area

  protected

  # Repaints the marker in the new theme's hint accent — its tone is baked into
  # the label's text, so a light/dark flip has to re-run it.
  #
  # @return [void]
  def handle_theme_changed
    super
    rebuild_marker
  end

  private

  # Lays the marker and the editable area out across the tinted well: the
  # marker on the first row at the very left edge, the area filling the rest
  # bar {TRAILING_PAD} columns. The base {Tuile::Component#repaint} fills
  # whatever the two children don't cover with {#bg_color} — which is what
  # paints the trailing pad and the rows under the marker.
  #
  # @return [void]
  def relayout
    @marker.rect = Tuile::Rect.new(0, 0, [MARKER_WIDTH, width].min, [1, height].min)
    @area.rect = Tuile::Rect.new(MARKER_WIDTH, 0, [width - MARKER_WIDTH - TRAILING_PAD, 0].max, height)
  end

  # Re-renders the marker label; its accent is baked into the text.
  # @return [void]
  def rebuild_marker
    @marker.text = screen.theme.hint(@capture_marker || MARKER)
  end
end
