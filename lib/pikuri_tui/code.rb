# frozen_string_literal: true

module PikuriTui
  # Namespace for the +bin/pikuri-tui-code+ TUI: the in-repo coding-agent
  # shell ({Code::App}), its vertical-split root layout ({Code::Layout}),
  # and the modal y/n confirmer ({Code::ConfirmerPopup}) the +Write+ /
  # +Bash+ tools prompt through. The Enter-submits text input ({Input}) and
  # conversation-window footer ({FooterLabel}) are shared top-level
  # components.
  #
  # == Why a parallel copy of +Chat::+ and not a shared base
  #
  # The shell machinery (worker-thread turn loop, diagnostic-log wiring,
  # leader-menu / Ctrl+C shortcuts, footer) is ~90% the same as {Chat::App},
  # but the two are deliberately kept as independent copies rather than
  # factored onto a common base. Rationale: the chat shell is functional
  # and specced, and a shared base would refactor it for a DRY win that
  # the project's "thin shell, readable not obfuscated" ceiling doesn't
  # ask for. The coding shell adds one thing chat has not — a
  # confirmation popup wired into the write/bash tools — and pays for it
  # with a little duplication instead of a base-class abstraction. A third
  # shell has since landed ({Os::App}, the OS assistant) and the call was
  # still to duplicate the genuinely-divergent shell-specific pieces (App /
  # Layout) rather than extract a base — though the OS shell does reuse this
  # namespace's {ConfirmerPopup} / diff adapters directly, since those are
  # cross-cutting tool wiring, not shell scaffolding.
  #
  # The two pieces that carried *no* divergence — the Enter-submits input
  # and the footer label — were the exception: they are shared top-level
  # {Input} / {FooterLabel} components, not per-shell copies. Duplicate only
  # where the copies genuinely drift; the input never did, and the footer's
  # only difference (chat's lack of a plan-mode badge) collapses to chat
  # simply never calling +FooterLabel#plan_active=+.
  #
  # == Code-only dependencies
  #
  # Everything here transitively needs the :code-group gems
  # (pikuri-workspace / -code / …). {PikuriTui}'s loader ignores this
  # whole subtree when those gems aren't loaded, so the chat process —
  # which runs +Bundler.setup(:default)+ — never sees it. See the gate in
  # +lib/pikuri_tui.rb+.
  module Code
  end
end
