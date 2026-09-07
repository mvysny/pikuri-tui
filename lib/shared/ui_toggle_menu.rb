# frozen_string_literal: true

# The transcript-density submenu, opened from the leader menu's +u+ entry in
# all three shells. A second {Shared::LeaderMenu} whose labels carry live
# state, lazyvim's +<leader>u+ retargeted at Tuile:
#
#   Ctrl+K  u
#   ┌ UI ─────────────────────┐
#   │ t  thinking: shown      │
#   │ v  tool lines: short    │
#   └─────────────────────────┘
#
#   ui = Shared::UIToggleMenu.new(screen: screen, conversation: conversation)
#   menu.add('u', 'UI toggles') { ui.open }
#
# Both entries flip a display flag on the conversation pane, which redraws
# what is already in the transcript. A submenu rather than two more top-level
# leader keys: display preferences are a family, they read best next to each
# other with their current values showing, and the top level stays a list of
# *actions* (open the logs, clear the conversation) rather than a mix of
# actions and settings. It earns the extra keystroke only because there are
# two of them — one toggle belongs at the top level.
#
# Every entry here is a *session* override of a +[ui]+ config default and is
# never written back (see {Shared::Config}).
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
