# frozen_string_literal: true

module PikuriTui
  # Namespace for the +bin/pikuri-tui-os+ TUI: the offline OS-assistant
  # shell ({Os::App}), its vertical-split root layout ({Os::Layout}), the
  # Enter-submits text input ({Os::Input}), and the conversation-window
  # footer ({Os::FooterLabel}). The shell is driven by one
  # +Pikuri::Os::Extension+ (wired in the bin): the five file tools, a
  # network-severed sandboxed +bash+, and the machine-facts / MACHINE.md
  # system-prompt sections — a single local agent for understanding and
  # operating this host.
  #
  # == Shape: chat layout, code wiring
  #
  # The OS shell is laid out like {Chat::App} — one conversation pane over
  # an input strip, NO sidebar (unlike {Code::App}'s task + git windows).
  # But its tools mutate the real host, so it carries the coding shell's
  # safety machinery: it owns a {Code::ConfirmerPopup} (yielded to the
  # build block for the +write+ / +bash+ tools), surfaces plan mode (a
  # footer badge via {Code::PlanModeListener} + a leader-menu +p+ toggle),
  # and renders +edit+ / +write+ tool calls as diffs through the same
  # {Code::EditFormatter} / {Code::WriteFormatter}.
  #
  # == Why a parallel copy of +Chat::+ / +Code::+ and not a shared base
  #
  # The shell machinery (worker-thread turn loop, diagnostic-log wiring,
  # leader-menu / Ctrl+C shortcuts, footer, model picker) is ~90% the same
  # across all three shells, but they are deliberately kept as independent
  # copies rather than factored onto a common base — the project's "thin
  # shell, readable not obfuscated" ceiling favors a little duplication
  # over a base-class abstraction (see {Code} for the longer rationale).
  # The OS shell reuses the cross-cutting adapters ({TuileListener},
  # {ModelListener}, {LeaderMenu}, {LogPopup}, …) and the +Code::*+
  # confirmer / diff classes directly, and copies only the four
  # shell-specific pieces ({Os::App}, {Os::Layout}, {Os::Input},
  # {Os::FooterLabel}).
  #
  # == OS-only dependencies
  #
  # Everything here transitively needs the heavier pikuri gems
  # (pikuri-workspace / -code, pulled in by pikuri-os) — and the reused
  # +Code::*+ adapters need them too. {PikuriTui}'s loader ignores this
  # whole subtree when those gems aren't loaded, so the chat process —
  # which runs +Bundler.setup(:default)+ — never sees it. See the gate in
  # +lib/pikuri_tui.rb+.
  module Os
  end
end
