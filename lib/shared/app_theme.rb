# frozen_string_literal: true

require 'tuile'

# The app's own {Tuile::Theme}: the built-in accent tokens (active
# highlight, input well, active border, status-bar hint) plus the extra
# colors pikuri-tui paints that the framework doesn't know about, carried
# in {Tuile::Theme#custom}. Subclassing (rather than passing a bare
# +custom:+ hash) buys one coloring helper per token, mirroring the
# built-in {Tuile::Theme#hint}:
#
#   theme.error('! boom')   # instead of theme.fg(:error, '! boom')
#   theme.tool('→ ls()')    # → the conversation pane's tool-call color
#
# +Data#with+ keeps the subclass through a +with+.
#
# The one built-in token this theme *overrides* is +hint_color+: Tuile's
# default is a teal (+LIGHT_SKY_BLUE3+ / +TURQUOISE4+), and pikuri-tui paints
# its chrome accents in {TALUS} instead — kuri's own coat color, so the
# keyboard hints, the +❯+ prompt marker, the pane captions and the status
# rule's model / token readout all read as the mascot's palette.
#
# The tokens cover the chrome all three shells paint:
#
# - +:tool+ — the +→ tool(args)+ call and += result+ lines
#   {Shared::ConversationTextView::Listener} writes into the conversation pane.
# - +:notice+ — the +! reason+ fallback line and the
#   {Code::ConfirmerPopup} sanitizer warnings (a "read this carefully"
#   amber).
# - +:error+ — the +! ClassName: message+ turn-failure line, the
#   +! cancelled+ notice, the +^C cancel+ shortcut hint, and the
#   +⚠ logs (N)+ error tally.
# - +:thinking+ — the single muted tone {Shared::Markdown::Grayscale} flattens
#   reasoning blocks to. Read as a {Tuile::Color} (+theme[:thinking]+)
#   rather than a text helper, since {Shared::Markdown::Grayscale} repaints spans
#   via +StyledString#with_fg+.
# - +:detail+ — the dim secondary text under a confirmer's question
#   (the sanitized command/diff detail).
# - +:user+ — the +> message+ echo of a user turn in the conversation
#   pane. Pure black (+#000000+, an explicit RGB rather than the named
#   ANSI black the terminal would remap) on light so it reads as solid
#   black, solid white on dark so it stands out the same way there.
# - +:added+ / +:removed+ — the green +"+N"+ / red +"-N"+ line-count
#   markers {Code::GitWatcher} paints next to each path in the sidebar
#   change summary. (The full diff popup uses git's own SGR coloring, not
#   these — they're only for the summary's hand-rendered counts.)
# - +:pane_bg+ — the background of every *secondary* surface: the prompt
#   well and the coding shell's tasks / changes sidebar. The conversation
#   pane, the status rule and the status bar are primary and keep the
#   terminal's own background, so the app still blends with the user's
#   terminal theme (and stays translucent under a transparent one).
# - +:frame+ / +:pane_frame+ — the hairline color for the +─+ / +│+ rules
#   that separate panes now that nothing is framed: +:frame+ for a rule on
#   the terminal background (the status rule), +:pane_frame+ for one on
#   +:pane_bg+ (the sidebar's captions and its left-edge column). Two tokens
#   because a hairline must be derived from the ground it rules on — see
#   {.derived}.
# - +:diff_line_add+ / +:diff_line_del+ / +:diff_span_add+ /
#   +:diff_span_del+ — the four *background* tones {Code::DiffRenderer}
#   paints for the edit / write tool diff view: a dim whole-line bar
#   (+line+) and a brighter changed-character emphasis (+span+), for
#   additions and removals. Read as {Tuile::Color}s (the renderer applies
#   them as backgrounds via +StyledString+ +bg:+), not via a text helper.
#   Distinct from +:added+/+:removed+, which are foreground count markers.
#
# The markdown body palette ({Shared::Markdown::AnsiConverter}'s header
# / emphasis / code SGR codes) is deliberately NOT a theme token: that
# converter is a screen-agnostic +Kramdown::Converter+ used in specs
# without a {Tuile::Screen}, and its output is flattened away on the
# thinking path by {Shared::Markdown::Grayscale} anyway — it renders content, not
# chrome accents, which is what theming is for. Its accents are
# named-ANSI, so they track the terminal's own light/dark remapping
# for free. The one exception is rouge code-block highlighting, which
# emits absolute 256-colors: {Shared::Markdown::Renderer.render} passes the
# current scheme as a plain +dark:+ boolean (not a theme token, so the
# converter stays screen-agnostic) and {Shared::Markdown::AnsiConverter}
# picks a light-legible code theme on light.
#
# Install the {THEME_DEF} pair at boot (+screen.theme_def=+) so OS
# light/dark flips re-pick the legible variant; tests point
# +Tuile::ThemeDef.default+ at it once so every +Screen.fake+ resolves
# the custom tokens.
#
# Immutable.
class Shared::AppTheme < Tuile::Theme
  # Renders +text+ in the +:tool+ foreground. See {Tuile::Theme#hint}.
  # @param text [String]
  # @return [String] ANSI-rendered text, ending with an SGR reset.
  def tool(text) = fg(:tool, text)

  # Renders +text+ in the +:notice+ foreground.
  # @param text [String]
  # @return [String] ANSI-rendered text, ending with an SGR reset.
  def notice(text) = fg(:notice, text)

  # Renders +text+ in the +:error+ foreground.
  # @param text [String]
  # @return [String] ANSI-rendered text, ending with an SGR reset.
  def error(text) = fg(:error, text)

  # Renders +text+ in the +:detail+ foreground.
  # @param text [String]
  # @return [String] ANSI-rendered text, ending with an SGR reset.
  def detail(text) = fg(:detail, text)

  # Renders +text+ in the +:user+ foreground (the user-turn echo).
  # @param text [String]
  # @return [String] ANSI-rendered text, ending with an SGR reset.
  def user(text) = fg(:user, text)

  # Renders +text+ in the +:added+ foreground (the +"+N"+ count marker).
  # @param text [String]
  # @return [String] ANSI-rendered text, ending with an SGR reset.
  def added(text) = fg(:added, text)

  # Renders +text+ in the +:removed+ foreground (the +"-N"+ count marker).
  # @param text [String]
  # @return [String] ANSI-rendered text, ending with an SGR reset.
  def removed(text) = fg(:removed, text)

  # Kuri's coat: the +#a89c8e+ fill of the head and ears in
  # +pikuri/assets/kuri.svg+, and so pikuri-tui's chrome accent. 7.8:1 against
  # +#000+ and 5.2:1 against One Dark, comfortably legible as text on any dark
  # ground — but only 2.7:1 on white, which is what {TALUS_SHADE} is for.
  # @return [Tuile::Color]
  TALUS = Tuile::Color.hex('#a89c8e')

  # {TALUS} for light terminals: the same hue and saturation stepped down in
  # HSL lightness until it clears the 4.5:1 text floor on every common light
  # ground (5.7:1 on +#fff+, 5.1:1 on Catppuccin Latte, 5.3:1 on Solarized
  # Light). Deliberately *not* the mascot's own +#786d61+ inner-ear shade,
  # which lands at 4.5:1 on white but slips to 4.47:1 on Latte.
  # @return [Tuile::Color]
  TALUS_SHADE = Tuile::Color.hex('#6f6558')

  # The custom tokens tuned for dark terminal backgrounds. The accents
  # are the named ANSI colors (terminal-remapped, so they track the
  # user's own palette — the same rationale {Tuile::Theme::DARK} uses
  # for its named +GREEN+ border); +:thinking+ is +#555555+ and +:detail+
  # a mid gray near X11 +dimgray+.
  #
  # +:pane_bg+ / +:frame+ / +:pane_frame+ are the *fixed-tint floor* — the
  # values used when the terminal answers no OSC 11 and
  # +Tuile::Screen#background_color+ is +nil+, assuming the common near-black
  # ground. When the real background RGB is known, {.derived} replaces all
  # three.
  # @return [Hash{Symbol => Tuile::Color}]
  DARK_CUSTOM = {
    tool:     Tuile::Color::CYAN,
    notice:   Tuile::Color::YELLOW,
    error:    Tuile::Color::RED,
    thinking: Tuile::Color.new([85, 85, 85]),
    detail:   Tuile::Color::GREY42,
    user:     Tuile::Color.new([255, 255, 255]),
    added:    Tuile::Color::GREEN,
    removed:  Tuile::Color::RED,
    diff_line_add: Tuile::Color.rgb(25, 55, 30),
    diff_line_del: Tuile::Color.rgb(60, 30, 30),
    diff_span_add: Tuile::Color.rgb(40, 110, 45),
    diff_span_del: Tuile::Color.rgb(120, 40, 40),
    pane_bg:    Tuile::Color.hex('#121212'),
    frame:      Tuile::Color.hex('#333333'),
    pane_frame: Tuile::Color.hex('#333333')
  }.freeze

  # The custom tokens tuned for light terminal backgrounds: the bright
  # named accents are swapped for darker palette siblings (yellow in
  # particular is illegible on white), and the gray tones step darker so
  # they read against a light "paper" background — +:thinking+ kept a
  # touch lighter than +:detail+ so reasoning reads as muted secondary
  # text without disappearing.
  # @return [Hash{Symbol => Tuile::Color}]
  LIGHT_CUSTOM = {
    tool:     Tuile::Color::DARK_CYAN,
    notice:   Tuile::Color::DARK_ORANGE3,
    error:    Tuile::Color::RED3,
    thinking: Tuile::Color::GREY46,
    detail:   Tuile::Color::GREY35,
    user:     Tuile::Color.new([0, 0, 0]),
    added:    Tuile::Color::DARK_GREEN,
    removed:  Tuile::Color::RED3,
    diff_line_add: Tuile::Color.rgb(225, 250, 228),
    diff_line_del: Tuile::Color.rgb(255, 228, 230),
    diff_span_add: Tuile::Color.rgb(170, 230, 175),
    diff_span_del: Tuile::Color.rgb(250, 180, 185),
    pane_bg:    Tuile::Color.hex('#f0f0f0'),
    frame:      Tuile::Color.hex('#cccccc'),
    pane_frame: Tuile::Color.hex('#cccccc')
  }.freeze

  # The dark-background app theme: {Tuile::Theme::DARK}'s built-in
  # accents (bar the {TALUS} hint) plus {DARK_CUSTOM}.
  # @return [Shared::AppTheme]
  DARK = new(**Tuile::Theme::DARK.to_h.merge(hint_color: TALUS, custom: DARK_CUSTOM))

  # The light-background app theme: {Tuile::Theme::LIGHT}'s built-in
  # accents (bar the {TALUS_SHADE} hint) plus {LIGHT_CUSTOM}.
  # @return [Shared::AppTheme]
  LIGHT = new(**Tuile::Theme::LIGHT.to_h.merge(hint_color: TALUS_SHADE, custom: LIGHT_CUSTOM))

  # The pair to hand to +Tuile::Screen#theme_def=+ (and
  # +Tuile::ThemeDef.default=+ in the suite) so the screen picks the
  # legible variant at startup and re-picks on every OS appearance flip.
  # Prefer {.derived}, which folds the terminal's reported background in.
  # @return [Tuile::ThemeDef]
  THEME_DEF = Tuile::ThemeDef.new(dark: DARK, light: LIGHT)

  # The theme pair with +:pane_bg+ and the two hairlines derived from the
  # terminal's *actual* background ({Shared::Tint}), replacing the fixed floors
  # baked into {DARK_CUSTOM} / {LIGHT_CUSTOM}: +:pane_bg+ steps the background
  # toward mid-grey, +:frame+ becomes a hairline on the terminal ground and
  # +:pane_frame+ a hairline on the tinted ground. With no reported background
  # (+nil+ — plenty of terminals answer no OSC 11) the fixed floor
  # {THEME_DEF} stands.
  #
  #   screen.theme_def = Shared::AppTheme.derived(screen.background_color)
  #
  # @param background [Tuile::Color, nil] +Tuile::Screen#background_color+.
  # @return [Tuile::ThemeDef] the pair to assign to +screen.theme_def=+.
  def self.derived(background)
    return THEME_DEF if background.nil?

    Tuile::ThemeDef.new(dark: derive_variant(DARK, background), light: derive_variant(LIGHT, background))
  end

  # Installs {.derived} for +screen+'s currently reported background.
  #
  # Call it *before* building any component whose text bakes in a derived tone
  # (the hairlines: {Shared::StatusRuleLabel},
  # {Shared::PaneCaptionLabel}) — each shell's +App+ does, at the top of its
  # +build_components+ — because a +theme_def=+ on a screen with no content yet
  # fires no +on_theme_changed+ to re-bake them. {Shared::RootLayout} then calls
  # this again from its own +on_theme_changed+, which is what keeps the
  # derivation current across a light/dark flip or a fresh OSC-11 answer. That
  # second call is re-entrant by construction: the derivation is deterministic,
  # so it resolves to an equal theme and +Tuile::Screen#theme=+ no-ops.
  #
  # @param screen [Tuile::Screen]
  # @return [void]
  def self.install(screen)
    screen.theme_def = derived(screen.background_color)
  end

  # The foregrounds actually painted *on* +:pane_bg+, which {.derived}'s
  # contrast guard defends: the prompt marker and sidebar captions
  # ({Tuile::Theme#hint_color}), the placeholder / completed-task tone
  # (+:detail+) and the three change-kind tones the git summary paints. The
  # named-ANSI ones among those have no knowable RGB and skip themselves inside
  # {Shared::Tint.pane_bg}.
  #
  # Deliberately *not* the conversation pane's tokens (+:tool+, +:user+,
  # +:thinking+, the diff backgrounds): that pane keeps the terminal's own
  # background, so no tint can hurt them.
  #
  # @param theme [Shared::AppTheme] the variant to read the tokens from.
  # @return [Array<Tuile::Color>]
  def self.guard_colors(theme)
    [theme.hint_color, theme[:detail], theme[:notice], theme[:added], theme[:removed]]
  end

  # One variant with its derived tokens folded in — see {.derived}.
  #
  # @param base [Shared::AppTheme] {DARK} or {LIGHT}.
  # @param background [Tuile::Color] the terminal background RGB.
  # @return [Shared::AppTheme]
  def self.derive_variant(base, background)
    pane_bg = Shared::Tint.pane_bg(background, guard: guard_colors(base))
    base.with(custom: base.custom.merge(
      pane_bg: pane_bg,
      frame: Shared::Tint.hairline(background),
      pane_frame: Shared::Tint.hairline(pane_bg)
    ))
  end
  private_class_method :derive_variant
end
