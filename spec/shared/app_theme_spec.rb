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
                      error hint notice pane_bg pane_frame removed thinking tool user],
                   described_class::DARK.custom.keys.sort
    end

    it 'paints its chrome accent in Talus, kuri own coat' do
      assert_equal described_class::TALUS, described_class::DARK[:hint]
      assert_equal described_class::TALUS_SHADE, described_class::LIGHT[:hint]
    end

    it 'keeps both Talus variants above the 4.5:1 text floor on their own grounds' do
      assert_operator Shared::Tint.contrast(described_class::TALUS, Tuile::Color.hex('#000000')),
                      :>=, 4.5
      assert_operator Shared::Tint.contrast(described_class::TALUS_SHADE, Tuile::Color.hex('#ffffff')),
                      :>=, 4.5
    end

    it 'paints the user-turn echo solid black on light, solid white on dark' do
      assert_equal Tuile::Color.new([0, 0, 0]), described_class::LIGHT[:user]
      assert_equal Tuile::Color.new([255, 255, 255]), described_class::DARK[:user]
    end

    it 'paints the tool lines in the coat too, not a terminal cyan' do
      assert_equal described_class::CHESTNUT, described_class::DARK[:tool]
      assert_equal described_class::CHESTNUT_SHADE, described_class::LIGHT[:tool]
    end

    # The conversation pane keeps the terminal's own background, so :tool has
    # to clear the floor on whatever ground the user runs — not just on the
    # near-black/near-white the fixed pane tint assumes.
    it 'keeps both Chestnut variants above the 4.5:1 text floor on common terminal grounds' do
      { described_class::CHESTNUT => %w[#000000 #282c34 #1e1e2e #002b36],
        described_class::CHESTNUT_SHADE => %w[#ffffff #eff1f5 #fdf6e3] }.each do |color, grounds|
        grounds.each do |ground|
          assert_operator Shared::Tint.contrast(color, Tuile::Color.hex(ground)), :>=, 4.5,
                          "#{color.inspect} on #{ground}"
        end
      end
    end
  end

  describe 'the derived pane tokens' do
    def hex(value) = Tuile::Color.hex(value)

    it 'falls back to the fixed-tint floor when the terminal reports no background' do
      dark = described_class::DARK.resolve(nil)
      light = described_class::LIGHT.resolve(nil)
      assert_equal [hex('#121212'), hex('#333333')], [dark[:pane_bg], dark[:pane_frame]]
      assert_equal [hex('#f0f0f0'), hex('#cccccc')], [light[:pane_bg], light[:pane_frame]]
    end

    it 'steps the pane tint off a reported background, and the hairline off the tint' do
      derived = described_class::DARK.resolve(hex('#000000'))
      refute_equal described_class::DARK.resolve(nil)[:pane_bg], derived[:pane_bg]
      # The hairline steps from :pane_bg, the ground it actually rules on —
      # not from the raw terminal background.
      assert_equal Shared::Tint.hairline(derived[:pane_bg]), derived[:pane_frame]
    end

    it 'leaves the non-derived tokens (and the Talus hint) alone' do
      derived = described_class::DARK.resolve(hex('#1e1e2e'))
      assert_equal described_class::TALUS, derived[:hint]
      assert_equal described_class::DARK[:tool], derived[:tool]
    end

    it 'stays an AppTheme, so the coloring helpers survive the derivation' do
      assert_kind_of described_class, described_class::LIGHT.resolve(hex('#282c34'))
    end

    it 'follows the background the screen reports' do
      Tuile::Screen.fake
      screen = Tuile::Screen.instance
      screen.background_color = hex('#282c34')
      assert_equal described_class::DARK.resolve(hex('#282c34'))[:pane_bg], screen.theme[:pane_bg]
    ensure
      Tuile::Screen.close
    end
  end

  describe 'the coloring helpers' do
    let(:theme) { described_class::DARK }

    it 'wraps text in the matching custom token foreground, ending with a reset' do
      { hint: :hint, tool: :tool, notice: :notice, error: :error, detail: :detail, user: :user,
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
