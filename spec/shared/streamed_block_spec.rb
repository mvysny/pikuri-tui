# frozen_string_literal: true

RSpec.describe Shared::StreamedBlock do
  # Minimal stand-ins for a TextView region and a streaming buffer.
  class FakeRegion
    attr_reader :removed

    def initialize = @removed = false
    def remove = @removed = true
  end

  class FakeBuffer
    attr_reader :appended, :finalized

    def initialize
      @appended = []
      @finalized = nil
    end

    def append(content) = @appended << content
    def finalize(content) = @finalized = content
  end

  # A block whose factory hands out a fresh region + buffer each open, and
  # records how many times it opened and the pairs it produced.
  def build
    opens = []
    block = described_class.new do
      pair = [FakeRegion.new, FakeBuffer.new]
      opens << pair
      pair
    end
    [block, opens]
  end

  it 'starts closed and opens lazily on the first append' do
    block, opens = build
    refute block.open?
    assert_empty opens

    block.append('hi')
    assert block.open?
    assert_equal 1, opens.size
    assert_equal ['hi'], opens.first.last.appended
  end

  it 'opens once across successive appends' do
    block, opens = build
    block.append('a')
    block.append('b')
    assert_equal 1, opens.size
    assert_equal %w[a b], opens.first.last.appended
  end

  it 'finalize commits the authoritative text and closes' do
    block, opens = build
    block.append('draft')
    block.finalize('final')
    assert_equal 'final', opens.first.last.finalized
    refute block.open?
  end

  it 'wipe removes the region and closes' do
    block, opens = build
    block.append('preview')
    region, = opens.first
    block.wipe
    assert region.removed
    refute block.open?
  end

  it 'preserve closes without removing the region (content stays on screen)' do
    block, opens = build
    block.append('kept')
    region, = opens.first
    block.preserve
    refute region.removed
    refute block.open?
  end

  it 'finalize / wipe / preserve are no-ops while closed' do
    block, opens = build
    block.finalize('x')
    block.wipe
    block.preserve
    assert_empty opens # never opened, nothing touched
    refute block.open?
  end

  it 'is reusable: a fresh append after close opens a new region + buffer' do
    block, opens = build
    block.append('first')
    block.finalize('first')
    block.append('second')
    assert_equal 2, opens.size
    refute_same opens[0].first, opens[1].first
    assert_equal ['second'], opens[1].last.appended
  end
end
