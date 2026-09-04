# frozen_string_literal: true

require 'pikuri-core'
require 'pikuri-workspace'

module Code
  # Paints one already-sanitized confirmation request as a transcript block:
  # sanitizer warnings first (when anything was flagged), the question, its
  # verbatim payload, and a write's diff.
  #
  #   Code::ConfirmRenderer.render(question: q, detail: nil, warnings: [], change: change,
  #                                width: conversation.buffer_width, theme: screen.theme)
  #
  #   ⚠ Suspicious content detected — read carefully before approving:   <- only when flagged
  #     ! text contains control bytes that can rewrite the line above
  #   ⏵ OK to edit MACHINE.md (1 occurrence)?
  #   - # Machine facts
  #   + # Machine facts (updated)
  #
  # The diff is {DiffRenderer}'s, the same two-tier form the +edit+ / +write+
  # formatters paint once the change lands — so the change under review and the
  # change applied look identical.
  #
  # Screen-agnostic (the theme is an argument), and it renders no key cue: which
  # outcomes are on offer belongs to the {Shared::PendingDecision} the pane
  # spells out under this body.
  module ConfirmRenderer
    # Cap on rendered diff lines, past which {DiffRenderer} appends its
    # +… +N more lines+ tail — a whole-file rewrite must not turn the decision
    # into a scroll marathon.
    #
    # @return [Integer]
    DIFF_MAX_LINES = 500

    LOG = Pikuri.logger_for('confirmer')
    private_constant :LOG

    class << self
      # @param question [Pikuri::Sanitizer::Result] the sanitized question.
      # @param detail [Pikuri::Sanitizer::Result, nil] the sanitized payload
      #   (the bash command, the sub-agent task); +nil+ for a write.
      # @param warnings [Array<Pikuri::Sanitizer::Warning>] what the sanitizer
      #   flagged across question + detail + change; empty when clean.
      # @param change [Pikuri::Workspace::Confirmer::Change, nil] the file
      #   change to diff, its old/new text ALREADY sanitized.
      # @param width [Integer] column width the diff's full-row bars pad to.
      # @param theme [Shared::AppTheme] supplies the warning / detail / diff
      #   tones; taken as an argument, so this renders without a
      #   {Tuile::Screen}.
      # @return [String] ANSI, newline-separated, no trailing newline — ready
      #   for {Shared::PendingDecision}'s +body+.
      def render(question:, detail:, warnings:, change:, width:, theme:)
        lines = warning_lines(warnings, theme)
        lines << Tuile::StyledString.styled("⏵ #{question.text}", bold: true).to_ansi
        detail&.text&.split("\n")&.each { |line| lines << theme.detail(line) }
        diff = change ? render_diff(change, width, theme) : nil
        lines << diff if diff
        lines.join("\n")
      end

      private

      # @param warnings [Array<Pikuri::Sanitizer::Warning>]
      # @param theme [Shared::AppTheme]
      # @return [Array<String>] the header + one explanation per warning, or
      #   empty when nothing was flagged.
      def warning_lines(warnings, theme)
        return [] if warnings.empty?

        header = Tuile::StyledString.styled('⚠ Suspicious content detected — read carefully before approving:',
                                            fg: theme[:notice], bold: true).to_ansi
        [header, *warnings.map { |warning| theme.notice("  ! #{warning.explanation}") }]
      end

      # Render +change+ as the transcript's two-tier diff, or +nil+ when
      # +diff-lcs+ chokes on it — a cosmetic path, so it degrades to a diffless
      # question rather than raising into the event loop and stranding the tool
      # blocked on its answer.
      #
      # @param change [Pikuri::Workspace::Confirmer::Change] sanitized text.
      # @param width [Integer]
      # @param theme [Shared::AppTheme]
      # @return [String, nil] ANSI diff body.
      def render_diff(change, width, theme)
        DiffRenderer.render(change.old.to_s, change.new, width: width,
                                                         palette: DiffToolFormatting.palette(theme),
                                                         max_lines: DIFF_MAX_LINES)
      rescue StandardError => e
        LOG.error("diff render failed (#{e.class}: #{e.message}); confirming without a diff")
        nil
      end
    end
  end
end
