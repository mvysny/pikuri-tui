# frozen_string_literal: true

RSpec.describe PikuriTui::AppTheme do
  describe 'the THEME_DEF pair' do
    it 'is a Tuile::ThemeDef whose members are AppThemes' do
      assert_kind_of Tuile::ThemeDef, described_class::THEME_DEF
      assert_kind_of described_class, described_class::THEME_DEF.dark
      assert_kind_of described_class, described_class::THEME_DEF.light
    end

    it 'declares the same custom token set on both variants' do
      assert_equal described_class::DARK.custom.keys.sort,
                   described_class::LIGHT.custom.keys.sort
    end

    it 'carries exactly the tokens the app paints' do
      assert_equal %i[added detail error notice removed thinking tool user],
                   described_class::DARK.custom.keys.sort
    end

    it 'paints the user-turn echo solid black on light, solid white on dark' do
      assert_equal Tuile::Color.new([0, 0, 0]), described_class::LIGHT[:user]
      assert_equal Tuile::Color.new([255, 255, 255]), described_class::DARK[:user]
    end
  end

  describe 'the coloring helpers' do
    let(:theme) { described_class::DARK }

    it 'wraps text in the matching custom token foreground, ending with a reset' do
      { tool: :tool, notice: :notice, error: :error, detail: :detail, user: :user,
        added: :added, removed: :removed }.each do |helper, token|
        out = theme.public_send(helper, 'x')
        assert_equal "#{theme[token].to_ansi(:fg)}x#{Tuile::Ansi::RESET}", out
      end
    end
  end

  describe 'subclass preservation' do
    it 'stays an AppTheme through Data#with (so theme.error survives a tweak)' do
      tweaked = described_class::DARK.with(active_border_color: Tuile::Color::CYAN)
      assert_kind_of described_class, tweaked
      assert_respond_to tweaked, :error
    end
  end

  describe 'the dark reasoning tone' do
    it 'matches AnsiGrayscale::GRAY, the pre-theme thinking color' do
      assert_equal PikuriTui::AnsiGrayscale::GRAY, described_class::DARK[:thinking]
    end
  end
end
