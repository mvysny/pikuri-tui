# frozen_string_literal: true

RSpec.describe PikuriTui::LogPopup do
  let(:log_window) { Tuile::Component::LogWindow.new('Log') }
  let(:popup) { described_class.new(log_window: log_window, on_dismiss: -> {}) }

  before { Tuile::Screen.fake }
  after  { Tuile::Screen.close }

  def write(line) = Tuile::Component::LogWindow::IO.new(log_window).write(line)

  it 'floors the popup at half the screen height even with only a few log lines' do
    screen_height = Tuile::Screen.instance.size.height
    write('a single short line')
    popup.open
    assert_equal screen_height / 2, popup.rect.height
  end

  it 'grows past the base 12-row cap for a busy log (up to the 4/5-of-screen ceiling)' do
    screen_height = Tuile::Screen.instance.size.height
    100.times { |i| write("log line #{i}") }
    popup.open
    assert_equal screen_height * 4 / 5, popup.rect.height
  end

  it 'fires on_dismiss when closed' do
    dismissed = false
    popup = described_class.new(log_window: log_window, on_dismiss: -> { dismissed = true })
    popup.open
    popup.close
    assert dismissed
  end
end
