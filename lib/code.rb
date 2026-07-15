# frozen_string_literal: true

# Namespace for the +bin/pikuri-tui-code+ TUI: the in-repo coding-agent
# shell ({Code::App}), its vertical-split root layout ({Code::Layout}), and
# the modal y/n confirmer ({Code::ConfirmerPopup}) the +Write+ / +Bash+ tools
# prompt through.
#
# == Why a parallel copy of +Chat::+ and not a shared base
#
# The shell machinery (worker-thread turn loop, diagnostic-log wiring,
# leader-menu / Ctrl+C shortcuts, footer) is ~90% the same as {Chat::App},
# but the two shells are kept as independent copies rather than factored
# onto a common base: the project's "thin shell, readable not obfuscated"
# ceiling doesn't ask for the DRY win, and the coding shell's one genuine
# addition — a confirmation popup on the write/bash tools — is cheaper as a
# little duplication than a base-class abstraction. The computer shell later made
# the same call (reusing this namespace's {ConfirmerPopup} / diff adapters,
# which are cross-cutting tool wiring, not shell scaffolding). Only pieces
# that carry *no* shell-specific divergence are extracted into {Shared}
# instead of copied ({Shared::InputArea}, {Shared::StatusFooterUpdater}, …);
# duplicate only where the copies genuinely drift.
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
