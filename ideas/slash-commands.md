# Slash commands

## Problem / goal

Add a `/`-triggered command palette to the prompt input, shared by all three
shells. It overlaps the `Ctrl+K` leader menu (and will later also surface
skills), but is a separate, discoverable entry path: type `/`, get an
autocomplete popup, pick a command, Enter runs it.

This session: build the **infrastructure** + these commands only:

- `/exit` and `/quit` — quit the app (all shells)
- `/diff` — open the git diff window (**code shell only**)

More commands (and skills) land later.

## Requirements (verbatim-ish from the ask)

- The moment the input buffer starts with `/`, an autocomplete popup appears.
- Popup spans screen width minus 1 char padding on **both** edges, **10 lines
  tall**, slightly distinctive background.
- Rows shaped `"/quit   quits the app"` — command name and description in two
  distinctive columns.
- Enter while the popup is visible executes the selected command.
- Command *list* varies per shell; the machinery is shared.

## Studied: `../tuile/examples/sampler.rb` `build_slash_demo`

The canonical Tuile recipe for exactly this, and it's all assembled from stock
hooks — nothing baked into `TextArea`:

- A **non-modal** `Popup` (`modal: false`) wrapping a `Window` wrapping a
  `List`. Focus (and the caret) never leaves the input.
- `List#cursor = List::Cursor.new` + `show_cursor_when_inactive = true` so the
  selection highlights while focus stays in the field.
- `area.on_change` → refill: compute matches, `overlay.open`/`close`, set
  `list.lines`, re-anchor.
- `area.on_key` → while open, forward `UP`/`DOWN`/`ENTER` to
  `list.handle_key(key)` (works unfocused — dispatch gates on focus, the list's
  handler doesn't) and consume `ESC` to close; let everything else fall through
  so typing keeps editing + refilling.
- `list.on_item_chosen` → accept: run the command.
- Anchor helper positions the overlay relative to the caret, flips above when
  no room, clamps to screen.

Our sizing differs from the sampler (we want a fixed full-width, 10-tall,
bottom-anchored bar over the input, not a caret-anchored menu), and our trigger
is simpler: **whole buffer starts with `/`**, not "the token at the caret".

## Decisions (locked in)

1. **Dedicated `Shared::SlashCommand`** value object + per-app catalog,
   parallel to `LeaderMenu::Action` (duplication accepted).
2. **`InputWindow` owns the orchestration** (on_change sync, Enter
   arbitration, nav forwarding), driving one injected slash collaborator.
3. **Unknown / no-match slash is blocked, never sent to the model**, and both
   known *and* unknown slash submissions are **echoed into the conversation
   pane** (what the user reads) but **not into the agent's message history**
   (what the model sees):
   - known `/quit` → echo `"/quit  quits the app"` (the effect), run it.
   - unknown `/xyz` → echo `"/xyz  Command not found"` with the outcome in the
     `:error` (red) tone; nothing runs, nothing reaches the agent.
   - The echo is a plain `Shared::ConversationWindow#add_block(...)` — that verb
     writes a styled block into the transcript view directly and does **not**
     append to the pikuri agent's context. (A command that *wants* to feed the
     agent would do so itself; "to be designed later.") So the conversation
     pane grows a legitimate new content category — local command echo +
     outcome — distinct from both the LLM stream and the diagnostic log pane.

## Interplay to get right (the one tricky bit)

`Shared::InputWindow::Area` already overrides `handle_key` to intercept
`ENTER` → submit-and-clear. The popup wants `ENTER` too (execute command) when
visible. **One owner must arbitrate Enter**, and it's the Area — it already
owns Enter and the buffer:

```
Enter pressed:
  popup.visible?  → popup executes selected command; clear buffer; consume
  else            → existing submit-and-clear (or blank no-op)
```

`Up`/`Down`/`Esc` while visible → forward to popup, consume. Ordinary keys →
fall through to normal editing, and `on_change` re-syncs the popup.

Buffer clearing on accept is the Area's job (it owns the buffer); running the
command is the command's callback. So accept = `clear buffer` + `run callback`
(callback deferred one tick like `LeaderMenu`, so any popup the command opens
doesn't stack under this one closing).

## Proposed COP decomposition

Follows the house shape: a domain component that takes data + renders itself,
driven by the prompt that owns the buffer/keys.

Per COP self-sufficiency, we start with **one cohesive component**, not a
view/controller/registry split (that would be the MVC layering the `cop` skill
warns against). The `SlashMenuPopup` does everything the slash surface needs
— hold the catalog, filter, render, navigate, execute, and report the outcome —
and `InputWindow` drives it with three verbs.

**Escape hatch (agreed):** if execution grows hairy — once skill commands need
the agent, a skills catalog, and richer conversation writes — pull a
non-widget *service* out of the popup (holding `conversation` + `agent` +
skills + …), leaving `SlashMenuPopup` to only *pick* a command and fire "user
chose command X". Not now: matching typed text is small, and folding execution
into the popup keeps one box. Revisit when it stops being small.

### `Shared::SlashCommand` (value object)

```ruby
SlashCommand = Data.define(:name, :description, :callback)
#   name        "/quit"
#   description "quits the app"   — the autocomplete right-column hint ONLY
#   callback    zero-arg app action; RETURNS a String outcome (or nil),
#               displayed below the command in the conversation. Run deferred.
```

Two distinct strings now: `description` is the static autocomplete hint (right
column of the popup list); the **callback's return value** is the post-execution
outcome shown *below* the echoed command in the conversation pane. This lets a
command produce a dynamic outcome ("Created task #5.") rather than parroting its
hint. Parallel to `Shared::LeaderMenu::Action` (key/label/callback). `/exit` and
`/quit` are two separate entries (both shown, both quit).

### `Shared::SlashMenuPopup` (a `Tuile::Component::Popup`)

The whole slash surface as one self-sufficient component. Widget-suffix
`*Popup` (subclasses `Popup`, like `GitDiffPopup` / `Shared::Log::Popup`).
Reaches *downward* to the conversation window to echo outcomes — an allowed COP
dependency (UI → UI, toward what it renders), and what makes it self-sufficient.

- ctor: `screen:` (defer callbacks, size/anchor), `commands:` (catalog),
  `conversation:` (`Shared::ConversationWindow`, for the outcome echo).
- `commands=` — replace catalog (data in, domain terms).
- `#sync(prefix)` — `prefix` = buffer when it starts with `/`, else `nil`.
  `nil` or no matches → close; else open (if closed), rebuild `list.lines` from
  matching commands, size to full-width−1 / 10-tall, anchor to the bottom over
  the input.
- `#visible?` → `open?`.
- `#handle_nav_key(key)` — `UP`/`DOWN` move the list selection, `ESC` closes.
  Returns truthy iff consumed. *Called by `Area`'s key forwarder, not by
  dispatch — focus stays in the field.* (Enter is arbitrated by `Area`, not
  here, so it doesn't reach this.)
- `#submit(buffer)` — the execution + echo path, called by `Area` on Enter for
  any leading-`/` buffer:
  - resolve: the highlighted list row if `visible?`, else first-whitespace-word
    exact match against the catalog.
  - found → echo the command name, run `callback` (deferred one tick, so a
    command that opens a popup — `/diff` — doesn't stack under this one
    closing), and echo its returned String *below* the command:

    ```
    /diff
    Opened the git diff.
    ```
  - not found → echo the command name with `"Command not found"` below it in the
    `:error` (red) tone; run nothing. **Either way the agent is never called.**
  - close the popup.
  - Ordering note: the callback runs deferred, and its return is what we render
    below — so render-outcome happens after the callback returns. `/quit` /
    `/exit` tear the screen down inside the callback, so their outcome line is
    never seen (harmless — nobody's left to read it).
- Rows render as two-column `StyledString`s: name left-padded to the widest
  name (col 1), description in a dimmer tone (col 2). Owns the "slightly
  distinctive background" (see Theming).

Filtering / resolving both key off `prefix.split.first` so a future
`"/cmd args"` still narrows on `/cmd`.

### `Shared::InputWindow` — grows an optional `slash_menu:`

`InputWindow.new(on_submit:, slash_menu: nil)`. The prompt legitimately owns
command completion (self-sufficiency: it does everything prompting needs), and
its private `Area` already owns Enter + the buffer, so it's the arbiter. `Area`
gains:

- after any buffer change → `slash_menu&.sync(prefix)`.
- Enter (see the arbitration section): `slash_menu` present **and buffer starts
  with `/`** → `slash_menu.submit(text)`; clear buffer; consume. Else existing
  submit / blank no-op.
- Up/Down/Esc while `slash_menu&.visible?` → `slash_menu.handle_nav_key(key)`.

`slash_menu` stays optional (nil) so `InputWindow` remains usable bare and
testable without the popup.

### Per-shell wiring (in each `App#build`, post-screen)

Mirrors `build_leader_menu`. Each App builds its catalog + the popup (handing it
the conversation window it already built), then the `InputWindow`:

```ruby
def build_slash_commands
  cmds = [Shared::SlashCommand.new('/exit', 'quits the app') { quit },
          Shared::SlashCommand.new('/quit', 'quits the app') { quit }]
  cmds << Shared::SlashCommand.new('/diff', 'show the git diff') { @sidebar.open_diff } # code only
  cmds
end
# @slash_menu = Shared::SlashMenuPopup.new(
#   screen: @screen, commands: build_slash_commands, conversation: @conversation_window)
# @input_window = Shared::InputWindow.new(
#   on_submit: @session.method(:submit), slash_menu: @slash_menu)
```

Chat / Computer: `/exit`, `/quit`. Code: `+ /diff`.

## Theming — the distinctive background (blocked on a Tuile feature)

**Investigated (`../tuile`):** there is no whole-component background knob.
`List#repaint` (list.rb:275) paints each row via `paintable_line`; the only
`bg:` applied is the per-row cursor highlight (`active_bg_color`). Content rows
are padded to full width but drawn on the terminal default; **blank filler rows**
(when < 10 matches) use an internal `@blank_padded` unreachable from outside
`lines=`. `Window` paints only its border; `TextArea`/`TextField` have an
`input_bg_color` well, but `List` has none. So a per-row `.with_bg` hack would
tint the matched rows and leave the filler rows below them untinted — a ragged
half-shaded box.

**Plan (agreed — we own Tuile):** filed a Tuile feature request for a
background-fill color on `List` (fills every row incl. blanks; the cursor row
composes `active_bg` on top), suggesting a general `Component#background_color`
as the cleaner shape:

- **https://github.com/mvysny/tuile/issues/1**

Then here: add a `:menu_bg` custom token to `Shared::AppTheme` (DARK/LIGHT) and
set it on the popup's list. Build the rest of the slash infrastructure now; wire
the distinctive background once the Tuile feature ships.

## Open questions (still to settle during implementation)

1. **Distinctive background** — blocked on the Tuile `List` background-fill
   feature (see Theming). Build without it; wire `:menu_bg` when it ships.
2. **Sizing/anchor detail** — full-width−1 each edge, 10 tall, anchored **over
   the input** (not caret-tracking, per decision). Confirm the anchor math
   against the input window's rect and that it tracks terminal resize.
3. **Future: unify with the leader menu / add skills.** Out of scope now; the
   `SlashCommand` catalog is the seam skills will plug into later, likely via
   the service escape hatch above.

## Specs plan

- `Shared::SlashCommand` — trivial value object, no spec of its own.
- `Shared::SlashMenuPopup` — `sync` open/close/filter transitions, row
  rendering (two columns, right command matched), `handle_nav_key` selection
  moves, `submit`: known → outcome echoed to conversation + callback fired
  (deferred), unknown → red "Command not found" + no callback + agent untouched,
  full-width−1 / 10-tall sizing. Fake screen + a real/fake `ConversationWindow`.
- `Shared::InputWindow` — Enter arbitration (leading-`/` → `slash_menu.submit`
  vs normal submit vs blank no-op), nav-key forwarding while visible, `sync` on
  change, blank / no-menu paths unchanged.
- App specs: each shell registers the expected command set (code has `/diff`,
  others don't).

## Graduation (when implemented)

Delete this file; propagate: package-map lines for the new files into
`AGENTS.md` Layout; the "shared building block" note into the dedup list;
class rdoc carries the Enter-arbitration contract + UI-thread confinement.
