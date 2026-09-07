# frozen_string_literal: true

# The transcript-density submenu — a {Shared::LeaderMenu} whose labels carry
# live state, lazyvim's +<leader>u+ retargeted at Tuile. Hang it off the
# leader menu:
#
#   ui = Shared::UIToggleMenu.new(screen: screen, conversation: conversation)
#   menu.add('u', 'UI toggles') { ui.open }
#
#   Ctrl+K  u
#   ┌ UI ─────────────────────┐
#   │ t  thinking: shown      │
#   │ v  tool lines: short    │
#   └─────────────────────────┘
#
# Each entry flips one {Shared::ConversationTextView} display flag, a session
# override of a +[ui]+ config default that is never written back.
#
# A submenu rather than two more top-level keys, and worth the extra keystroke
# only because there are two: it keeps the leader menu a list of *actions*
# (open the logs, clear the conversation) rather than a mix of actions and
# settings, and puts the two preferences where they read against each other.
#
# UI-thread-confined.
class Shared::UIToggleMenu
  # The submenu popup's caption.
  # @return [String]
  CAPTION = 'UI'

  # @param screen [Tuile::Screen] the screen the popup mounts on.
  # @param conversation [Shared::ConversationTextView] the pane whose display
  #   flags these entries flip.
  def initialize(screen:, conversation:)
    @menu = Shared::LeaderMenu.new(screen: screen, caption: CAPTION)
    @menu.add('t', -> { "thinking: #{conversation.show_thinking ? 'shown' : 'hidden'}" }) do
      conversation.toggle_thinking
    end
    @menu.add('v', -> { "tool lines: #{conversation.tool_detail}" }) { conversation.toggle_tool_detail }
  end

  # @return [void]
  def open = @menu.open

  # @return [Array<Shared::LeaderMenu::Action>] the toggle entries, in display
  #   order. Exposed for tests.
  def actions = @menu.actions
end
