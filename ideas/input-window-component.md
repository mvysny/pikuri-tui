# Idea: `Shared::InputWindow` — frame the input pane as a component

## Problem

All three `App#build_components` repeat the identical three-line dance to
frame the already-componentized `Shared::InputArea` in a `Window`:

```ruby
# chat/app.rb:174-176, code/app.rb:223-225, computer/app.rb:209-211 — identical
@input = Shared::InputArea.new(on_submit: method(:submit_message))
@input_window = Tuile::Component::Window.new('You')
@input_window.content = @input
```

…then hand the layout `input: @input_window` while focusing the *inner*
`@input` (`@screen.focused = @input`). So each App carries a split
`@input` / `@input_window` pair plus the framing boilerplate.

This is the `Shared::ConversationWindow` situation one level down: a
`Window` framing one self-contained widget. `ConversationWindow` already
does this exact `super(title); self.content = …; self.scrollbar = …`
idiom internally (`conversation_window.rb:36-38`).

## Sketch

`Shared::InputWindow < Tuile::Component::Window`:

- ctor takes `on_submit:` (and maybe `title: 'You'`), builds its own
  `Shared::InputArea` internally, sets it as content.
- exposes a focus target so the App can do `@screen.focused =
  @input_window.focus_target` (or the window forwards focus itself).
- App's `build_components` drops to one line; the `@input` /
  `@input_window` split collapses to a single `@input_window`.

Widget-suffix convention: it *is* a `Window` wrapper, so `InputWindow`
is the right name (cf. `Shared::Log::Popup`, `LogWindow`).

## Open questions

- **Focus handoff.** Tuile focuses the leaf `TextArea`, not the
  `Window`. Options: (a) expose `#focus_target` returning the inner
  `InputArea`; (b) give `InputWindow` a `#focus!` that sets
  `screen.focused` to its inner area. Prefer (a) — matches how
  `ConversationWindow` exposes `#view` for tests and lets the App keep
  owning `@screen`.
- Does `InputArea` stay a separate public class, or become an
  implementation detail of `InputWindow`? Keep it separate — it has its
  own spec and its Enter-rebinding contract stands alone; `InputWindow`
  just frames it.
- Title always `'You'`? Yes today across all three. Keep a `title:`
  param defaulting to `'You'` for cheap flexibility, or hardcode until a
  second title appears. Lean hardcode (YAGNI) unless a shell diverges.

## Fit / risk

Cleanest, lowest-risk win. Directly mirrors the `ConversationWindow`
precedent. A `Shared::` Tuile component reused by all three shells.

## Durable nuggets to propagate on completion

- Package-map line in AGENTS.md Layout section:
  `lib/shared/input_window.rb` — `Shared::InputWindow`, the `Window`
  framing a `Shared::InputArea`; shared by all three shells.
- Add `Shared::InputWindow` to the "building blocks already living this
  way" list in the Dedup bullet (Working on this codebase).
- Class rdoc carries the focus-handoff contract (how the host focuses
  the inner area) — that's the one non-obvious nugget.
- `UI-thread-confined` tag (same as `InputArea` / `ConversationWindow`).
