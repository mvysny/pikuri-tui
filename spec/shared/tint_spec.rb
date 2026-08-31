# frozen_string_literal: true

RSpec.describe Shared::Tint do
  # The representative terminal backgrounds the derivation was measured
  # against: the two poles plus popular dark and light themes.
  BACKGROUNDS = {
    'pure black' => '#000000',
    'Catppuccin Mocha' => '#1e1e2e',
    'One Dark' => '#282c34',
    'pure white' => '#ffffff',
    'Catppuccin Latte' => '#eff1f5',
    'Solarized Light' => '#fdf6e3'
  }.freeze

  def hex(value) = Tuile::Color.hex(value)
  def lightness(color) = described_class.to_hsl(described_class.rgb_of(color))[2]

  describe '.pane_bg' do
    it 'steps a dark background lighter and a light one darker — toward mid-grey' do
      dark = hex('#1e1e2e')
      light = hex('#eff1f5')
      assert_operator lightness(described_class.pane_bg(dark)), :>, lightness(dark)
      assert_operator lightness(described_class.pane_bg(light)), :<, lightness(light)
    end

    it 'still shows a tint at the poles, where a pole-directed step would be a no-op' do
      refute_equal hex('#000000'), described_class.pane_bg(hex('#000000'))
      refute_equal hex('#ffffff'), described_class.pane_bg(hex('#ffffff'))
    end

    it 'preserves the hue of a tinted background' do
      mocha = described_class.rgb_of(hex('#1e1e2e'))
      tinted = described_class.rgb_of(described_class.pane_bg(hex('#1e1e2e')))
      assert_in_delta described_class.to_hsl(mocha)[0], described_class.to_hsl(tinted)[0], 2.0
    end

    it 'flips away from grey when the step would drag a passing token under the floor' do
      # A background/token pair crafted to trip the guard: the token clears
      # 4.5:1 against the raw background but not against the toward-grey
      # candidate.
      background = hex('#255') # dark teal — toward grey = lighter
      token = hex('#c4c4c4')   # ~4.8:1 on the raw background, no headroom
      assert_operator described_class.contrast(token, background), :>=, described_class::CONTRAST_FLOOR
      toward = Tuile::Color.rgb(*described_class.step(described_class.rgb_of(background), described_class::DELTA))
      assert_operator described_class.contrast(token, toward), :<, described_class::CONTRAST_FLOOR

      chosen = described_class.pane_bg(background, guard: [token])
      assert_operator lightness(chosen), :<, lightness(background) # flipped: darker
      assert_operator described_class.contrast(token, chosen), :>=, described_class::CONTRAST_FLOOR
    end

    it 'skips guard tokens with no knowable RGB rather than raising' do
      described_class.pane_bg(hex('#000000'), guard: [Tuile::Color::GREEN, Tuile::Color::RED])
    end

    it 'raises on a background whose RGB it cannot know' do
      assert_raises(ArgumentError) { described_class.pane_bg(Tuile::Color::GREEN) }
    end
  end

  describe '.hairline' do
    it 'matches the hand-tuned floors at the poles' do
      # #333333 on black and #cccccc on white are both 0.2 of HSL lightness
      # away — HAIRLINE_DELTA reproduces them.
      assert_equal Tuile::Color.rgb(51, 51, 51), described_class.hairline(hex('#000000'))
      assert_equal Tuile::Color.rgb(204, 204, 204), described_class.hairline(hex('#ffffff'))
    end

    it 'stays visible on a mid-dark ground, where the fixed #333333 vanished' do
      one_dark = hex('#282c34')
      assert_operator described_class.contrast(described_class.hairline(one_dark), one_dark), :>=, 1.5
      # the motivating regression: the fixed hex is near-invisible there
      assert_operator described_class.contrast(hex('#333333'), one_dark), :<, 1.2
    end
  end

  describe '.rgb_of' do
    it 'reads an RGB color straight through' do
      assert_equal [30, 30, 46], described_class.rgb_of(hex('#1e1e2e'))
    end

    it 'resolves a 256-palette cube index and a grey-ramp index' do
      assert_equal [0, 95, 175], described_class.rgb_of(Tuile::Color.palette(25))
      assert_equal [128, 128, 128], described_class.rgb_of(Tuile::Color.palette(244))
    end

    it 'declines symbolic ANSI, whose look the terminal scheme owns' do
      assert_nil described_class.rgb_of(Tuile::Color::GREEN)
      assert_nil described_class.rgb_of(Tuile::Color.palette(9))
    end
  end

  # The spec form of the measurement that picked the direction and DELTA:
  # across the representative backgrounds, no guarded token that clears the
  # floor against the raw background may lose it against the derived tint.
  describe 'the guard table, as Shared::AppTheme.derived applies it' do
    BACKGROUNDS.each do |name, value|
      it "keeps every passing tinted-pane token above the floor on #{name}" do
        background = Tuile::Color.hex(value)
        derived = Shared::AppTheme.derived(background)
        [derived.dark, derived.light].each do |theme|
          pane_bg = theme[:pane_bg]
          Shared::AppTheme.guard_colors(theme).each do |color|
            next if described_class.rgb_of(color).nil? # symbolic ANSI — the terminal's scheme owns it
            next if described_class.contrast(color, background) < described_class::CONTRAST_FLOOR

            assert_operator described_class.contrast(color, pane_bg), :>=, described_class::CONTRAST_FLOOR,
                            "#{color.inspect} on #{name} (#{pane_bg.inspect})"
          end
        end
      end
    end

    it 'derives the hairline from the tinted ground it rules on, not the terminal one' do
      derived = Shared::AppTheme.derived(hex('#282c34')).dark
      assert_equal described_class.hairline(derived[:pane_bg]), derived[:pane_frame]
      refute_equal described_class.hairline(hex('#282c34')), derived[:pane_frame]
    end
  end
end
