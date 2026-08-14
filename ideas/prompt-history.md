# Prompt history (Up/Down recall in the input window)

Status: brainstorming, nothing implemented.

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
to submit, but a *pasted* line break arrives as `\n` and inserts
(`text_area.rb:20`), so a buffer can hold hard breaks as well as wraps.

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

## What Tuile 0.11.0 already gives us

Checked against `tuile/component/text_area.rb` + `abstract_string_field.rb`.

- **Scrolling to the caret is free.** `caret=` fires `on_caret_mutated` →
  `TextArea#adjust_top_display_row`, which scrolls so the caret's row is
  visible (`text_area.rb:387-401`). Recall = `self.text = entry` then
  `self.caret = text.length`, and a recall taller than the strip lands
  scrolled to the bottom with no work from us. The earlier "verify this or
  it's a Tuile bug" item is settled: it's implemented.
- **Buffer + caret are public.** `text=` / `caret=` both clamp and snap to
  grapheme boundaries. Order matters — text first (it clamps the caret), caret
  second.
- **Key interception needs no new seam.** We already override the public
  `handle_key`; the documented subclass hook is the protected
  `handle_text_input_key`, and `on_key` exists as a composition seam
  (first refusal before the default handling).
- **The visual-row math exists and is correct** — grapheme-cluster aware, wide
  glyphs, hard breaks, whitespace absorbed at soft wraps. We must never
  reimplement it; an empty buffer reports exactly one row, so first == last and
  both arrows recall, as specified.

## The one gap: "is the caret in the first/last display row?"

Public API answers half of it: `cursor_position.y - rect.top +
top_display_row` is the caret's absolute display row, so *first row* is
`== 0`. The row **count** lives in the private `display_rows`, so *last row*
has no public answer.

Three ways out, in preference order:

1. **Ask Tuile for the overflow hook** (preferred FR).
   `move_caret_vertical` already detects our exact condition — `new_row ==
   cur_row` means "nowhere to go in that direction" — and currently responds
   by snapping the caret to the start/end of the text. Add a protected hook
   there, consulted before the snap:

   ```ruby
   # @param delta [Integer] -1 for up, +1 for down.
   # @return [Boolean] true if the subclass consumed the overflow.
   def on_caret_vertical_overflow(delta) = false
   ```

   Then our `Area` overrides it and touches no row math at all: Tuile owns the
   wrap and the "nowhere to go" decision, we own what happens instead. Useful
   beyond us (a `TextArea` in a scrolling container, Down as tab-to-next-field).
2. **Or public readers** `#caret_display_row` / `#display_row_count` — both
   one-liners over the existing privates, more general, and they'd let anyone
   build this. Weaker for us than the hook (we'd re-derive a decision Tuile
   already makes) but worth having anyway.
3. **Interim without touching Tuile:** Ruby lets a subclass call the inherited
   private `caret_to_display` / `display_rows`, so the exact spec is reachable
   today. Works, but couples us to the wrap cache's `{start:, length:,
   columns:}` shape — acceptable as a stopgap, not as the answer.

Rejected: a public-API-only rule of "Up recalls when the caret is at
character 0" (and Down at `text.length`). It needs no Tuile change and
dovetails with the existing snap, but costs a second press from any non-empty
buffer and isn't the behaviour we agreed.

## Open: recall must not open the slash palette

Not a Tuile issue — ours. `text=` fires `on_change`
(`abstract_string_field.rb:127`) and `Area` wires `on_change` →
`slash_menu.sync`. So recalling an entry that starts with `/` opens the
palette, and by our own precedence rule the palette then owns Up/Down/ESC —
history navigation is trapped after one recall of a slash command.

Proposed: suppress the palette for the duration of a recall (a guard around
the assignment). Recall isn't typing, and the palette is autocomplete-as-you-
type; a recalled `/trifecta` should sit inert until you either press Enter or
type a character (which fires `on_change` and opens it, correctly filtered).

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
