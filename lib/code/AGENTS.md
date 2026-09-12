# `Code::` — AGENTS.md

This directory's must-not-break list and class map, loaded beside the root `../../AGENTS.md` when
work touches it. One-line invariants and pointers only; the truth lives in each class's rdoc, the
roads not taken in `../../design/decisions.md`. ≤ 10 KB.

The coding shell (`bin/pikuri-tui-code`) — and the source of the confirmer / diff adapters the
computer shell reuses verbatim, so a change here is a change to two shells. `Code::App` and
`Code::Layout` are deliberate parallel copies of the chat shell's, never a subclass
(`D_parallel_shells`; `code.rb` carries the rationale next to the code).

## Invariants

- **`Code::TranscriptConfirmer`'s keys are live only while the transcript holds focus.** That is what makes them safe to spell `y`/`n`; no grace window, no timer. See `D_transcript_confirmer`, `R_human_gated_egress`.
- **Decline-by-default lives in exactly two places** — `Ctrl+C` and quit, both through `#reject_pending!`. Skip either and a parked tool leaves `Ctrl+C` looking broken, because the worker is blocked on the answer.
- **The `edit` / `write` diff blocks are never kinded**, so no density toggle can hide them: a diff is reviewed, not skimmed. See `D_density_thunks`.
- **`Code::GitWatcher` must keep polling while the sidebar is off screen** — the status-rule digest stands in for the hidden panes. Hide with `visible=`, never by detaching. See `D_visible_not_detach`.
- **A gated skill must not be *listed*.** `Code::SkillActivationListener` builds the palette's skill half from pikuri's activation, not its catalog, and re-lists as the `paths:` gate opens and closes. See pikuri's `D_skill_path_activation`, which closed the operator exemption.

## Classes

- `app.rb` — `Code::App`: the shell; agent build, confirmer, sidebar, plan mode, the three-namespace palette.
- `layout.rb` — `Code::Layout`: the dual-column root; owns the `│` separator and the sidebar-width modes.
- `workspace_sidebar.rb` — `Code::WorkspaceSidebar`: tasks over changes; owns the watcher lifecycle and the digest.
- `task_list_pane.rb` — `Code::TaskListPane`: the task pane plus its `Tasks::ListChanged` listener.
- `git_summary_pane.rb` — `Code::GitSummaryPane`: the "Changes" pane, grouped by directory, counts right-aligned.
- `git_watcher.rb` — `Code::GitWatcher`: the background git poller as a UI-independent service; owns `Snapshot` / `Change`.
- `git_diff_window.rb` — `Code::GitDiffWindow`: the working-tree diff pane, re-rendered on resize.
- `git_diff_popup.rb` — `Code::GitDiffPopup`: the fullscreen popup wrapping that window (leader `d`).
- `git_diff_renderer.rb` — `Code::GitDiffRenderer`: plain `git diff` → the tool diffs' two-tier inline form.
- `diff_renderer.rb` — `Code::DiffRenderer`: a before/after pair as a two-tier ANSI diff; screen-agnostic.
- `diff_tool_formatting.rb` — `Code::DiffToolFormatting`: the call-time diff block and result-time error line.
- `edit_formatter.rb` — `Code::EditFormatter`: the `edit` tool formatter; diffs straight from the call arguments.
- `write_formatter.rb` — `Code::WriteFormatter`: the `write` tool formatter; diffs the on-disk file against `content`.
- `transcript_confirmer.rb` — `Code::TranscriptConfirmer`: asks in the transcript; approve / edit / reject.
- `confirm_renderer.rb` — `Code::ConfirmRenderer`: paints one sanitized request as that block; no key cue.
- `plan_mode_listener.rb` — `Code::PlanModeListener`: drives the status rule's plan-mode badge.
- `skill_activation_listener.rb` — `Code::SkillActivationListener`: mirrors pikuri's `paths:` gate into palette and transcript.
- `trust_store.rb` — `Code::TrustStore`: the persisted git-config-trusted roots; asked once per project.
- `privacy_store.rb` — `Code::PrivacyStore`: the persisted private/public answer (tri-state) feeding the workspace.
