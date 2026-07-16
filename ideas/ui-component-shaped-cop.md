# Idea: UI-component-shaped COP — concrete pikuri-tui shapes

> **The architectural principle has been backported and enshrined** — it now
> lives in the `cop` skill (general shape: default-target rule,
> composition-over-inheritance carve-out, model/view sizing aid, render-verb
> seam) and the `tuile` skill (Tuile event loop + component mechanics), plus
> the two posts they cite
> (https://mvysny.github.io/component-oriented-programming/,
> https://mvysny.github.io/composition-over-inheritance/) and the global
> CLAUDE.md COP block. The `ideas/ui-component-cop-principle.md` brainstorm
> was deleted once that landed. This file keeps only the concrete pikuri-tui
> component shapes that apply the principle — and its one still-open piece,
> Actionable 2 (the git-pane model/view reframing).

## It's already our house style (just not uniform)

`Shared::ConversationTextView`'s own doc states it almost verbatim: *"the
widget owns how a conversation is drawn, and the listener is a thin
event→verb adapter."* So this codifies an existing best pattern rather
than inventing one.

Scorecard of the recent extractions:

| Component | Fits? |
|---|---|
| `Shared::InputWindow` (+ inner `Area < TextArea`) | ✅ behavior on a `TextArea` subclass, framed by a `Window` |
| `Shared::ConversationWindow` / `ConversationTextView` | ✅ the exemplar: `TextView` owns rendering, nested thin `Listener` |
| `Code::TaskListWindow` | ⚠️ half — frame is a component, but rendering still lives in the standalone `TaskListener` driving a *plain* `TextView` |

## Actionable 1 — fix the task pane to match the conversation pane — DONE

Landed: `Code::TaskListTextView < TextView` (owns `GLYPHS` / `PLACEHOLDER`
/ per-status tone via `#items=`) with a nested `Listener`; `Code::TaskListener`
absorbed and deleted; `Code::TaskListWindow` now frames the view. The task
pane and the conversation pane are now the same shape. Naming resolved as
`TaskListTextView` (strict parity with `ConversationTextView`, no new
convention). Original sketch below for the record.



`Code::TaskListener` currently owns the rendering (`GLYPHS`,
`PLACEHOLDER`, `render_item`, `@text_view.text = …`) and drives a vanilla
`Tuile::Component::TextView`. That's the pre-inversion shape
`ConversationTextView` was built to replace. Target shape:

- **`Code::TaskListTextView < Tuile::Component::TextView`** — owns "how a
  task list is drawn": `GLYPHS`, `PLACEHOLDER`, per-status tone, and a UI
  verb like `items=` / `render(items)`. Stateless w.r.t. the stream, like
  `ConversationTextView`.
- **Nested `Code::TaskListTextView::Listener`** (mirrors
  `ConversationTextView::Listener`) — thin: on `Pikuri::Tasks::ListChanged`,
  marshal `event.items` onto the UI thread and call `view.items=`.
- **`Code::TaskListWindow`** frames the view, exposes `#listener` (=
  `view.listener`) — same as `ConversationWindow` ↔ `ConversationTextView`.

Result: the two sibling panes stop being built on two philosophies.
`Code::TaskListener` (standalone) is absorbed into the nested `Listener`.

**Open question — naming.** Widget-suffix convention suffixes with the
Tuile class, so strictly `TaskListTextView`. It's clunky next to
`ConversationTextView`; `TaskListView` reads better but drops the
`TextView` suffix. Decide when implementing (lean `TaskListTextView` for
consistency, or add a convention note if we allow `…View`).

## Actionable 2 — revisit the git pane as case 2 (shared model → injected views)

This is the textbook case-2 shape. `GitWatcher` is the **shared model** (a
poll thread feeding two panes); it stays a plain service. The two panes
become view components that take it as a ctor arg:

- **`GitSummaryTextView < TextView`** — owns the change-summary draw
  (`colorize_label`, `summary_line`), fed from an injected `GitWatcher`.
- **`GitDiffTextView < TextView`** — owns the inline diff draw, same.

`GitWatcher`'s job shrinks to producing data (structured change entries +
a raw diff) and pushing it to whatever views subscribe; the views own how
it looks.

**One tradeoff to weigh (a detail for the separate session, not a
blocker):** `GitWatcher` deliberately renders on the *poll thread* today
(rdoc: "the only UI-thread work is the `text=` assignment"), so a resize
re-renders off-thread on the next poll. If the views own rendering it
moves onto the UI thread. Options: (a) accept it if git rendering is cheap
relative to repaint frequency; (b) keep `GitWatcher` producing rendered
strings and let the views be thin sinks — the model/view split still
holds, the "model" just happens to emit display-ready text. Decide after
the task-pane fix gives us a precedent to measure against.

*(Deferred: this whole git reframing gets its own brainstorming session —
see the note below.)*

## Status / next steps

- Principle + boundary captured (this file), sharpened with the
  model/view (JTable) framing and the dedicated-vs-shared source cases.
- **Actionable 1 (task-pane symmetry) DONE** — see above; it's the
  precedent to measure the git reframing against.
- **DONE — principle enshrined** in the `cop` / `tuile` skills, the
  global CLAUDE.md COP block, and an AGENTS.md pointer (*Design with
  components* names the live exemplars; *Working on this codebase* tells the
  agent to read both skills before UI work).
- **The git reframing (Actionable 2) gets its own brainstorming session.**

## Durable nuggets to propagate on completion

- **AGENTS.md** gains a "UI-component-shaped COP" convention (under
  *Design with components* / *Working on this codebase*): the primary
  target, the **model/view boundary** (widget owns the view; the data
  source is a separate model, à la `JTable`), the **dedicated-1:1 →
  self-sufficient-subclass vs. shared-1:many → inject-the-source** split,
  and the narrow genuine-exceptions list. This is a cross-cutting design
  rule, so it belongs in durable docs, not just here.
- Package-map + rdoc updates for whatever task-pane components land;
  delete `lib/code/task_listener.rb` if it's absorbed into the nested
  `Listener`.
- If git rendering moves to views, update `GitWatcher`'s rdoc (it drops
  the "renders on the poll thread" story) and the package map.
