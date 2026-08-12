# frozen_string_literal: true

require 'pikuri-core'

# Paints a +Pikuri::Trifecta::Report+ for the conversation pane: the advisory
# toned by verdict, the map below it untoned — it is a table of facts, and
# coloring it would compete with the one line that carries the meaning.
#
#   Shared::TrifectaRenderer.render(agent.trifecta, theme: screen.theme)
#
#   [TRIFECTA: HARD] pikuri-tui-code — private(read, grep, glob, bash) +   <- red on :loud,
#   untrusted(read, grep, glob, bash, skill) + egress(bash). An injection      yellow on :soft,
#   in what this agent reads can drive an exfiltration. Break a leg: ...       dim on :silent
#
#   pikuri-tui-code [:private, :untrusted_hard, :egress]
#     read [:private, :untrusted_hard]
#     ...
#     researcher [gate: unreviewed] [:untrusted_hard, :egress]
#       fetch [:untrusted_hard, :egress]
#
# Nothing here wraps: the advisory is one long hard line, left to the
# +TextView+ to word-wrap at the pane width. Its closing "See
# book/trifecta-detector.md in this repo" points at *pikuri's* repo, where that
# chapter lives, and is passed through unedited.
module Shared::TrifectaRenderer
  class << self
    # Render the whole report — advisory line, blank line, map.
    #
    # @param report [Pikuri::Trifecta::Report] a walked report, normally
    #   +agent.trifecta+.
    # @param theme [Shared::AppTheme] supplies the verdict tone; taken as an
    #   argument, so this renders (and tests) without a {Tuile::Screen}.
    # @return [String] ANSI, newline-separated, no trailing newline — ready for
    #   {Shared::ConversationWindow#add_block}.
    # @raise [NoMatchingPatternError] if the report carries a verdict this has
    #   no tone for — deliberate, so a new severity can't slip through untoned.
    def render(report, theme:)
      # Split positionally rather than matching +#advisory+ back out of the
      # rendered string: an upstream reword can then only mistone a line, never
      # duplicate or swallow one.
      advisory, *map = report.render.lines(chomp: true)
      [tone(report.tree_verdict, advisory, theme), *map].join("\n")
    end

    private

    # @param verdict [Symbol] +:silent+, +:soft+ or +:loud+.
    # @param text [String] the advisory line.
    # @param theme [Shared::AppTheme]
    # @return [String] ANSI-toned text.
    def tone(verdict, text, theme)
      case verdict
      in :loud then theme.error(text)
      in :soft then theme.notice(text)
      # Dimmed, not greened: the detector reasons about capability presence,
      # so a silent verdict is not a clean bill of health.
      in :silent then theme.detail(text)
      end
    end
  end
end
