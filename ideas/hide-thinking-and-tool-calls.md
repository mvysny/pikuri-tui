# Transcript density: hide thinking, shorten tool lines

**Status:** designed, not started. The leans from the brainstorm are folded
in below as `D_` decisions (the alternatives are kept one line each, for the
why-not notes at graduation). Scratch file — delete once implemented
(propagate per AGENTS.md "Ideas live in `ideas/*.md`, then evaporate").

Two changes, independent of each other:

1. **Thinking becomes toggleable** (show / hide), with a config default.
2. **Tool lines get a short form and stay visible.** Not a toggle. v1 is
   tui-only from what the events carry today; v2 consumes the summaries
   pikuri will compose (`../pikuri/ideas/tool-summary-lines.md`).

Never hidden, never shortened: user echoes, assistant prose, `⊕`
injections, `!` notices, cancel markers, the `Code::TranscriptConfirmer`
decision block (a parked decision blocks the turn; it must stay loud), and
**the `edit` / `write` diff blocks** — a diff is the one tool output the user
reviews rather than skims (`D_diffs_always_visible`).

---

## Part 1 — the thinking toggle

### Decisions

`D_config_default` — a `[ui]` table in `Shared::Config`
(`show_thinking = true`), layered like everything else, flowing into the pane
as a constructor flag exactly as `markdown:` does today. The runtime toggle
is a *session override* of the configured default and is never written back:
the file-sets-default / runtime-overrides shape `sandbox` / `confirm` already
have. The toggle's echo names the key so the user can make it stick:
`Thinking hidden for this session — set ui.show_thinking = false in
config.toml to keep it.`
- Rejected `O_session_only`: transcript density is taste, not a response to
  terminal width like the sidebar mode; re-typing it every boot would grate.
- Rejected `O_state_file` (a rewrite-in-place prefs file under
  `Pikuri::Paths.state`): would be the first rewritten preference store and
  grows into a settings system. Can replace `D_config_default` later without
  touching the pane, which only sees a boolean.

`D_one_ui_table` — one `[ui]` table for all three shells, no `[chat.ui]` /
`[code.ui]`; the preference is per-person far more than per-shell.

`D_markdown_flag_deferred` — the pane's `markdown:` flag is the same shape
and has no config key; it is the natural second `[ui]` key but out of scope.
Say so in the `[ui]` rdoc so the next person puts it there.

`D_leader_t_and_slash_thinking` — leader `t` ("thinking") plus
`/thinking [on|off]` (blank toggles, the `/sidebar` shape). `t` is free in
all three shells (taken: `l d s p m c q`). The leader label is a static
`String` and cannot show state; the toggle's echo does, and hidden thinking
is not an invisible state the way hidden tool calls would have been — the
spinner still says the agent is busy and only grey prose is missing.
- Deferred `O_which_key_submenu` (leader `u` → a second `PickerWindow` with
  live-state labels, lazyvim's `<leader>u`): right shape once a second
  display preference exists (`markdown`, a tool-verbose flag), silly for one.
- Rejected `O_checkbox_dialog`: same information in a widget the app does
  not otherwise use.

`D_no_hidden_marker` — no `· thought` line where thinking was. The reasoning
is grey filler by design; nothing about its absence confuses. Revisit only
on a real "the model isn't thinking any more" report.

`D_kinded_regions` — the pane keeps, per block it creates,
`{region, kind, render}` where `render` is a zero-arg thunk producing the
block's text (closing over event content, indent, renderer — so a reveal
renders at the *current* width and theme). `add_block(..., kind:)`: kind
visible → `region.text = render.call` now; kind hidden → create the region,
keep the entry, leave it empty (zero rows, position held — Tuile's
`Region` rdoc: `region.text = ""` "collapses a region's visible footprint
without detaching it"). Toggle = walk the entries of that kind,
`region.text = hidden ? '' : render.call`. The decision region is untouched,
visible blocks aren't re-rendered, no `clear`, no replay. Scrolling is safe:
tuile 0.15's `set_region_text` clamps `scroll_top_row` to the new max and
runs `update_scroll_top_row_if_auto_scroll` (`text_view.rb` L491–506), so a
following view stays tailed through a bulk collapse and a scrolled-up view
is pulled back into range.
- Rejected `O_listener_filter` as the whole answer: only affects future
  blocks; "that answer looks wrong, show me its reasoning" is the case that
  matters. Kept for the delta stream while hidden (below).
- Rejected `O_tuile_hidden_region` (`Region#hidden=` upstream): invasive in
  the `@rows` ↔ hard-line mapping, and Tuile already has the collapse
  primitive. Don't ask.
- Rejected `O_replay` (record events, `clear`, re-dispatch through a
  filter): `clear` drops the pending decision region — a parked confirmer
  question plus a toggle would erase the question while the worker stays
  blocked on the answer. Also clobbers open streamed blocks mid-turn, loses a
  cancel's preserved partial, resets scroll. **This trap goes in the pane
  rdoc next to `pending_decision=` at graduation.**

`D_drop_deltas_while_hidden` — streaming while hidden renders nothing
anywhere: the listener drops `ThinkingDelta` outright and lets the
`Thinking` bookend land as a hidden block (pikuri's bookend carries the full
text — the listener already relies on that to replace a truncated preview).
Cost: a cancel mid-thinking while hidden has no bookend, so that reasoning is
not revealable later. Accepted. Flipping to hidden mid-stream: `wipe` the
open thinking block and route the rest silently.

`D_pane_owns_flag` — sub-agent listeners are minted per delegate and share
the pane, so the pane (not the listener) owns the flag; a flag on the
listener would be copied at mint time and go stale. Sub-agent thinking is
thinking: same kind, same flag.

The pane's "stateless" rdoc claim narrows to *conversation progress*
(open-stream cursors stay in the listener); a per-region kind register is
display state, the pane's job. Memory: one closure + the thinking text per
block for the life of the conversation (`clear` / `Reset` drop them).

### Specs

The pane is unit-testable from canned events under a fake screen: dispatch a
scripted stream with the flag each way, toggle, assert `text` lines. Plus one
confirmer spec that parks a decision, toggles, and answers `y` — the guard
for the `O_replay` trap.

---

## Part 2 — short-form tool lines

### The target look (v2, once pikuri composes summaries)

```
  Write(lib/shared/config.rb)
    Added 2 lines, removed 3 lines
  WebSearch(rails 8 credentials)
    Returned 23 search results
  Edit(lib/code/app.rb)
    ✎ edit  lib/code/app.rb          ← the diff block, unchanged
    ┃ -foo
    ┃ +bar
```

`D_tool_composes_summary` — the summary is composed by the tool in pikuri,
in code, and only echoes structure (counts, sizes, exit codes), never an
excerpt and never a model-written sentence. Rationale and mechanism live in
`../pikuri/ideas/tool-summary-lines.md`; this note only consumes the result.
- Rejected `O_llm_composes`: the model is the one component an attacker can
  steer; a narrated `Saved successfully` on a failed write is the injection's
  goal.
- Rejected `O_ui_formatter` as the *permanent* answer: the summary derives
  from structured data the tool had and the renderer never sees; a UI table
  re-parses flattened strings and drifts across three renderers. It is fine
  as the throwaway v1 below.

### v1 — tui-only, from today's events

Ship the *look* now with what `Event::ToolCall(name:, arguments:)` and
`Event::ToolResult(content:)` already carry:

```
  WebSearch(rails 8 credentials)
    OK
  Bash(rm -rf build)
    Error: exit 1: rm: cannot remove 'build': Permission denied
```

- **Call line:** CamelCased display name + `(` first argument value `)`.
  `D_v1_camelcase`: the CamelCase transform is one line, done now so v1
  already looks final and v2 changes no pixels when the event carries
  `display_name`; treat any run of non-alphanumerics in the name as a word
  break (MCP names). The argument is the first *value* of the `arguments`
  hash — the model emits keys in schema order in practice, and the first
  schema parameter *is* the primary one for every shipped tool (`path`,
  `query`, `command`, `name`). Good enough for a throwaway; pikuri's
  first-required-parameter replaces it in v2. A no-arg tool renders as
  `EnterPlanMode` with no parentheses; a non-`String` value (an array, a
  number) renders via `to_s`.
- **Result line:** `OK, 1.2 kB` when the content does not start with
  `Error:`, else the content's first line. `D_v1_ok_with_size`: the size is
  the one structural fact today's `(N bytes total)` suffix carried, and it is
  what tells a `read` that returned nothing apart from one that didn't; zero
  cost. Prefix detection is a heuristic (a `read` of a file whose first line
  is `Error: …` would misreport) — accepted for v1, and exactly what v2's real
  summary fixes. Tools don't *raise* into the listener: pikuri's `Tool#run`
  returns recoverable failures as `"Error: …"` strings, and a genuine raise
  aborts the turn and lands as a `render_turn_error` line, not a
  `ToolResult`. So "OK or raised" is "OK or the `Error:` line". Tone: the
  `OK` line dim (`theme.detail`, the tone the formatters already use for a
  quiet success); the call line and the `Error:` line in `theme.tool`, matching
  `Code::DiffToolFormatting#render_result`.
- **Sanitize.** The current `→ name(k=v)` line is safe only because every
  value passes through `inspect`, which escapes control bytes. The short form
  drops `inspect`, so both lines go through `Pikuri::Sanitizer.sanitize(…).text`
  (pikuri-core, already loaded in all three shells) before `StyledString.parse`
  sees them — a filename carrying `ESC[` must not recolor the transcript.
  Not deferrable to v2.
- **Cap.** The argument to one line, ~60 columns, `…`; a `command` can be a
  4 kB script. The result line to one line as well.
- **Formatters.** `Code::EditFormatter` / `Code::WriteFormatter` keep the
  diff block. Their header is `✎ edit  path` today; align it with the short
  form (`Edit(path)`, then the diff body) so the two shapes don't sit side
  by side. Their `render_result` already returns `nil` on success and the
  error text on failure — which is v1's rule already.
- **Where.** `Listener#render_tool_call` / `#render_tool_result` default
  branches; ~20 lines. The `Assistant` / decision / thinking paths are
  untouched. Not a toggle, so no kind register involvement — plain
  `add_block`.

#### v1 handoff checklist

Scope is *only* the two default branches, the formatter header, and what
pins them. Nothing from Part 1, no config key, no leader/slash change.

Code:
- `lib/shared/conversation_text_view.rb` — `Listener#render_tool_call`
  (L586–597) and `#render_tool_result` (L606–615) default branches. The
  helpers (CamelCase, first argument, size formatting, the `Error:` check)
  are private on the pane or the listener — no new file; they are v2's
  deletions. Sanitize with `Pikuri::Sanitizer.sanitize(str).text` (a
  `Pikuri::Sanitizer::Result`; its `warnings` are ignored here — the confirm
  block already surfaces them for gated tools). Sanitize *then* cap, so an
  escaped `\x1b` can't be cut mid-token.
- `truncate_tool_result` / `MAX_TOOL_RESULT_CHARS` (L66–70, L223–236) lose
  their only caller; delete them and their rdoc (the pane header's
  "mirrors the terminal listener's cap" sentence goes with them). If the
  `Error:` line needs a cap, a fresh one-line constant, not this one.
- `lib/code/diff_tool_formatting.rb` `#render_call` (L36–39) — header
  `✎ edit  path` → `✎ Edit(path)`. **Keep `GLYPH`:** `✎` is the mutation
  family mark, shared with `Code::GitDiffRenderer`'s `✎ path` file headers
  (pinned in `spec/code/git_diff_renderer_spec.rb`) and the prompt's capture
  marker; only the verb part takes the short form. Its rdoc L24–29 follows.
- `lib/code/edit_formatter.rb` L8–9 and `lib/code/write_formatter.rb` L9 —
  rdoc says "instead of the default `→ edit(path=…)` dump"; re-word to the
  new default.

Specs (the lines that pin the old shape — every one changes, none is
deleted):
- `spec/shared/conversation_text_view_spec.rb` L127 (`= 42`), L139 (`5000
  bytes total` → the `OK, 4.9 kB`-style size), L479 + L512 (`→ edit` absent /
  present — the assertion is "default line vs formatter block", re-point at
  `Edit(`), L497 (`= ` absent), L520 + L530 (`= whatever` / `= match` → `OK`
  or the `Error:` line), L529 (`→ grep` → `Grep(`), L554–573 (the sub-agent
  indent tests hand-build a `→ web_search` block — they test the *indent*, so
  either keep the literal or switch to `WebSearch(`), L589 (`= 42`).
- Add: an `Error: …` observation renders its first line and not `OK`; a
  value carrying `\e[31m` renders escaped, not colored; a 4 kB `command` is
  cut to one line with `…`; a no-arg call has no parentheses.
- `spec/code/edit_formatter_spec.rb` / `write_formatter_spec.rb` don't pin
  the header text today; add one assertion each for `✎ Edit(` / `✎ Write(`.

Docs:
- AGENTS.md L161 ("tool-call lines, tool observations") is still true; the
  `Shared::ConversationTextView` Layout entry should say the tool lines are
  the short `Name(arg)` / `OK, size` form, composed here as a v1 stand-in for
  pikuri's summaries (pointer to `../pikuri/ideas/tool-summary-lines.md`
  while it lives, to the pikuri decision once it graduates).
- `Shared::ConversationTextView` class rdoc L6–9 lists what it renders —
  "tool calls, tool observations" stands; the `tool_formatters` `@param`
  (L88–91) names the default it replaces — update.

Run `bundle exec rake check`.

### v2 — consume pikuri's summaries

When `ToolCall` carries `display_name:` / `argument:` and `ToolResult`
carries `summary:` (+ `name:`), the listener prints those and deletes v1's
CamelCase helper, first-value pick and `Error:` prefix check. The diff
formatters drop the redundant summary under a diff (renderer's call, per the
pikuri note). Nothing else moves; the v1 look was chosen so v2 changes no
pixels except the result line's wording.

`D_no_verbose_toggle_yet` — the current `→ name(k=v)` / `= <200 chars>` form
is a debugging view, and with `D_kinded_regions` a `tools: short | verbose`
flag would be nearly free (the render thunk picks the form). Don't build it
until a real debugging session misses the raw view; then it is also what
unlocks the deferred `u` submenu. The diagnostic log is *not* the place for
the raw form — never cross the streams.

---

## Sequencing

1. Part 2 v1 (smallest, most visible, no config).
2. Part 1 (`[ui]` config key, kinded regions, leader `t`, `/thinking`).
3. Part 2 v2 when pikuri ships `tool-summary-lines`.

## Open questions

- Argument cap width and `…` style — implementer's call; ~60 columns is
  the starting point.

## When this is done

Delete this file. Durable nuggets to propagate first:

- AGENTS.md Layout: `Shared::ConversationTextView` gains the kinds/collapse
  contract and `show_thinking=`; `Shared::Config` gains `[ui]` (with the
  `markdown` pointer); each `App` gains leader `t` + `/thinking`.
- AGENTS.md Scope decisions, one line each: the decision block and
  user/assistant prose are never hidden (a parked decision must stay loud);
  tool lines are short by design with the diff blocks the deliberate
  exception; the short form is composed by the tool in pikuri, never by the
  model, and is structural, never an excerpt.
- `Shared::ConversationTextView` rdoc: the "stateless" claim narrows to
  conversation progress; and the why-not next to `pending_decision=`: a
  `clear`-based re-render would silently erase a parked question.
- The `[ui]` rdoc: why session-only and a state file were passed over.
