# Prompt history (Up/Down recall in the input window)

Status: design settled, nothing implemented — but the upstream blocker is gone.
[tuile#3](https://github.com/mvysny/tuile/issues/3) landed as
`TextArea#caret_row` / `#row_count` (see *Solved* below), so this is now
buildable entirely in `Shared::InputWindow::Area`.

## The ask

Up in the prompt recalls the previous submitted message, cursor at end of
text. Down recalls the next one. Enter sends it exactly as if typed. When the
buffer is non-empty, Up only recalls if the caret sits in the first row
(otherwise it moves the caret, as today).

## Agreed shape

A list of submitted messages, oldest → newest, with **the draft pinned at the
bottom** past the newest — the *virtual entry*: whatever you typed but haven't
sent sits in the history like a real entry, so browsing away from it and back
is lossless. The prompt tracks a position that starts at the draft; Up walks
toward older, Down toward newer and stops at the draft. Both clamp. The buffer
always shows the entry at the position.

(No index arithmetic in this doc on purpose — "the third-oldest" is not a
thing anyone thinks in. Positions are named: *older*, *newer*, *the draft*.)

**The store is append-only and immutable; the draft is the only mutable
slot.** History entries are shown, never written to. Typing over a recalled
entry changes only what's on screen — navigate off and the entry is back as
you sent it. So:

- edit + navigate away → the edit is gone, the entry reads as submitted;
- edit + ESC → same, and you land back on your intact draft;
- edit + Enter → a *new* entry appends at the end, the recalled one untouched
  where it was. The text enters the pipeline as if typed from scratch — which
  is also why it appends rather than moving to the top.

This is the strict model, chosen over per-entry scratch overlays. The scratch
state is then exactly **one string** (the draft) rather than a map of saved
edits needing lifecycle rules — and the behaviour states in one line: *the
arrows always show you exactly what you sent; the only text the prompt
remembers for you is the one thing you never sent.* Cost, accepted: tweak a
recalled message, wander off with Up, come back — the tweak is gone. The fix
is the thing you were going to do anyway (Enter, which appends it).

Knock-on of append-on-submit: re-sending an old entry unchanged appends a
copy, so the same text may appear twice at different positions. Intended —
dedup collapses only *consecutive* duplicates, so re-sending the
immediately-previous message doesn't grow the list while re-sending something
older does.

Entry/exit rules:

- Up: caret in first row → step to the older entry (else move the caret,
  unchanged).
- Down: caret in last row → step to the newer entry (else move the caret).
- On recall the caret goes to the very end of the text (both directions).
- Submit: append to history, clear the draft, return the position to it.

**"Row" means a *visual* row, not a logical line.** The input strip is 5 rows
tall (3 editable lines, `Chat::Layout::INPUT_HEIGHT`) and `TextArea`
hard-wraps at the pane width, so a long single-line message with no `\n` in it
still occupies several rows. The rule is therefore "Up moves the caret unless
there is nowhere up to go" — exactly what you see on screen, and what
`move_caret_vertical` already does. Navigating by logical lines would make the
caret jump out of the middle of visibly-wrapped text; confusing UX, rejected.

Multi-line entries are live behaviour, not future-proofing: Enter is rebound
to submit, but a *pasted* line break arrives as `\n` (`Keys::CTRL_J`, which
`TextArea` accepts alongside `\r` precisely so a paste doesn't lose its
newlines) and inserts, so a buffer can hold hard breaks as well as wraps.

Recalling something taller than the 3 editable lines relies on the area
scrolling to keep the caret (at the end) visible. That is `TextArea`'s job —
if it doesn't, it's a Tuile bug to fix upstream, not something this feature
works around. The strip stays fixed-height either way; no growing input pane.

Consequence worth noting: recall lands the caret on the *last* row, so
travelling further back through a multi-line entry means walking up through it
first. That falls out of the first-row rule and is what fish/zsh do. Going
*forward* needs no walk (already on the last row) — deliberate asymmetry:
backwards is browsing, forwards is rewinding to your draft.

## Ownership: the prompt keeps its own list

History is **not** derived from the agent's conversation log. Three reasons,
any one of them sufficient:

- It outlives `/clear` (leader-`c`), which wipes the agent's context.
- Slash commands are entries, but they never reach the agent's context —
  `Shared::SlashMenuPopup` echoes them into the conversation *pane* only.
- The draft is unsent text; it has no representation in a conversation log at
  all.

(And the log is lossy the other way too: it carries system-injected messages
the user never typed, so deriving would mean filtering.) So the record lives
with the prompt — appended at submit, in memory, dying with the process.

## What Tuile gives us

Checked against `../tuile` at 5d65960 (unreleased, post-0.11.0 — we already
consume it via `gem 'tuile', path: '../tuile'`).

- **Scrolling to the caret is free.** `caret=` fires `on_caret_mutated` →
  `TextArea#adjust_scroll_top_row`, which scrolls so the caret's row is
  visible. Recall = `self.text = entry` then `self.caret = text.length`, and a
  recall taller than the strip lands scrolled to the bottom with no work from
  us. The earlier "verify this or it's a Tuile bug" item is settled: it's
  implemented.
- **Buffer + caret are public.** `text=` / `caret=` both clamp and snap to
  grapheme boundaries. Order matters — text first (it clamps the caret), caret
  second.
- **Key interception needs no new seam.** We already override the public
  `handle_key`; the documented subclass hook is the protected
  `handle_text_input_key`, and `on_key` exists as a composition seam
  (first refusal before the default handling).
- **The row math exists and is correct** — grapheme-cluster aware, wide
  glyphs, hard breaks, whitespace absorbed at soft wraps. We must never
  reimplement it; an empty buffer reports exactly one row, so first == last and
  both arrows recall, as specified.

### Nomenclature: "display row" is now just "row"

The same unreleased line renamed Tuile's scrolling vocabulary (57fc4ef): a
wrapped unit of text *is* a **row**, `line` means a `\n` unit, and
`TextArea#top_display_row` is now `#scroll_top_row`. So this doc's "visual row,
not logical line" disclaimer above is now sayable in Tuile's own words — *row*
vs *line* — and we should use them when this lands in rdoc.

## Solved: "is the caret in the first/last row?" — tuile#3 landed

[tuile#3](https://github.com/mvysny/tuile/issues/3) is **closed**; the
resolution went to the *readers*, not the `on_caret_vertical_overflow` hook
this doc preferred. `TextArea` gained two public one-liners over the (still
private) wrap:

```ruby
def caret_row = wrap.row_at(@caret)   # 0            => Up has nowhere to go
def row_count = wrap.row_count        # >= 1; caret_row == row_count - 1 => same for Down
```

Why not the hook (Tuile's `DECISIONS.md` `D-text-area-rows`, condensed): it
would be a *fourth* key-interception mechanism next to `on_key`,
`handle_text_input_key` and the ancestor bubble; it names an implementation
moment inside `move_caret_vertical` rather than an event, so its firing
condition could drift under us, where `caret_row == 0` cannot; and it points
the arrow the wrong way — the framework consulting the app, where Tuile
consistently prefers an optional read-only caller-side query. The
"re-derivation" the hook was meant to save us turns out to be `- 1`.
Publishing `wrap` / `WrappedText` wholesale was rejected too (it's a lazy
cache, nilled on text/width change — a handed-out reference answers
confidently about text the widget no longer holds).

So our side of the feature is now pure app code, no upstream dependency, and
the spec is expressible exactly as agreed:

```ruby
# Shared::InputWindow::Area, protected — Tuile's own recipe from TextArea's rdoc
def handle_text_input_key(key)
  return recall_older if key == Tuile::Keys::UP_ARROW && caret_row.zero?
  return recall_newer if key == Tuile::Keys::DOWN_ARROW && caret_row == row_count - 1

  super # anywhere else: the caret moves, and the unclaimed edge still snaps
end
```

**Which of our two override points takes which key** — a layering that falls
out of the ladder (`handle_key` → `on_key` → `handle_text_input_key`) and
matches the precedence we decided:

- the **public `handle_key`** keeps the slash-palette arbitration it already
  has (Up/Down/ESC to the palette *while shown*, Enter on a leading-`/`
  buffer). It runs first, so the palette keeps winning Up/Down/ESC for free —
  no `@slash_menu.visible?` test in the history branch.
- the **protected `handle_text_input_key`** gets the recall branches above.

ESC is *not* a third branch there: `AbstractStringField` ships a dedicated
`on_escape` seam (fired from its own `handle_text_input_key`, `nil` → let ESC
bubble). Our two non-palette tiers — browsing → jump to the draft, otherwise →
clear the buffer — go in an `on_escape` we set. Note it **replaces** Tuile's
default, which clears focus (`screen.focused = nil`); we don't want a prompt
that un-focuses itself on ESC anyway, so that's a loss worth taking, but it's a
behaviour change to mention when this lands.

Both recall methods return `true` to consume the key. `super` at the end keeps
Tuile's edge snap for any edge we don't claim — worth a spec of our own, since
we claim both.

Rejected earlier, still rejected: a rule of "Up recalls when the caret is at
character 0" (and Down at `text.length`). It needed no Tuile change, but costs
a second press from any non-empty buffer and isn't the behaviour we agreed —
and it's moot now that `caret_row` exists.

## Recall must not open the slash palette

Not a Tuile issue — ours. `text=` fires `on_change`
(`abstract_string_field.rb:127`) and `Area` wires `on_change` →
`slash_menu.sync`. So recalling an entry that starts with `/` would open the
palette, and by our own precedence rule the palette then owns Up/Down/ESC —
history navigation trapped after one recall of a slash command.

**Decided**: suppress the palette for the duration of a recall (a guard around
the assignment). Recall isn't typing, and the palette is
autocomplete-as-you-type; a recalled `/trifecta` sits inert until you either
press Enter (which runs it, since `handle_key` tests the buffer's leading `/`,
not the palette's visibility) or type a character — which fires `on_change`
and opens the palette, correctly filtered.

## Open before coding

Three, all app-side; none needs Tuile.

1. **What a recall returns when there's nothing to recall.** The sketch above
   reads `return recall_older if key == UP_ARROW && caret_row.zero?` — so if
   `recall_older` returned `false` at the oldest entry, the method returns
   `false` *without reaching `super`*, and the key bubbles to the parent as
   unhandled. That's the one shape we must not ship. Proposed: **the recall
   methods always return `true`** — at the oldest, Up is a silent no-op, and at
   the draft, so is Down. Deliberately *not* falling through to Tuile's edge
   snap: having Up jump the caret to character 0 only once you've hit the end
   of history is a lurch, and the snap is not behaviour anyone asked for here.
   Consequence: the prompt loses the snap-to-start/end gesture entirely (both
   edges are claimed) — accepted, ESC and Home/End cover it.
2. **When the draft is snapshotted.** Not continuously from `on_change` — that
   would let editing a *recalled* entry overwrite the draft, breaking the one
   slot the strict model promises to preserve. Proposed: **capture on leaving
   the draft**, i.e. the first Up while the position is at the draft copies the
   buffer into it; nothing else ever writes it but a submit (which clears it).
3. **Where the store lives.** Proposed: a small `Shared::PromptHistory` —
   `#append` / `#older` / `#newer` / `#draft=` / `#reset`, no Tuile, no Pikuri —
   composed by `Area` rather than a clutch of ivars on it. `Area` already
   arbitrates the palette, Enter and submit; the list is a cohesive thing with
   its own rules (append-only, consecutive-dedup, the pinned draft, clamping)
   that unit-tests without a screen. The alternative (ivars in `Area`) is
   fewer files but tests only through key presses.

Also worth noting, not a question: **two call sites append**, not one —
`Area#submit` (turns and mid-turn injections) *and* `Area#submit_command`
(slash commands, which never reach `on_submit`). Missing the second would
silently drop exactly the entries the *Ownership* section says we keep history
for.

## Decided

- **No persistence.** In-session, in-memory, per process, dies with the app.
  No file, no cap needed, no config switch, no user prose on disk. Revisit in
  a follow-up if the lack bites.
- **An entry is anything the user submitted** through the prompt: turns, slash
  commands, mid-turn injections. Blank submits are not entries (the prompt
  already drops them before `on_submit`).
- **Consecutive duplicates collapse** — a submission identical to the newest
  entry doesn't grow the list (zsh `HIST_IGNORE_DUPS`).
- **Survives `/clear` / leader-`c`** (clear conversation + context). You often
  clear context to re-run a variation of what you just sent; history is an
  input-line facility, not part of the transcript.
- **ESC has three tiers**, in precedence order: palette shown → the palette
  takes it (existing behaviour); browsing → jump to the draft (intact by
  construction, since it's the only preserved slot); otherwise → clear the
  buffer, like Claude Code. Double-ESC while browsing therefore reads as one
  "get me out of here" gesture: leave history, then wipe. There is nothing
  else to reset — the strict model leaves no residue behind a browsing
  session.
- **The slash palette wins Up/Down/ESC.** Recall applies only when the palette
  is hidden — `Area#handle_key` already checks `@slash_menu.visible?` before
  forwarding (`lib/shared/input_window.rb:83`). Modal popups (confirmer,
  pickers, leader menu) own keys anyway.
