# Idea: `Shared::AgentSession` — extract the turn-lifecycle engine

## Problem

The single largest duplication in the tree. These methods are
**byte-for-byte identical** across `Chat::App`, `Code::App`,
`Computer::App` (only doc prose differs), ~120 lines total:

- `submit_message` (chat:267, code:370, computer:324) — turn-in-progress
  guard → `queue_mid_turn` or `start_turn`.
- `queue_mid_turn` (chat:290, code:388, computer:342) — inject into the
  agent's `Interloper`, warn if none wired.
- `start_turn` (chat:311, code:406, computer:360) — spinner on, spawn the
  worker `Thread`, `run_loop`, rescue `Cancelled` / `StandardError`
  (log + `render_turn_error`), `ensure` marshals spinner-off +
  `@turn_in_progress = false` + `deliver_pending_injections` back onto
  the event-loop thread.
- `deliver_pending_injections` (chat:351, code:441, computer:395) —
  `interloper.drain!`, re-submit as a fresh turn.
- `on_interrupt` (chat:381, code:484, computer:427) — Ctrl+C escalation:
  cancel turn → unfocus → stop event queue.
- `clear_conversation` (chat:246, code:335, computer:289) —
  between-turns guard → `@agent.clear_conversation`.

`quit` (`@screen.event_queue.stop`) and `on_screen_error` (log-only) are
*also* byte-identical across the three, but they touch neither `@agent`
nor `@turn_in_progress` — they're screen/app concerns, not turn-lifecycle.
Pulling them in would smear the responsibility toward "everything `App`
does minus layout," so they **stay in `App`** (the leader-menu `q` wiring
and `@screen.on_error =` wiring already live there). See *Scope: what
stays in App*.

Plus the shared state: `@model_picker = Shared::Model::Picker.new(...)`
and `@turn_in_progress = false`.

These collaborate with **nothing app-specific** — only `@agent`,
`@conversation_window`, `@model_picker`, `@screen`, and the
`@turn_in_progress` flag. That's a coherent single responsibility: *own
one agent, run turns off the UI thread, serialize concurrency, handle
mid-turn injection, drive the spinner, escalate Ctrl+C.*

## Why this is allowed (not "folding App into a base")

AGENTS.md keeps `App` / `Layout` as deliberate parallel copies — but it
*mandates* extracting the smaller building blocks they compose out of
("a triplicated field or method across the three `App`s is the signal a
block is waiting to be pulled out"). `AgentSession` is such a block, not
a generic-App base. Each `App` keeps its own construction/layout and
*composes* an `AgentSession`.

## What it is (COP): a coordinator/presenter, NOT a service

`AgentSession` is a non-widget box — no addressable Tuile widget, so it's
the COP "not a component" case, and (not being a Tuile subclass) it takes
**no widget suffix**: a plain agent-noun name, same family as
`Shared::StatusFooterUpdater` / `Code::GitWatcher`.

But it is emphatically **not a UI-independent service** like `GitWatcher`
(which touches no UI at all — `no views, no Tuile, no event loop`). It
*must* hold `screen` (to marshal via `event_queue.submit`) and drive
`conversation_window`'s spinner / error surface. Referencing UI is its
job: coordinating the spinner with off-thread agent work is the whole
point. So its true sibling is `Shared::StatusFooterUpdater` — a presenter
that holds `screen` + a window and drives chrome — not `GitWatcher`.

This still honors the COP arrow rule at the granularity that matters:
`AgentSession` only calls `conversation_window`'s **public action verbs**
(`start_animation` / `stop_animation` / `render_turn_error` — tell,
don't ask); it never reaches into how the window draws, and the window
keeps owning its rendering. Frame the rdoc as *coordinator/presenter*, not
service — so a later reader doesn't "fix" it into a pure service and
recreate the App-level coupling this extraction removes.

## Scope: what stays in App

The cohesive core is *turn lifecycle + the `@turn_in_progress` flag*:
`submit_message`, `queue_mid_turn`, `start_turn`,
`deliver_pending_injections`, `on_interrupt`, and `clear_conversation`
(it reads the shared guard). `quit` and `on_screen_error` stay in `App` —
they touch neither `@agent` nor the flag (see the Problem section). Each
`App` keeps its construction / layout / leader-menu / shortcuts / `run`
loop and *delegates* into the session (`menu.add('c') {
@session.clear_conversation }`, `Ctrl+C` → `@session.interrupt`).

## Sketch

`Shared::AgentSession` (a plain class, NOT a Tuile component — no rect):

```ruby
session = Shared::AgentSession.new(
  screen: @screen,
  conversation_window: @conversation_window,
  model_picker: @model_picker
)
session.agent = built_agent          # set once the build block returns
# App#submit_message just delegates: session.submit(message)
# Ctrl+C shortcut calls session.interrupt
# leader 'c' calls session.clear_conversation; 'q' calls session.quit
```

- Owns `@turn_in_progress`, the worker thread, the interloper drain.
- The `LOG` it writes through — today each App logs via its own
  `'chat'` / `'code'` / `'computer'` logger. Decide: does `AgentSession`
  take a `logger:` (so lines keep their shell tag) or use one `'session'`
  tag? Lean **`logger:` injected** — preserves the per-shell subsystem
  tag the LogWindow shows. (See open questions.)
- `InputArea.on_submit` points at `session.submit` (via the App, or
  directly).

## Open questions

- **Logger tag.** Injected `logger:` (keeps `chat`/`code`/`computer`
  tags) vs. a single `'session'` tag. Injected is more faithful to the
  current LogWindow output; confirm the Conventions "Log through pikuri"
  list still makes sense (the three App tags stay, `session` may not need
  adding).
- **Who owns `@model_picker`?** Today the App builds it (needs
  `.names` for `ConversationWindow` and `.multiple?` for the leader
  menu, both at `build_components` time, before the agent exists). So
  the App likely still constructs the picker and *passes* it in, rather
  than `AgentSession` owning it outright. Verify the ordering.
- **`start_turn` transport.** `@model_picker.take_pending` is read at
  turn start (applies a pending model switch). That logic moves into
  `AgentSession#submit`/`start_turn`; make sure the picker is shared, not
  copied.
- **Testability.** This is the piece most worth a spec (threading,
  interloper drain, in-progress guard). A fake screen (`Tuile::Screen.fake`)
  + a fake/stub agent. Worth designing the seam so the worker thread is
  drivable in a test (inject the thread runner? or test `submit` routing
  + `deliver_pending_injections` synchronously and leave the raw thread
  spawn thin).
- Does `on_screen_error` belong here or stay App-level? It's wired via
  `@screen.on_error = method(:on_screen_error)` in the ctor tail. It only
  logs — could live on `AgentSession` or stay a free App method. Minor.

## Fit / risk

Biggest overall payoff. Medium risk — it's threading + lifecycle, so the
spec matters. Do *after* `InputWindow` (independent, and `InputWindow`
warms up the pattern).

## Durable nuggets to propagate on completion

- Package-map line: `lib/shared/agent_session.rb` — `Shared::AgentSession`,
  owns one agent's turn lifecycle (worker thread, mid-turn injection,
  spinner, Ctrl+C escalation) for all three shells.
- Add to the "building blocks already living this way" list.
- Class rdoc: the threading contract (turn runs on a worker, all UI
  marshaled back via `screen.event_queue`; `@turn_in_progress`
  serializes) — this is the load-bearing gotcha. Tag its off-thread-safe
  methods per the thread-safety rule.
- If a `logger:` seam is chosen, note it in the Conventions "Log through
  pikuri" bullet.
