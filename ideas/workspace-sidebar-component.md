# Idea: `Code::WorkspaceSidebar` — the tasks + git sidebar as one component

## Progress

- **DONE — `Code::TaskListWindow` extracted** (the certain, decided
  slice), then refactored to the model/view shape: it frames a
  `Code::TaskListTextView` (which owns rendering + a nested `Listener`),
  exposing `#listener`. `Code::App` composes it and the `Layout` still
  takes it via `tasks:`. It's the first building block the eventual
  sidebar will compose.
- **DONE — the git panes reframed to model/view**: `GitSummaryTextView` /
  `GitDiffTextView` now own rendering (each takes a `GitWatcher::Snapshot`);
  `GitWatcher` is a UI-independent service that emits snapshots to `#on_change`
  subscribers. (This was the old `ui-component-shaped-cop.md` Actionable 2,
  since implemented and evaporated — see the `cop` / `tuile` skills for the
  principle.)
  So the container work below now composes *reframed* panes, not the old
  plain-`TextView` + rendering-in-`GitWatcher` shape the sketch below shows.
- **PENDING — the container.** Revisit whether to wrap the git-changes pane +
  `GitWatcher` + `GitDiffPopup` + `open_git_diff_popup` + the `start`/`stop`
  lifecycle into a `WorkspaceSidebar` (likely a `Layout` subclass owning the
  tasks-over-git split), composing the already-extracted `TaskListWindow`.
  Open questions below still stand for this half. (The per-pane triple in the
  sketch below is now `GitSummaryTextView`/`GitDiffTextView` framed by their
  windows.)

## Problem

`Code::App#build_components` (`code/app.rb:229-259`) hand-assembles a
whole workspace sidebar whose parts only ever talk to each other and to
`Code::Layout(tasks:, git:)`. Three concerns tangled into the App:

1. **The repeated pane triple** — `TextView` + `Window` + `scrollbar =
   true`, built *three times* (tasks / git-changes / git-diff):

   ```ruby
   @tasks_view = Tuile::Component::TextView.new
   @tasks_window = Tuile::Component::Window.new('Tasks')
   @tasks_window.content = @tasks_view
   @tasks_window.scrollbar = true
   # …same for @git_summary_view/@git_window ('Changes')
   # …same for @git_diff_view/@git_diff_window ('Git diff') + GitDiffPopup
   ```

2. **The listeners / watcher / popup** bound to those views:

   ```ruby
   @task_listener = TaskListener.new(text_view: @tasks_view, screen: @screen)
   @git_watcher   = GitWatcher.new(summary_view: @git_summary_view,
                                   diff_view: @git_diff_view, screen: @screen)
   @git_diff_popup = GitDiffPopup.new(diff_window: @git_diff_window)
   ```

3. **The lifecycle + action** scattered into `App#run` and the leader
   menu: `@git_watcher.start` / `.stop` (run:204-210) and
   `open_git_diff_popup` (453-457) behind leader `d`.

## Sketch

`Code::WorkspaceSidebar` — a Tuile container (a `Layout` framing tasks
over git, or a component the `Code::Layout` places as one child):

- builds its two framed panes + the diff pane/popup internally.
- owns `GitWatcher` + `GitDiffPopup`; exposes `#start` / `#stop` (called
  from `App#run`) and `#open_diff` (leader `d`).
- exposes `#task_listener` for the App to fold into the agent's
  `ListenerList` (the one thing the agent build block needs).
- `Code::Layout` takes a single `sidebar:` child instead of separate
  `tasks:` + `git:`, and the sidebar owns its internal tasks-over-git
  split.

App's `build_components` sidebar section collapses to one construction;
`run` becomes `@sidebar.start` / `@sidebar.stop`.

### Sub-extraction: `Shared::TextPaneWindow`

The pane triple (#1) also appears inside `ConversationWindow`
(`conversation_window.rb:36-38`). A tiny `Shared::TextPaneWindow <
Tuile::Component::Window` (owns a `TextView`, sets `scrollbar = true`,
exposes `#view`) collapses each triple to one line and unifies the
idiom. Could land first as its own small win, or fold into the sidebar
work. Decide whether `ConversationWindow` should also be rebased on it.

## Open questions

- **Component boundary.** Is `WorkspaceSidebar` a `Tuile::Component::Layout`
  subclass (owns the tasks/git rect split itself, so `Code::Layout` just
  gives it the sidebar rect), or a plain holder the `Code::Layout` still
  positions pane-by-pane? Prefer the former — it moves the
  `TASK_HEIGHT` split *into* the sidebar and simplifies `Code::Layout`'s
  `rect=` to a two-way conversation-vs-sidebar split.
- Single-site today (Code only; Computer has no sidebar). Extraction is
  still justified by cohesion + emptying the densest method — but it
  lives in `Code::`, not `Shared::`, unless/until a second shell grows a
  sidebar.
- Does `TextPaneWindow` go to `Shared::` now (used by sidebar +
  `ConversationWindow`) — yes if we rebase `ConversationWindow` on it,
  otherwise it's a judgment call.
- `GitDiffPopup` opening: the popup is currently opened via
  `screen`-level `open_git_diff_popup`. Confirm the sidebar can own
  `#open_diff` cleanly (it holds the popup) without the App reaching
  into `@screen` for it.

## Fit / risk

Densest single-site hand-assembly; a genuine Tuile container component.
Lower cross-shell payoff than #1/#2 (Code-only) but the biggest cleanup
of one file. Do last of the three.

## Durable nuggets to propagate on completion

- Package-map lines: `lib/code/workspace_sidebar.rb` —
  `Code::WorkspaceSidebar`, framing tasks over git changes, owning the
  `GitWatcher` lifecycle + `GitDiffPopup`; and (if extracted)
  `lib/shared/text_pane_window.rb` — `Shared::TextPaneWindow`.
- Update the `Code::Layout` package-map line + its rdoc ASCII sketch if
  the sidebar absorbs the tasks/git split.
- Class rdoc: the `#start`/`#stop` lifecycle contract (poll thread
  started before the event loop, stopped after) and `UI-thread-confined`
  tags.
- If `TextPaneWindow` lands and `ConversationWindow` rebases on it, note
  the shared idiom.
