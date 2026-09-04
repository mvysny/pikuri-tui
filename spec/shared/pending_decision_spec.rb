# frozen_string_literal: true

RSpec.describe Shared::PendingDecision do
  def choice(key, label, outcome)
    described_class::Choice.new(key: key, label: label, outcome: outcome)
  end

  let(:decision) do
    described_class.new(
      body: '⏵ OK to run this?',
      choices: [choice('y', 'approve', :approve), choice('n', 'reject', :reject)],
      on_choice: ->(_outcome) {}
    )
  end

  it 'spells the offered keys out as a cue line' do
    assert_equal '(y) approve   (n) reject', decision.cue
  end

  it 'resolves a pressed key to its choice' do
    assert_equal :reject, decision.choice_for('n').outcome
  end

  it 'resolves a capitalised key too (shift is a slip, not a different answer)' do
    assert_equal :approve, decision.choice_for('Y').outcome
  end

  it 'resolves an unoffered key to nothing' do
    assert_nil decision.choice_for('e')
  end
end
