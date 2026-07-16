# Idea: UI-component-shaped COP as the default target

## The principle

When a UI framework is in play, prefer expressing a problem as a **UI
component** — subclass the actual widget (`TextView`, `TextArea`,
`Window`, …) and bolt the behavior / business logic onto it — then
compose those components into bigger ones. This is COP with the extra
constraint that the unit of composition *is* the unit of the framework: a
`Window` frames a `TextView` frames a `TextArea`, each a self-sufficient
box. Make "can this be a single UI component?" the **primary target** for
any new UI-facing piece.

### The boundary: model vs. view

The line that decides the shape is the **model/view split**, à la Swing
`JTable`: the widget owns the *view*, and the data arrives through a
general *model* API that is agnostic to the actual source (JDBC, a file, a
computed result — `JTable` doesn't care). The UI component is always a
component; the *data source* is the separate thing. So a background
worker like `Code::GitWatcher` is **not** "an exception to being a
component" — it's the **model half**, and the view half is still a UI
component. Two shapes, chosen by whether the source is dedicated or shared:

1. **Dedicated 1:1 source → self-sufficient subclass.** When a source
   backs exactly one component, the component may subclass the widget
   *and* wire its own model straight to that source — reaching the backend
   directly. Swing: `PersonTable < JTable` whose model hits one JPA table.
   This is the self-sufficiency the global CLAUDE.md COP note already
   blesses (`BookingsGrid` populating itself). Ours: `ConversationTextView`
   with its nested `Listener` (the model adapter for the agent event
   stream) is this shape.
2. **Shared 1:many source → inject it.** When one source feeds several
   components (`GitWatcher` → summary pane + diff pane), don't force it
   into one widget. Build a Tuile component that takes the source as a
   **ctor arg** and configures itself to feed from it. Each view feeds
   from the shared model; the model stays a plain service.

Still genuinely *not* a component (the narrow exceptions):

- **Pure presenter, no widget of its own** — drives someone else's chrome.
  Ex: `Shared::StatusFooterUpdater` (drives `Window#footer_text`), which
  AGENTS.md already argues is deliberately *not* a `*Label`.
- **Pure listener / adapter** bridging into another component's surface.
  Ex: `Code::PlanModeListener` (flips a footer badge).
- **The alternative is plainly simpler.** Don't manufacture a subclass
  where a two-line helper does.

(A data-source service like `GitWatcher` is no longer in this list — it's
the model half of case 2, paired with view components, not an exception.)

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

## Actionable 1 — fix the task pane to match the conversation pane

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
- **The git reframing (Actionable 2) gets its own brainstorming session.**
  The task-pane fix (Actionable 1) is the clean precedent to land first.

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
