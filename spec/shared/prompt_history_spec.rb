# frozen_string_literal: true

RSpec.describe Shared::PromptHistory do
  let(:history) { described_class.new }

  it 'starts on the draft with nothing to recall' do
    assert history.at_draft?
    assert_empty history.entries
    assert_nil history.older
    assert_nil history.newer
  end

  it 'recalls the newest entry first, then walks back to the oldest' do
    history.append('first')
    history.append('second')
    assert_equal 'second', history.older
    assert_equal 'first',  history.older
    refute history.at_draft?
  end

  it 'returns nil at the oldest entry instead of clamping silently' do
    history.append('only')
    assert_equal 'only', history.older
    assert_nil history.older
    # The cursor stayed put, so Down still walks forward to the draft.
    assert_equal '', history.newer
  end

  it 'walks forward to the draft and stops there' do
    history.append('first')
    history.append('second')
    history.draft = 'unsent'
    history.older
    history.older
    assert_equal 'second', history.newer
    assert_equal 'unsent', history.newer
    assert history.at_draft?
    assert_nil history.newer
  end

  it 'preserves the draft across a full round trip' do
    history.append('sent')
    history.draft = 'half typed'
    assert_equal 'sent', history.older
    assert_equal 'half typed', history.newer
  end

  it 'jumps straight back to the draft from anywhere' do
    history.append('a')
    history.append('b')
    history.draft = 'mine'
    history.older
    history.older
    assert_equal 'mine', history.jump_to_draft
    assert history.at_draft?
  end

  it 'jumps to an empty draft when none was captured' do
    history.append('a')
    history.older
    assert_equal '', history.jump_to_draft
  end

  it 'collapses a consecutive duplicate but keeps a re-sent older entry' do
    history.append('ls')
    history.append('ls')
    assert_equal ['ls'], history.entries

    history.append('pwd')
    history.append('ls')
    assert_equal %w[ls pwd ls], history.entries
  end

  it 'clears the draft and returns to it on append' do
    history.draft = 'abandoned'
    history.older # nothing to recall, but the draft is captured
    history.append('sent')
    assert history.at_draft?
    assert_equal 'sent', history.older
    assert_equal '', history.newer
  end

  it 'freezes what it keeps, so a caller mutating its String cannot rewrite an entry' do
    submitted = +'live buffer'
    history.append(submitted)
    submitted << ' — edited after the fact'
    assert_equal ['live buffer'], history.entries
    assert history.entries.first.frozen?
  end

  it 'hands out a copy of the entries' do
    history.append('a')
    history.entries << 'forged'
    assert_equal ['a'], history.entries
  end
end
