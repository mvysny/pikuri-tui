# Refactoring: fold the `*TextView` panes into their `*Window`s

Rationale and the design lesson behind this live in the "DRY Rot" blog post
(mvysny.github.io). Short version: the `Window`-frames-`*TextView` split is a
fake seam wherever the view is always-wrapped and the window consumes none of
its render API. Each pane should be **one self-sufficient `*Window`** that
manages an internal bare `Tuile::Component::TextView`, owns its render verbs,
nests its `Listener` where one exists, and keeps `attr_reader :view` for tests.

## Stage 1 — git panes (low risk, code-only) — DONE

- `GitSummaryTextView` → `GitSummaryWindow`; `GitDiffTextView` → `GitDiffWindow`
  (both now `Window` subclasses rendering into their own content view).
- `WorkspaceSidebar` builds the two domain windows directly; `GitDiffPopup`
  wraps `GitDiffWindow`. No listener on either (fed by the `GitWatcher` service).
- `GitDiffWindow`'s width-reactive re-render moved to the *window's* own
  `on_width_changed` (`max_width = rect.width - 3`), so no inner view subclass is
  needed — content is a plain `TextView`.
- Specs renamed to `git_summary_window_spec` / `git_diff_window_spec`.

## Stage 2 — TaskList (moderate, code-only)

- Merge `TaskListTextView` (rendering + nested `Listener`) into `TaskListWindow`;
  delete the view class. Listener becomes `TaskListWindow::Listener` (constant
  rename across code-shell files + specs; verify by eager-load + suite).

## Stage 3 — Conversation (higher-risk; brainstorm before starting)

- Merge `ConversationTextView` into `ConversationWindow`; listener becomes
  `ConversationWindow::Listener` (ripples ~20 files across all three shells; ~47
  region/streaming touchpoints convert `self.…` → `@view.…`).
- Open question to settle at that point: merge (razor says fake seam; the real
  mechanisms — `Markdown::Renderer` / `StreamingBuffer` / `Grayscale` — are
  already extracted, so the window stays mostly orchestration), OR consciously
  keep `ConversationTextView` as a legitimate "conversation renderer" mechanism.
  Decide then, with Stages 1 & 2 proving the pattern out.
