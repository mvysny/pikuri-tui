# frozen_string_literal: true

require 'tuile'

module PikuriTui
  # The app's own {Tuile::Theme}: the built-in accent tokens (active
  # highlight, input well, active border, status-bar hint) plus the
  # five colors pikuri-tui paints that the framework doesn't know
  # about, carried in {Tuile::Theme#custom}. Subclassing rather than
  # passing a bare +custom:+ hash buys one coloring helper per token
  # ({#tool}, {#notice}, {#error}, {#detail}) that mirrors the built-in
  # {Tuile::Theme#hint} — call sites read +theme.error("…")+ instead of
  # +theme.fg(:error, "…")+, and +Data#with+ keeps the subclass through
  # a +with+.
  #
  # The tokens cover the chrome both shells paint:
  #
  # - +:tool+ — the +→ tool(args)+ call and += result+ lines
  #   {TuileListener} writes into the conversation pane.
  # - +:notice+ — the +! reason+ fallback line and the
  #   {Code::ConfirmerPopup} sanitizer warnings (a "read this carefully"
  #   amber).
  # - +:error+ — the +! ClassName: message+ turn-failure line, the
  #   +! cancelled+ notice, the +^C cancel+ shortcut hint, and the
  #   +⚠ logs (N)+ error tally.
  # - +:thinking+ — the single muted tone {AnsiGrayscale} flattens
  #   reasoning blocks to. Read as a {Tuile::Color} (+theme[:thinking]+)
  #   rather than a text helper, since {AnsiGrayscale} repaints spans
  #   via +StyledString#with_fg+.
  # - +:detail+ — the dim secondary text under a confirmer's question
  #   (the sanitized command/diff detail).
  #
  # The markdown body palette ({MarkdownRenderer::AnsiConverter}'s header
  # / emphasis / code SGR codes) is deliberately NOT a theme token: that
  # converter is a screen-agnostic +Kramdown::Converter+ used in specs
  # without a {Tuile::Screen}, and its output is flattened away on the
  # thinking path by {AnsiGrayscale} anyway — it renders content, not
  # chrome accents, which is what theming is for.
  #
  # Install the {THEME_DEF} pair at boot (+screen.theme_def=+) so OS
  # light/dark flips re-pick the legible variant; tests point
  # +Tuile::ThemeDef.default+ at it once so every +Screen.fake+ resolves
  # the custom tokens.
  class AppTheme < Tuile::Theme
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

    # The custom tokens tuned for dark terminal backgrounds. The accents
    # are the named ANSI colors (terminal-remapped, so they track the
    # user's own palette — the same rationale {Tuile::Theme::DARK} uses
    # for its named +GREEN+ border); +:thinking+ is +#555555+ (the tone
    # the listener used before this theme existed) and +:detail+ a mid
    # gray near X11 +dimgray+.
    # @return [Hash{Symbol => Tuile::Color}]
    DARK_CUSTOM = {
      tool:     Tuile::Color::CYAN,
      notice:   Tuile::Color::YELLOW,
      error:    Tuile::Color::RED,
      thinking: Tuile::Color.new([85, 85, 85]),
      detail:   Tuile::Color::GREY42
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
      detail:   Tuile::Color::GREY35
    }.freeze

    # The dark-background app theme: {Tuile::Theme::DARK}'s built-in
    # accents plus {DARK_CUSTOM}.
    # @return [AppTheme]
    DARK = new(**Tuile::Theme::DARK.to_h.merge(custom: DARK_CUSTOM))

    # The light-background app theme: {Tuile::Theme::LIGHT}'s built-in
    # accents plus {LIGHT_CUSTOM}.
    # @return [AppTheme]
    LIGHT = new(**Tuile::Theme::LIGHT.to_h.merge(custom: LIGHT_CUSTOM))

    # The pair to hand to +Tuile::Screen#theme_def=+ (and
    # +Tuile::ThemeDef.default=+ in the suite) so the screen picks the
    # legible variant at startup and re-picks on every OS appearance flip.
    # @return [Tuile::ThemeDef]
    THEME_DEF = Tuile::ThemeDef.new(dark: DARK, light: LIGHT)
  end
end
