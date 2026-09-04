# Sidebar: a width cycle (full / narrow / hidden)

Motivation (mavi): give the conversation pane more width. The sidebar at
`SIDEBAR_FRACTION = 0.4` eats ~48 cols of a 120-col terminal.

The prerequisite half — making both sidebar panes render one row per item,
ellipsized to their own width — is **done**; see `Code::TaskListPane` /
`Code::GitSummaryPane` rdoc and the AGENTS.md package map. Their renders are
already width-aware, so a narrower column needs no new render mode.

## The shape

- One leader key (`s` — `l d p m c q` are taken) cycling **full → narrow →
  hidden**, plus `/sidebar [full|narrow|off]` (`SlashCommand` callbacks already
  take the rest of the line).
- **`narrow` = a fixed ~24 cols**, i.e. today's `MIN_SIDEBAR_WIDTH`, the width
  `Code::Layout` already treats as its readability floor. Both panes were
  designed and mocked at exactly 24.

## Rejected: a 10–15 col strip

- Density falls faster than width: a name row plus a counts row halves the file
  count visible, and basenames at 10 cols are ambiguous exactly where this tree
  is dense (`lib/code/app.rb` / `lib/chat/app.rb` / `lib/computer/app.rb`).
- `1/10`-style task text is a status readout, not a pane.
- Width arithmetic on 120 cols (conversation columns):
  `full 71 · narrow 95 · strip-10 109 · hidden 120`. The strip buys 14 columns
  over narrow and gives up 11 to hidden, for a whole second render mode.

If an ambient digest is wanted *while hidden*, `Shared::StatusRuleLabel` is its
home (`3 files ±42`, `tasks 2/10`), dropping out when empty like every other
segment there. Not needed while the sidebar is visible — the captions carry it.

## Open questions

- **Persistence.** Session-only, or a `Shared::Config` key
  (`sidebar = "full" | "narrow" | "hidden"`)? Default stays `full` either way.
- **Interaction with the existing auto-collapse.** `Code::Layout#sidebar_width`
  already collapses below `MIN_SIDEBAR_WIDTH` / when the conversation would
  starve. Explicit `narrow` should be a fixed width rather than a fraction, but
  must still honor the `MIN_CONVERSATION_WIDTH` starve check.
- **`TASK_HEIGHT` under `narrow`.** 6 fixed rows is probably still right now
  that items are one row each, but worth a look.
- **Does `hidden` stop the `GitWatcher` poll?** Lean no: the diff popup is
  on-demand and would otherwise open on a stale diff, and a rule digest would
  want the data anyway.
