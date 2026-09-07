# Transcript density: hide thinking, shorten tool lines

**Status:** Part 2 v1 **landed in pikuri-tui** (see "Part 2 v1 — as built"
below); Part 1 and Part 2 v2 still designed-not-started. Held back from
graduation deliberately: **pikuri-web will reuse this file** for the same two
changes on its own chrome, so it stays here past the pikuri-tui landing
instead of evaporating into AGENTS.md. The durable pikuri-tui nuggets from v1
*have* been propagated (AGENTS.md Scope decisions + the
`Shared::ConversationTextView` Layout entry + the class rdoc); what remains
here is the design record and the not-yet-built parts.

The leans from the brainstorm are folded in below as `D_` decisions (the
alternatives are kept one line each, for the why-not notes at graduation).

Two changes, independent of each other:

1. **Thinking becomes toggleable** (show / hide), with a config default.
2. **Tool lines get a short form, with the raw form one key away.** v1 is
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

`D_kinded_regions` — **built, and already in use.** Part 2 v1 needed exactly
this for its tool-line toggle, so it was pulled forward: pikuri-tui's
`Shared::ConversationTextView` now has `#add_kinded_block(kind:, indent:,
&render)` + `#rerender(kind:)` over a `{region, kind, indent, render}`
register, dropped by `#clear`. Part 1 adds a second kind (`:thinking`) and the
hidden-means-empty-text branch; the register itself is done. The design as
written:

The pane keeps, per block it creates,
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
  branches. The `Assistant` / decision / thinking paths are untouched.

#### Part 2 v1 — as built (pikuri-tui)

Landed as designed above, plus the toggle (`D_verbose_toggle`). The five
things a second implementation (pikuri-web) wants to copy:

1. **Both renderers, one register.** `Listener` carries
   `#short_call_line` / `#short_result_line` and `#verbose_call_line` /
   `#verbose_result_line`; the pane carries `TOOL_DETAIL_MODES`
   (`%i[short verbose]`), `#tool_detail=` / `#toggle_tool_detail` /
   `#select_tool_detail(argument)`, and the `D_kinded_regions` register. Each
   default-branch block goes in as `add_kinded_block(kind: :tool) { short? ?
   … : … }`, so the flip redraws what is already on screen.
2. **`#select_tool_detail` returns the echo string** ("Tool lines: verbose.",
   or the "No tool-line form …" complaint). It lives on the pane rather than
   in each `App` because all three shells need it — a triplicated
   argument-parser is exactly the smell AGENTS.md's dedup rule names.
3. **Formatter blocks are not kinded**, so `D_diffs_always_visible` holds by
   construction rather than by a special case in the toggle.
4. **The result line indents `TOOL_RESULT_INDENT` (2) under its call line, in
   both forms.** Mode-independent, so the indent stays the pane's business
   (`add_kinded_block(indent:)`) and never enters the thunk.
5. **Sanitizing is per-path.** Short lines and the verbose *observation* go
   through `Pikuri::Sanitizer.sanitize(str).text` (then flatten, then cap —
   in that order, so a cut can't land inside an escaped `\x1b`); the verbose
   *arguments* are safe on `inspect` alone. Warnings are ignored here — the
   confirm block already surfaces them for gated tools.

Small deviations from the sketch above, all deliberate:
- `MAX_TOOL_RESULT_CHARS` / `truncate_tool_result` were **kept**, moved from
  the pane to the `Listener` (the verbose renderer is their caller now), and
  now route through the sanitizer. `TOOL_ERROR_MAX_CHARS` is the fresh
  constant for the short form's `Error:` line.
- Sizes are SI (`5000` → `5.0 kB`), not the `4.9 kB` in the sketch: calling
  1024 bytes a kB is the common-but-wrong thing.
- `✎ edit  path` → `✎ Edit(path)` with `GLYPH` kept, as specified; the
  formatters now pass `verb: 'Edit'` / `'Write'` / `'Create'` capitalized
  rather than the module capitalizing them.
- The verbose call line sanitizes `name` too — pre-existing hole, one word to
  close.
- Surfaces: leader `v` ("tool line detail") + `/tools [short|verbose]` (blank
  toggles, the `/sidebar` shape) in all three shells. `t` stays reserved for
  Part 1's thinking toggle.

Docs propagated: AGENTS.md Scope decisions (a new bullet: what the toggle must
keep true) + the `Shared::ConversationTextView` Layout entry + the leader/slash
roster line; the pane's class rdoc gained a `== Tool-line form` section and the
`Listener`'s variant list a fourth departure; `Shared::AppTheme`'s `:tool`
token rdoc re-worded off the old `→ call` / `= result` shape.

### v2 — consume pikuri's summaries

When `ToolCall` carries `display_name:` / `argument:` and `ToolResult`
carries `summary:` (+ `name:`), the listener prints those and deletes v1's
CamelCase helper, first-value pick and `Error:` prefix check. The diff
formatters drop the redundant summary under a diff (renderer's call, per the
pikuri note). Nothing else moves; the v1 look was chosen so v2 changes no
pixels except the result line's wording.

`D_verbose_toggle` — **reversed, and built in v1.** The original lean was
`D_no_verbose_toggle_yet`: don't build a `tools: short | verbose` flag until a
real debugging session misses the raw view. Overruled on the way in — the raw
form must stay *reachable*, not just present in git history, so both renderers
live side by side and a runtime toggle picks which one is drawn. That made
`D_kinded_regions` a v1 dependency rather than a Part 1 one (above), and it
is what would unlock the deferred `u` submenu once a second display preference
exists. Unchanged from the original note: the diagnostic log is *not* the place
for the raw form — never cross the streams.

---

## Sequencing

1. ~~Part 2 v1~~ — **done in pikuri-tui** (kinded regions came with it).
2. Part 1 (`[ui]` config key, the `:thinking` kind, leader `t`, `/thinking`).
3. Part 2 v2 when pikuri ships `tool-summary-lines`.
4. Both parts again in pikuri-web, on its own chrome.

## Open questions

- ~~Argument cap width and `…` style~~ — settled at 60 columns +
  `…` (`Listener::TOOL_ARGUMENT_MAX_CHARS`).
- Does pikuri-web want the same two-mode toggle, or does a web chrome make
  the raw form a disclosure triangle per call instead? The pikuri-tui shape
  is one mode for the whole transcript because a TUI has no cheap
  per-block affordance.

## When this is done

Delete this file — but **not until pikuri-web has taken its copy of the
design**. Durable nuggets to propagate first:

- AGENTS.md Layout: `Shared::ConversationTextView` gains `show_thinking=` and
  a second `add_kinded_block` kind; `Shared::Config` gains `[ui]` (with the
  `markdown` pointer); each `App` gains leader `t` + `/thinking`. (The
  tool-line half of this is already propagated.)
- AGENTS.md Scope decisions: the decision block and user/assistant prose are
  never hidden (a parked decision must stay loud). (The tool-line bullet is
  already there.)
- `Shared::ConversationTextView` rdoc: the "stateless" claim narrows to
  conversation progress; and the why-not next to `pending_decision=`: a
  `clear`-based re-render would silently erase a parked question.
- The `[ui]` rdoc: why session-only and a state file were passed over.
