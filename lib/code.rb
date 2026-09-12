# frozen_string_literal: true

# Namespace for the +bin/pikuri-tui-code+ TUI: the in-repo coding-agent
# shell ({Code::App}), its vertical-split root layout ({Code::Layout}), and
# the in-transcript y/n confirmer ({Code::TranscriptConfirmer}) the +Write+ /
# +Bash+ tools ask through.
#
# == Why a parallel copy of +Chat::+ and not a shared base
#
# {App} and {Layout} are independent copies of {Chat::App} / {Chat::Layout},
# never subclasses of them: only pieces carrying *no* shell-specific
# divergence are extracted into {Shared} ({Shared::InputPane},
# {Shared::StatusRuleLabel}, …), and the scaffolding that wires them together
# is duplicated. The computer shell made the same call, and additionally
# reuses this namespace's {TranscriptConfirmer} / diff adapters — those are
# cross-cutting tool wiring, not shell scaffolding. The fork and the rejected
# +AbstractApp+ are in +design/decisions.md+, +D_parallel_shells+.
#
# == Code-only dependencies
#
# Everything here transitively needs the :code-group gems
# (pikuri-workspace / -code / …). The boot loader ignores this
# whole subtree when those gems aren't loaded, so the chat process —
# which runs +Bundler.setup(:default)+ — never sees it. See the gate in
# +lib/pikuri_tui.rb+.
module Code
end
