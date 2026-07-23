# frozen_string_literal: true

# One slash command: the typed name, the autocomplete hint, and the action.
#
#   Shared::SlashCommand.new('/diff', 'show the git diff',
#                            -> { sidebar.open_diff; 'Opened the git diff.' })
#
# The +description+ is the right-column hint in the {Shared::SlashMenuPopup}
# list; the +callback+'s *return value* is a separate string — the outcome
# shown below the command in the conversation pane once it runs (nil for none).
# So the hint ("show the git diff") and the effect report ("Opened the git
# diff.") are distinct, and a command can report a dynamic result.
#
# Sibling of {Shared::LeaderMenu::Action}; each shell registers its own set.
#
# @!attribute [r] name
#   @return [String] the command as typed, leading slash included (+"/diff"+).
# @!attribute [r] description
#   @return [String] the autocomplete hint (right column of the popup list).
# @!attribute [r] callback
#   @return [Proc, Method] zero-arg action, run one tick after Enter; its
#     +String+ (or nil) return is echoed below the command as the outcome.
Shared::SlashCommand = Data.define(:name, :description, :callback)
