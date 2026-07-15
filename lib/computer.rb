# frozen_string_literal: true

# Namespace for the +bin/pikuri-tui-computer+ TUI: the desktop-assistant shell
# ({Computer::App}) and its vertical-split root layout ({Computer::Layout}).
# The shell composes two pikuri surfaces into one local agent for this
# machine (wired in the bin):
#
# * +Pikuri::Os::Extension+ — the five file tools, a network-severed
#   sandboxed +bash+, and the machine-facts / MACHINE.md system-prompt
#   sections (understanding and operating this host); plus a quarantined
#   RESEARCHER sub-agent for human-gated web research.
# * +Pikuri::Thunderbird::Extension+ — searching and reading the user's
#   local mail + calendar, and two human-gated outbound hand-offs (draft a
#   reply, add an event) the user Sends/confirms in Thunderbird's own UI.
#
# This is pikuri's "reassembled trifecta" — whole-disk private pool +
# attacker-authorable email as an untrusted source + egress — with every
# egress leg human-gated, never autonomous (see +bin/pikuri-tui-computer+
# and pikuri's +ideas/pikuri-computer.md+). The Tuile shell is otherwise
# identical to the chat/code shells; it owns nothing pikuri-side beyond
# wiring these two extensions.
#
# == Shape: chat layout, code wiring
#
# The computer shell is laid out like {Chat::App} — one conversation pane
# over an input strip, NO sidebar (unlike {Code::App}'s task + git windows).
# But its tools mutate the real host, so it carries the coding shell's
# safety machinery: it owns a {Code::ConfirmerPopup} (yielded to the
# build block for the +write+ / +bash+ tools), surfaces plan mode (a
# footer badge via {Code::PlanModeListener} + a leader-menu +p+ toggle),
# and renders +edit+ / +write+ tool calls as diffs through the same
# {Code::EditFormatter} / {Code::WriteFormatter}. Thunderbird's two outbound
# tools need no confirmer here — their gate is Thunderbird's own compose
# window / import wizard, so the shell wires them without extra UI.
#
# == Why a parallel copy of +Chat::+ / +Code::+ and not a shared base
#
# The shell machinery (worker-thread turn loop, diagnostic-log wiring,
# leader-menu / Ctrl+C shortcuts, footer, model picker) is ~90% the same
# across all three shells, but they are deliberately kept as independent
# copies rather than factored onto a common base — the project's "thin
# shell, readable not obfuscated" ceiling favors a little duplication
# over a base-class abstraction (see {Code} for the longer rationale).
# The computer shell reuses the cross-cutting +Shared::*+ adapters and the
# +Code::*+ confirmer / diff classes directly, and copies only the
# genuinely-divergent shell-specific pieces ({Computer::App},
# {Computer::Layout}).
#
# == Computer-only dependencies
#
# Everything here transitively needs the heavier pikuri gems
# (pikuri-workspace / -code, pulled in by pikuri-os) plus pikuri-thunderbird
# — and the reused +Code::*+ adapters need them too. The boot loader ignores
# this whole subtree when those gems aren't loaded, so the chat process —
# which runs +Bundler.setup(:default)+ — never sees it. See the gate in
# +lib/pikuri_tui.rb+.
module Computer
end
