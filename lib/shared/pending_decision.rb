# frozen_string_literal: true

# One human decision awaiting an answer in the transcript: a rendered body, the
# outcomes on offer, and the callback that reports the picked one.
#
#   decision = Shared::PendingDecision.new(
#     body: 'OK to run `rm -rf build`?',
#     choices: [Shared::PendingDecision::Choice.new(key: 'y', label: 'approve', outcome: :approve),
#               Shared::PendingDecision::Choice.new(key: 'n', label: 'reject',  outcome: :reject)],
#     on_choice: ->(outcome) { decide(outcome) }   # gets :approve / :reject
#   )
#   conversation.pending_decision = decision   # renders body + "(y) approve   (n) reject"
#
# +body+ arrives already rendered (ANSI, newline-joined) because what a decision
# looks like is the asking side's business — a write request renders a diff, a
# sub-agent delegation renders the task text.
#
# UI-free and Pikuri-free: the pane renders it, but nothing here reaches for
# either — so the lean chat process can load it too.
class Shared::PendingDecision < Data.define(:body, :choices, :on_choice)
  # One offered outcome: the key that picks it, the word shown in the cue, and
  # the symbol handed to +on_choice+.
  Choice = Data.define(:key, :label, :outcome)

  # The key cue shown under the body.
  #
  #   '(y) approve   (e) edit   (n) reject'
  #
  # @return [String]
  def cue = choices.map { |choice| "(#{choice.key}) #{choice.label}" }.join('   ')

  # @param key [String] a pressed key, case as typed.
  # @return [Choice, nil] the choice that key picks, or +nil+ if it picks none.
  def choice_for(key)
    down = key.downcase
    choices.find { |choice| choice.key == down }
  end
end
