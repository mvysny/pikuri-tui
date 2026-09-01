# The next tuile bump retires all three borderless workarounds

**Status:** waiting on a tuile release. Everything below is already fixed
upstream in `~/work/my/tuile`, all of it under `## [Unreleased]` — the tag tip
is still `v0.14.0` and `VERSION = "0.14.0"`, which is what our
`gem 'tuile', '~> 0.14'` resolves to. Nothing to do until there's a version to
bump to.

Trigger: read tuile#10 (the scrollbar has no theme token). It's closed. So are
#9 and #11 — the whole "Three borderless workarounds are waiting on upstream
tuile" table in AGENTS.md goes away in one bump.

## What landed upstream

Issue #10 → commit `4684344`, `feat(scrollbar)!: theme the bar, quiet it when
nothing scrolls, swappable glyphs`. Rationale in tuile's `DECISIONS.md`
`D_scrollbar_ink`.

- `Theme#scrollbar_color` — a **required fifth token**, read at paint time by
  both `paintable_row`s (`TextView` and `List`). `DARK` = `GREY37` (the
  `active_bg_color` value, so the handle carries the selection well's weight);
  `LIGHT` = `GREY62`, a step darker than the highlights because it's a
  *foreground* against pale. `VerticalScrollBar` stays pure geometry, reaching
  no `Screen`; the components style the span.
- **No handle when `row_count <= height`** — the solid full-height `█` is gone,
  the bar just shows its track. Deliberately an *ink* rule, not a visibility
  one: `scrollbar_visible?` stays true, the column stays reserved,
  `content_width` / `wrap_width` never move. That's what sidesteps the reason
  `:auto` is refused (`D_select`: height-dependent visibility makes the content
  width height-dependent, and the padded-row cache is rebuilt from the
  width-only `on_width_changed`). **`:auto` is not coming** — don't ask again,
  this is what we wanted from it.
- `VerticalScrollBar.handle_char=` / `.track_char=` — the two glyphs as an
  app-global knob (`▐` over `│` for a lazygit bar), validated at assignment to
  exactly one grapheme cluster one column wide.

Issue #9 → `TextView#scrollbar_columns` now reserves the blank column itself:
`0` when the bar is hidden, `2` when visible and `rect.width >= 3`, `1` below
(the blank is dropped where reserving it would leave no column for text at
all). That is *semantically identical* to our `SCROLLBAR_GUTTER` guard — ours
is `scrollbar_visible? && rect.width > SCROLLBAR_GUTTER + 1`, i.e. `width >= 3`
for `SCROLLBAR_GUTTER == 1`. Same cutoff, same contract ("exactly `rect.width`
columns" at every width).

Issue #11 → `Component#bg_color` is no longer inert on `TextField` / `TextArea`
/ `Select` / `ComboBox`; setting one on a field now wins over its well.

## The trap this closes (and why it's moot)

Worth writing down because it nearly was a silent regression:
`Shared::ConversationTextView#paintable_row` builds the scrollbar glyph itself
with `Tuile::StyledString.plain(...)`. Upstream's new `paintable_row` is the
thing that applies `screen.theme.scrollbar_color`. **Our override would have
bypassed the new theming entirely** — the one pane that must keep its bar (the
conversation, since PageUp/PageDown from the prompt drive it) would have stayed
loud after the bump, with the fix apparently "not working".

It's moot only because #9 landed alongside: we delete the override, so we
inherit the themed bar for free. If for any reason we keep a `paintable_row`
override, it has to become
`plain(gutter) + styled(char, fg: screen.theme.scrollbar_color)`.

## The bump checklist

1. **Delete the tuile#9 pair** in `Shared::ConversationTextView`:
   `SCROLLBAR_GUTTER`, `#wrap_width`, `#gutter_width`, `#paintable_row`. This is
   the fragile one — `paintable_row` is *private* upstream and is the only
   private-Tuile lean in the repo. Its rdoc already says to delete it when #9
   lands.
   - The specs pinning it (`spec/shared/conversation_text_view_spec.rb`, the
     `describe 'the scrollbar gutter'` block ~L44–70, plus the read-back at
     ~L565 that reads "one column short of the pane so the scrollbar gutter's
     glyph…") mostly *keep their assertions* — the wrap should still stop one
     column short — but they now pin upstream behaviour rather than ours.
     Re-point them at `scrollbar_columns` rather than deleting.
2. **Delete `Shared::InputPane::Area#background`** (tuile#11), replaced by
   `@area.bg_color = Tuile::Theme.ref(:pane_bg)`. The private `Area` subclass
   may not need to exist at all after that — it still rebinds Enter, so it
   probably does; check.
3. **Decide `scrollbar_color`** in `Shared::AppTheme`. We are *not* broken by
   the breaking change: `DARK`/`LIGHT` are built as
   `new(**Tuile::Theme::DARK.to_h.merge(hint_color: …, custom: …))`, so the
   fifth token rides along from the base theme. Question is whether we take
   `GREY37`/`GREY62` or derive one off the tint/Talus palette. Leaning: derive
   it in `.derived` alongside `:pane_bg` / `:pane_frame`, since the conversation
   bar sits on the *untinted* primary pane while every other rule in the app
   sits on `:pane_bg` — a fixed grey may read wrong against a user's terminal
   ground. Measure before deciding; don't invent a token.
4. **Sidebar panes stay `:gone`.** The AGENTS.md row says "revisit
   `scrollbar_visibility` in `Code::TaskListPane` / `Code::GitSummaryPane`" —
   the answer is **no**. They dropped the bar because nothing in the sidebar
   takes focus, so it was inoperable decoration; the ink fix addresses
   loudness, not inoperability. Resolved, not deferred.
5. **Drop the whole workarounds table** from AGENTS.md's "Working on this
   codebase", and the "Neither sidebar pane carries a scrollbar" note in the
   Layout section keeps its focus-based reason (it never rested on the ink).
6. `handle_char=` / `track_char=` — probably leave alone. Open question below.

## Also in that Unreleased batch (check before bumping)

The scrollbar work isn't the only thing between us and a release.

- **Breaking: `Component::Label#bg` / `#bg=` are gone.** Grepped `lib/` — we
  don't use them. `Code::DiffRenderer`'s
  `StyledString::Style.new(bg:)` and `Grayscale`'s `with_bg(nil)` are different
  APIs and unaffected. Safe, but re-grep at bump time.
- `Component#default_bg_color`, `Component::BG_INHERIT`, and a state-keyed
  `bg_color` (`{ normal:, active: }`). All additive. `BG_INHERIT` is
  interesting for us: it's the sanctioned way for a widget owned by a bigger
  one to drop its own well and take the surrounding tint — which is exactly
  what `Shared::InputPane` and `Code::WorkspaceSidebar` do by hand. Possibly a
  cleaner item 2 than `bg_color = Theme.ref(:pane_bg)`. Read `D_bg_surface`
  before choosing.
- `Tuile::Final`. Not our problem unless it lands on a class we subclass —
  and we subclass `TextView`, `TextArea`, `Theme`, `Window`. Worth a quick
  check that nothing we override got marked final (`#paintable_row` above all,
  though we're deleting that one anyway).

## Open questions

- Do we want a lazygit-style `▐`/`│` bar? It's two lines at boot and it's a
  look-and-feel call, not a fix. Against: `█`/`░` already carry the
  density difference, and `│` next to our hairline `─` rules and the sidebar's
  `│` separator might read as *another* separator rather than a scrollbar.
  Lean no; revisit if the themed `░` still reads noisy in practice.
- Is `Code::GitDiffWindow`'s own width arithmetic affected? Its comment at
  ~L92 mentions "scrollbar gutter" in computing a floored wrap width, and it
  sets `self.scrollbar = true` inside a `Window`. It's not one of the three
  workarounds, but it may be doing its own version of the same subtraction —
  check it against `scrollbar_columns` at bump time.
- `Code::ConfirmerPopup` L406 similarly budgets "the `TextView`'s scrollbar and
  margin". Same check.

## When this is done

Delete this file. Durable nuggets to propagate first:

- AGENTS.md: remove the three-row workarounds table and the
  `Shared::ConversationTextView` Layout entry's `SCROLLBAR_GUTTER` sentence.
- Keep, somewhere durable, the *one* thing that isn't in the code after the
  cleanup: **`:auto` scrollbar visibility is refused upstream on purpose**
  (`D_select`), and the no-handle-when-fits behaviour is an ink rule that
  deliberately does not move any width. Without that note someone will file
  tuile#10 again. A line in the `Code::TaskListPane` / `Shared::ConversationTextView`
  rdoc is probably the right home.
