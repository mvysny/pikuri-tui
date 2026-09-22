# frozen_string_literal: true

require 'tuile'

# The slash-command palette: a non-modal overlay that appears while the prompt
# buffer starts with +/+, lists the matching commands in two columns, and runs
# the picked one. A borderless full-width bar floating just above the input:
#
#    /diff   show the git diff
#    /exit   quits the app
#    /quit   quits the app
#    <name>  <description>
#
# Driven entirely by the {Shared::InputPane} that owns it — the popup never
# takes focus (the caret stays in the field). The window wires three verbs:
#
#   menu = Shared::SlashMenuPopup.new(
#     screen: screen, commands: cmds, conversation: conversation_window)
#   menu.sync(buffer)              # on every keystroke: open/filter/close
#   menu.handle_nav_key(key)       # Up/Down move the selection, ESC closes
#   menu.submit(buffer)            # Enter: run the selected/typed command
#
# This is one self-sufficient component: it holds the catalog, filters it,
# renders it, tracks the selection, splits +"/name rest"+, runs the command with
# +rest+, and echoes any outcome to the conversation pane. It stays generic
# across command *kinds* — a skill command carries its agent/catalog wiring in
# its own {Shared::SlashCommand} callback (built by the shell), so this box only
# resolves-and-calls. Should those callbacks ever bloat, split a non-widget
# service out and leave this to only *pick* a command; until then one box is
# simpler.
#
# The panel *is* a {Tuile::Component::ListDropdown} — Tuile's reusable
# "borderless, tinted, non-focusable floating list an input drops open" building
# block, the panel half of {Tuile::Component::ComboBox}. The parent owns the
# wrapped list, the {Tuile::Theme#input_bg_color} tint, the non-focusable /
# never-steals-the-caret contract, and key-forwarding ({#move} / {#choose}); the
# palette adds only the driver-specific parts that vary per dropdown — filtering,
# two-column row rendering, geometry, and running the picked command.
#
# == Implementation details
#
# Geometry is the placement's ({AboveAnchor}, or {AtBottom} with no {#anchor}):
# full screen width less one column each edge, {HEIGHT} tall, bottom edge just
# above the anchor. The {Tuile::ScreenPane} runs it on every layout pass, so it
# tracks a resize and the input moving.
#
# {#submit} resolves the command *before* the caller clears the buffer (the
# {Shared::InputPane} calls submit first, then wipes the field), so the
# highlighted row is still valid: a partial +"/di"+ with +/diff+ highlighted
# runs +/diff+. The callback runs one tick later (via the event queue) so a
# command that opens its own popup (+/diff+) doesn't stack under this one
# closing. The outcome echo is a plain {Shared::ConversationTextView#add_block} —
# it never reaches the agent's message history.
#
# UI-thread-confined.
class Shared::SlashMenuPopup < Tuile::Component::ListDropdown
  # Blank columns kept clear on each edge; the requested "1 char padding".
  # @return [Integer]
  PAD = 1

  # Fixed row count of the palette, matches spec.
  # @return [Integer]
  HEIGHT = 10

  # The palette's rect for a bar whose bottom edge sits at row +bottom+.
  # @param bottom [Integer] the screen row the palette ends just above.
  # @param screen_size [Tuile::Size]
  # @return [Tuile::Rect]
  def self.bar_above(bottom, screen_size)
    width = [screen_size.width - (PAD * 2), 1].max
    Tuile::Rect.new(PAD, [bottom - HEIGHT, 0].max, width, HEIGHT)
  end

  # Places the palette just above +anchor+. Answering {#anchor_rect} makes the
  # {Tuile::ScreenPane} follow the anchor as it moves.
  AboveAnchor = Data.define(:anchor) do
    # @return [Tuile::Rect, nil] the anchor in screen coordinates; nil while it,
    #   or any ancestor, is hidden or detached.
    def anchor_rect
      node = anchor
      until node.nil?
        return nil unless node.visible?

        node = node.parent
      end
      anchor.attached? ? anchor.absolute_extent_rect : nil
    end

    # @param _popup [Shared::SlashMenuPopup]
    # @param screen_size [Tuile::Size]
    # @return [Tuile::Rect]
    def rect_for(_popup, screen_size) = Shared::SlashMenuPopup.bar_above(anchor_rect.top, screen_size)
  end

  # Places the palette just above the bottom screen edge, for the bare use.
  AtBottom = Data.define do
    # @param _popup [Shared::SlashMenuPopup]
    # @param screen_size [Tuile::Size]
    # @return [Tuile::Rect]
    def rect_for(_popup, screen_size) = Shared::SlashMenuPopup.bar_above(screen_size.height, screen_size)
  end

  # The input the palette floats above, set by the {Shared::InputPane} that owns
  # it before the first open. When nil (bare use / tests) the palette sits at
  # the screen bottom.
  # @return [Tuile::Component, nil]
  attr_accessor :anchor

  # @param screen [Tuile::Screen] mounts the popup, defers callbacks, resolves
  #   the theme and screen size.
  # @param commands [Array<Shared::SlashCommand>] the full catalog.
  # @param conversation [Shared::ConversationTextView] where command echoes and
  #   outcomes are written (never the agent context).
  def initialize(screen:, commands:, conversation:)
    @screen = screen
    @conversation = conversation
    @anchor = nil
    super() # builds the non-focusable list, the :input_bg_color tint, the cursor
    # The list holds the SlashCommands themselves and renders them on demand, so
    # the highlighted row resolves straight to a command — no parallel array.
    self.renderer = method(:row)
    self.commands = commands
  end

  # Replaces the command catalog and recomputes the name-column width.
  # @param commands [Array<Shared::SlashCommand>]
  # @return [void]
  def commands=(commands)
    @commands = commands
    @name_width = commands.map { |c| c.name.length }.max || 0
  end

  # @return [Boolean] whether the palette is currently shown.
  def visible? = open?

  # Reconcile the palette with the current buffer: open + refilter while +text+
  # is a bare command token (leading +/+, no whitespace yet) with matches,
  # otherwise close. Once the user types a space they've committed to a command
  # and are writing its follow-up message, so the palette gets out of the way —
  # Enter still runs the command (parsed in {#submit}), but there's nothing left
  # to pick. Called on every buffer change; the selection resets to the top
  # match on each refilter (arrow keys don't change the text, so they don't
  # reset it).
  # @param text [String] the whole input buffer.
  # @return [void]
  def sync(text)
    matches = picking?(text) ? matching(text) : []
    if matches.empty?
      close if open?
      return
    end

    self.items = matches
    self.cursor = Tuile::Component::List::Cursor.new
    open unless open?
  end

  # Move the selection or dismiss while the palette is open. Called by the
  # input's key forwarder, not by dispatch — the list is unfocused, so movement
  # rides {Tuile::Component::ListDropdown#move} (which forwards to the list
  # regardless of focus); ESC is driver-owned (dismiss), so {#move} never claims
  # it and this does.
  # @param key [String]
  # @return [Boolean] true iff the key was consumed here.
  def handle_nav_key(key)
    return true if move(key)
    return false unless key == Tuile::Keys::ESC

    close
    true
  end

  # Run the command +text+ names, passing the rest of the line as its argument,
  # and echo any outcome to the conversation pane. +"/name the rest"+ splits
  # into the command (resolved: the highlighted row while the palette is open,
  # else an exact first-word match) and +"the rest"+ (+""+ when none), which is
  # handed to the callback — an action command ignores it, a skill command sends
  # it as a follow-up message. A truthy return is echoed below the name; a nil
  # return echoes nothing (the command's own effect — a popup, an agent turn —
  # is the feedback). An unknown command echoes a red "Command not found" and
  # runs nothing. Either way the agent context is never written directly. Closes
  # the palette.
  # @param text [String] the whole input buffer (must start with +/+).
  # @return [void]
  def submit(text)
    command = resolve(text)
    close if open?
    if command
      rest = remainder(text)
      # Deferred so a command opening its own popup (/diff) doesn't stack under
      # this one closing; its return value is the outcome shown below the name.
      @screen.event_queue.submit do
        outcome = command.callback.call(rest)
        @conversation.add_block(echo(command.name, outcome)) if outcome
      end
    else
      @conversation.add_block(echo(first_word(text), theme.error('Command not found')))
    end
  end

  # What {#open} places the palette with.
  # @return [AboveAnchor, AtBottom]
  def default_placement = anchor ? AboveAnchor.new(anchor: anchor) : AtBottom.new

  private

  # Whether the buffer is still a command being *picked*: a leading +/+ with no
  # whitespace yet. A space means the user has moved on to the command's
  # argument, so the palette closes (see {#sync}).
  # @param text [String]
  # @return [Boolean]
  def picking?(text) = text.start_with?('/') && !text.match?(/\s/)

  # Commands whose name starts with the (whole, space-free) buffer.
  # @param text [String]
  # @return [Array<Shared::SlashCommand>]
  def matching(text)
    @commands.select { |c| c.name.start_with?(text) }
  end

  # The text after the command name — the follow-up argument. +""+ when the
  # buffer is a bare command (+"/foo"+ → +""+, +"/foo a b"+ → +"a b"+).
  # @param text [String]
  # @return [String]
  def remainder(text) = text.to_s.split(/\s+/, 2)[1].to_s

  # The command +text+ should run: the highlighted match while open (so a
  # partial name completes to the selection), else an exact first-word match.
  # @param text [String]
  # @return [Shared::SlashCommand, nil]
  def resolve(text)
    if open? && !items.empty?
      pos = cursor.position
      return items[pos] if pos.between?(0, items.size - 1)
    end
    @commands.find { |c| c.name == first_word(text) }
  end

  # @param text [String]
  # @return [String] the leading whitespace-delimited word (the command name).
  def first_word(text) = text.to_s.split.first.to_s

  # A two-column list row: name padded to the widest name in the tool tone,
  # description in the dim detail tone. Padded before coloring so the SGR codes
  # don't throw off the column width.
  # @param command [Shared::SlashCommand]
  # @param _width [Integer] the columns the list gives the row, unused — a long
  #   description takes the list's trailing ellipsis.
  # @return [String] ANSI, parsed by the list.
  def row(command, _width)
    "#{theme.tool(command.name.ljust(@name_width))}  #{theme.detail(command.description)}"
  end

  # The conversation echo for a run command: its name in the tool tone with the
  # already-colored outcome on the line below. Only called with a real outcome
  # ({#submit} skips the echo entirely when the callback returns nil).
  # @param name [String]
  # @param outcome [String]
  # @return [String]
  def echo(name, outcome)
    "#{theme.tool(name)}\n#{outcome}"
  end

  # @return [Shared::AppTheme]
  def theme = @screen.theme
end
