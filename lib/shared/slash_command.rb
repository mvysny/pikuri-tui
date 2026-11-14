# frozen_string_literal: true

# One slash command: the typed name, the autocomplete hint, and the action.
#
#   # an action command ignores the rest of the line:
#   Shared::SlashCommand.new('/diff', 'show the git diff',
#                            ->(_rest) { sidebar.open_diff; 'Opened the git diff.' })
#   # a skill command consumes it as a follow-up message:
#   Shared::SlashCommand.new('/writing-rdoc', 'writing rdoc docs',
#                            ->(rest) { load_skill('writing-rdoc', rest); nil })
#
# The +description+ is the right-column hint in the {Shared::SlashMenuPopup}
# list; the +callback+'s *return value* is a separate string — the outcome
# shown below the command in the conversation pane once it runs (nil for none,
# e.g. a command that drives an agent turn and lets the turn be its own record).
# So the hint ("show the git diff") and the effect report ("Opened the git
# diff.") are distinct, and a command can report a dynamic result.
#
# The +rest+ argument is the text after the command name (+""+ when none) —
# {Shared::SlashMenuPopup} splits +"/name rest"+ and passes +rest+ through. An
# action command takes-and-ignores it (+->(_rest) { … }+); a skill command
# forwards it to the agent as a follow-up message.
#
# Sibling of {Shared::LeaderMenu::Action}; each shell registers its own set.
#
# @!attribute [r] name
#   @return [String] the command as typed, leading slash included (+"/diff"+).
# @!attribute [r] description
#   @return [String] the autocomplete hint (right column of the popup list).
# @!attribute [r] callback
#   @return [Proc, Method] one-arg action (the +rest+ String), run one tick
#     after Enter; its +String+ (or nil) return is echoed below the command as
#     the outcome.
Shared::SlashCommand = Data.define(:name, :description, :callback)
