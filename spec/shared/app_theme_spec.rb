# frozen_string_literal: true

RSpec.describe Shared::AppTheme do
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
      assert_equal %i[added detail diff_line_add diff_line_del diff_span_add diff_span_del
                      error frame notice pane_bg pane_frame removed thinking tool user],
                   described_class::DARK.custom.keys.sort
    end

    it 'paints its chrome accent in Talus, kuri own coat, not Tuile teal' do
      assert_equal described_class::TALUS, described_class::DARK.hint_color
      assert_equal described_class::TALUS_SHADE, described_class::LIGHT.hint_color
      refute_equal Tuile::Theme::DARK.hint_color, described_class::DARK.hint_color
    end

    it 'keeps both Talus variants above the 4.5:1 text floor on their own grounds' do
      assert_operator Shared::Tint.contrast(described_class::TALUS, Tuile::Color.hex('#000000')),
                      :>=, 4.5
      assert_operator Shared::Tint.contrast(described_class::TALUS_SHADE, Tuile::Color.hex('#ffffff')),
                      :>=, 4.5
    end
  end

  describe '.derived' do
    it 'falls back to the fixed-tint floor when the terminal reports no background' do
      assert_same described_class::THEME_DEF, described_class.derived(nil)
    end

    it 'steps the pane tint off a reported background and hairlines off their own grounds' do
      derived = described_class.derived(Tuile::Color.hex('#000000')).dark
      refute_equal described_class::DARK[:pane_bg], derived[:pane_bg]
      # :frame rules on the terminal ground, :pane_frame on the tinted one, so
      # the two must not collapse to the same value.
      refute_equal derived[:frame], derived[:pane_frame]
    end

    it 'leaves the non-derived tokens (and the Talus hint) alone' do
      derived = described_class.derived(Tuile::Color.hex('#1e1e2e')).dark
      assert_equal described_class::TALUS, derived.hint_color
      assert_equal described_class::DARK[:tool], derived[:tool]
    end

    it 'stays an AppTheme, so the coloring helpers survive the derivation' do
      assert_kind_of described_class, described_class.derived(Tuile::Color.hex('#282c34')).light
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
    it 'stays an Shared::AppTheme through Data#with (so theme.error survives a tweak)' do
      tweaked = described_class::DARK.with(active_border_color: Tuile::Color::CYAN)
      assert_kind_of described_class, tweaked
      assert_respond_to tweaked, :error
    end
  end

  describe 'the dark reasoning tone' do
    it 'matches Shared::Markdown::Grayscale::GRAY, the pre-theme thinking color' do
      assert_equal Shared::Markdown::Grayscale::GRAY, described_class::DARK[:thinking]
    end
  end
end
