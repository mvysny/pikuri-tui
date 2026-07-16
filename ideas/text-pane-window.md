# Idea: `Shared::TextPaneWindow` — collapse the "framed scrollable TextView" triple

Deferred sub-extraction, split out of the (now-landed) `Code::WorkspaceSidebar`
work. Revisit now that the sidebar refactor is done.

## Problem

The same three-line idiom — a `TextView`, a `Window` framing it, `scrollbar =
true` — recurs across the tree:

- `Shared::ConversationWindow` (`conversation_window.rb:36-38`) frames a
  `ConversationTextView`.
- `Code::WorkspaceSidebar` builds it twice internally: the git "Changes" pane
  (`GitSummaryTextView` + `Window('Changes')`) and the "Git diff" pane
  (`GitDiffTextView` + `Window('Git diff')`).
- `Code::TaskListWindow` is already a `Window`-subclass doing the same
  (`super('Tasks')` + `content=` + `scrollbar = true`).

## Sketch

A tiny `Shared::TextPaneWindow < Tuile::Component::Window` that owns a
`TextView`, sets `scrollbar = true`, and exposes `#view`. Collapses each triple
to one construction and unifies the idiom.

But note `TaskListWindow` shows the shape is often *already* a bespoke
`Window` subclass framing a *specific* view (it exposes `#listener`, not a raw
`#view`). So `TextPaneWindow` is only a clean fit where the framed view is
generic/injected, not where the window is itself a domain component. Decide
per-site rather than mechanically.

## Open questions

- Does it land in `Shared::` at all, or is the triple too shallow / too varied
  to be worth a shared class? (The `WorkspaceSidebar` git panes want a
  *specific* view type, like `ConversationWindow` does — so a generic
  `TextPaneWindow` may not actually save much once each site needs its own
  view subclass anyway.)
- If it lands: should `Shared::ConversationWindow` rebase onto it, or does its
  footer/listener wiring make it a domain `Window` subclass that shouldn't?
- Widget-suffix naming: `TextPaneWindow` (a `Window`) is correct per the rule.
