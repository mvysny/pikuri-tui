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
# Driven entirely by the {Shared::InputWindow} that owns it — the popup never
# takes focus (the caret stays in the field). The window wires three verbs:
#
#   menu = Shared::SlashMenuPopup.new(
#     screen: screen, commands: cmds, conversation: conversation_window)
#   menu.sync(buffer)              # on every keystroke: open/filter/close
#   menu.handle_nav_key(key)       # Up/Down move the selection, ESC closes
#   menu.submit(buffer)            # Enter: run the selected/typed command
#
# This is one self-sufficient component: it holds the catalog, filters it,
# renders it, tracks the selection, executes the command, and echoes the
# outcome to the conversation pane. If skill commands later need the agent and
# a skills catalog, split a non-widget service out of {#submit} and leave this
# to only *pick* a command — until then one box is simpler.
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
# Geometry is owned by {#reposition} (the Tuile hook called on open and on
# every layout pass, so it tracks SIGWINCH): full screen width less one column
# each edge, {HEIGHT} tall, its bottom edge just above the {#anchor} input. The
# base {Tuile::Component::Popup} default +size+ is unused — reposition assigns
# the rect outright.
#
# {#submit} resolves the command *before* the caller clears the buffer (the
# {Shared::InputWindow} calls submit first, then wipes the field), so the
# highlighted row is still valid: a partial +"/di"+ with +/diff+ highlighted
# runs +/diff+. The callback runs one tick later (via the event queue) so a
# command that opens its own popup (+/diff+) doesn't stack under this one
# closing. The outcome echo is a plain {Shared::ConversationWindow#add_block} —
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

  # The input window the palette floats above; its rect gives the bottom edge
  # to anchor to. Set by the {Shared::InputWindow} that owns this popup. When
  # nil (bare use / tests) the palette anchors to the screen bottom.
  # @return [Tuile::Component::Window, nil]
  attr_accessor :anchor

  # @param screen [Tuile::Screen] mounts the popup, defers callbacks, resolves
  #   the theme and screen size.
  # @param commands [Array<Shared::SlashCommand>] the full catalog.
  # @param conversation [Shared::ConversationWindow] where command echoes and
  #   outcomes are written (never the agent context).
  def initialize(screen:, commands:, conversation:)
    # Set before +super+: {Tuile::Component::Popup#initialize} calls {#reposition},
    # which reads @screen and @anchor.
    @screen = screen
    @conversation = conversation
    @anchor = nil
    @matches = []
    super() # builds the non-focusable list, the :input_bg_color tint, the cursor
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

  # Reconcile the palette with the current buffer: open + refilter when +text+
  # is a slash command with matches, otherwise close. Called on every buffer
  # change; the selection resets to the top match on each refilter (arrow keys
  # don't change the text, so they don't reset it).
  # @param text [String] the whole input buffer.
  # @return [void]
  def sync(text)
    matches = text.start_with?('/') ? matching(text) : []
    if matches.empty?
      close if open?
      return
    end

    @matches = matches
    self.lines = matches.map { |c| row(c) }
    self.cursor = Tuile::Component::List::Cursor.new
    open unless open?
    reposition
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

  # Run the command +text+ names and echo the result to the conversation pane.
  # Resolve prefers the highlighted row while the palette is open, else an exact
  # first-word match; an unknown command echoes a red "Command not found" and
  # runs nothing. Either way the agent is never touched. Closes the palette.
  # @param text [String] the whole input buffer (must start with +/+).
  # @return [void]
  def submit(text)
    command = resolve(text)
    close if open?
    if command
      # Deferred so a command opening its own popup (/diff) doesn't stack under
      # this one closing; its return value is the outcome shown below the name.
      @screen.event_queue.submit do
        outcome = command.callback.call
        @conversation.add_block(echo(command.name, outcome))
      end
    else
      @conversation.add_block(echo(first_word(text), theme.error('Command not found')))
    end
  end

  # Full width less {PAD} each edge, {HEIGHT} tall, bottom edge just above the
  # {#anchor} input (screen bottom when unset). Overrides the base so the
  # palette owns its own geometry on open and every layout pass (tracks resize).
  # @return [void]
  def reposition
    screen_size = @screen.size
    width = [screen_size.width - (PAD * 2), 1].max
    bottom = anchor ? anchor.rect.top : screen_size.height
    top = [bottom - HEIGHT, 0].max
    self.rect = Tuile::Rect.new(PAD, top, width, HEIGHT)
  end

  private

  # Commands whose name starts with the buffer's first whitespace word, so a
  # future +"/cmd args"+ still narrows on +/cmd+.
  # @param text [String]
  # @return [Array<Shared::SlashCommand>]
  def matching(text)
    word = first_word(text)
    @commands.select { |c| c.name.start_with?(word) }
  end

  # The command +text+ should run: the highlighted match while open (so a
  # partial name completes to the selection), else an exact first-word match.
  # @param text [String]
  # @return [Shared::SlashCommand, nil]
  def resolve(text)
    if open? && !@matches.empty?
      pos = cursor.position
      return @matches[pos] if pos.between?(0, @matches.size - 1)
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
  # @return [String] ANSI, parsed by the list.
  def row(command)
    "#{theme.tool(command.name.ljust(@name_width))}  #{theme.detail(command.description)}"
  end

  # The conversation echo for a run command: its name in the tool tone with the
  # outcome (already colored, or nil) on the line below.
  # @param name [String]
  # @param outcome [String, nil]
  # @return [String]
  def echo(name, outcome)
    outcome ? "#{theme.tool(name)}\n#{outcome}" : theme.tool(name)
  end

  # @return [Shared::AppTheme]
  def theme = @screen.theme
end
