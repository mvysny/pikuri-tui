# frozen_string_literal: true

require 'tuile'

# The bottom input pane, framed: a {Tuile::Component::Window} captioned
# "Prompt" wrapping an editable {Area} (Enter submits, blank buffers are a
# no-op). Frames the input the way {Shared::ConversationWindow} frames the
# transcript — the host builds one, drops it into the layout, and focuses
# the *window*; Tuile's Window→content focus cascade (+HasContent#on_focus+)
# lands focus on the inner {Area}, so there is no focus plumbing to expose
# here:
#
#   menu = Shared::SlashMenuPopup.new(screen:, commands:, conversation:)
#   win  = Shared::InputWindow.new(on_submit: session.method(:submit),
#                                  slash_menu: menu, conversation: conversation_window)
#   layout = Chat::Layout.new(conversation: conversation_window, input: win)
#   screen.focused = win   # cascades onto the inner Area
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
# Shared by all three shells.
#
# UI-thread-confined.
class Shared::InputWindow < Tuile::Component::Window
  # Border caption. Not a constructor parameter — all three shells frame
  # the input identically.
  #
  # @return [String]
  TITLE = 'Prompt'

  # @param on_submit [Proc, Method] one-arg callable invoked with the
  #   buffer text when the user presses Enter on a non-blank line; handed
  #   straight to the wrapped {Area}.
  # @param slash_menu [Shared::SlashMenuPopup, nil] the slash-command palette
  #   this prompt drives, or nil for a plain input. This window becomes its
  #   anchor (the palette floats just above it).
  # @param conversation [Shared::ConversationWindow, nil] the transcript
  #   PageUp/PageDown page while the prompt holds focus, or nil to leave those
  #   keys to the {Tuile::Component::TextArea}.
  def initialize(on_submit:, slash_menu: nil, conversation: nil)
    super(TITLE)
    self.content = Area.new(on_submit: on_submit, slash_menu: slash_menu, conversation: conversation)
    slash_menu.anchor = self if slash_menu
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
  # inherited unchanged. Private to {InputWindow} — the frame is the only
  # public handle.
  class Area < Tuile::Component::TextArea
    # @param on_submit [Proc, Method] one-arg callable invoked when the
    #   user presses Enter on a non-blank buffer. Receives the buffer text
    #   *before* it is cleared; this class owns the clear, so callers don't
    #   wipe the input in their handler.
    # @param slash_menu [Shared::SlashMenuPopup, nil] the palette to drive, or
    #   nil for a plain input (then every slash branch below is skipped).
    # @param conversation [Shared::ConversationWindow, nil] the pane the page
    #   keys scroll, or nil to leave them unclaimed.
    def initialize(on_submit:, slash_menu:, conversation:)
      super()
      @on_submit = on_submit
      @slash_menu = slash_menu
      @conversation = conversation
      @history = Shared::PromptHistory.new
      @recalling = false
      self.on_change = ->(text) { slash_menu.sync(text) unless @recalling } if slash_menu
      self.on_escape = method(:escape)
    end

    # Route keys with the slash palette in mind, then fall through to
    # {Tuile::Component::TextArea#handle_key}. Returns +true+ on a consumed key
    # so it isn't re-dispatched up the tree as something else. While a palette
    # is present: Up/Down/ESC drive it *only when shown* (otherwise they edit
    # normally), and Enter on a leading-+/+ buffer runs a command instead of
    # submitting a turn.
    #
    # @param key [String]
    # @return [Boolean] +true+ if the key was consumed here.
    def handle_key(key)
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
    def handle_text_input_key(key)
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

    # ESC outside the palette, in place of the inherited clear-focus default:
    # leave history if browsing, otherwise wipe the buffer.
    #
    # @return [void]
    def escape
      if @history.at_draft?
        self.text = ''
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

      @recalling = true
      self.text = entry
      self.caret = text.length
      true
    ensure
      @recalling = false
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
      self.text = ''
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
      self.text = ''
      @on_submit.call(message)
      true
    end
  end

  private_constant :Area
end
