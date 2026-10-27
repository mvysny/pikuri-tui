# frozen_string_literal: true

RSpec.describe Shared::Log::Dialog do
  let(:dialog) { described_class.new(on_dismiss: -> {}) }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  def write(line) = Tuile::Component::LogDialog::IO.new(dialog).write(line)

  it 'is half the screen height with only a few log lines' do
    screen_height = Tuile::Screen.instance.size.height
    write('a single short line')
    dialog.open
    assert_equal screen_height / 2, dialog.rect.height
  end

  it 'stays half-screen regardless of log volume (sizing is top-down, not content-driven)' do
    screen_height = Tuile::Screen.instance.size.height
    100.times { |i| write("log line #{i}") }
    dialog.open
    assert_equal screen_height / 2, dialog.rect.height # the busy log scrolls within the fixed box
  end

  it 'keeps logging while closed, so a later open shows the backlog' do
    write('logged while closed')
    Tuile::Testing.loop # LogDialog#log submits
    dialog.open
    assert_includes dialog.content.text.to_s, 'logged while closed'
  end

  it 'fires on_dismiss when closed' do
    dismissed = false
    dialog = described_class.new(on_dismiss: -> { dismissed = true })
    dialog.open
    dialog.close
    assert dismissed
  end

  it 'does not fire on_dismiss when the screen tears down under it' do
    dismissed = false
    dialog = described_class.new(on_dismiss: -> { dismissed = true })
    dialog.open
    Tuile::Screen.close
    refute dismissed
  end
end
