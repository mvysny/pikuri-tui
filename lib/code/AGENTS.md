# `Code::` — AGENTS.md

The coding shell (`bin/pikuri-tui-code`) — and the source of the confirmer / diff adapters the
computer shell reuses verbatim, so a change here is a change to two shells. `Code::App` and
`Code::Layout` are deliberate parallel copies of the chat shell's, never a subclass
(`D_parallel_shells`; `code.rb` carries the rule next to the code). `ls` is the class index.

## Invariants

- **`Code::TranscriptConfirmer`'s keys are live only while the transcript holds focus.** That is what makes them safe to spell `y`/`n`; no grace window, no timer. See `D_transcript_confirmer`.
- **Decline-by-default lives in exactly two places** — `Ctrl+C` and quit, both through `#reject_pending!`. Skip either and a parked tool leaves `Ctrl+C` looking broken, because the worker is blocked on the answer.
- **The `edit` / `write` diff blocks are never kinded**, so no density toggle can hide them: a diff is reviewed, not skimmed. See `D_density_thunks`.
- **`Code::GitWatcher` must keep polling while the sidebar is off screen** — the status-rule digest stands in for the hidden panes. Hide with `visible=`, never by detaching. See `D_visible_not_detach`.
- **A gated skill must not be *listed*.** `Code::SkillActivationListener` builds the palette's skill half from pikuri's activation, not its catalog, and re-lists as the `paths:` gate opens and closes — pikuri's `decisions.md` → `skill_path_activation` closed the operator exemption.

Maintenance: the root `AGENTS.md`'s rules; cap 10 KB.
