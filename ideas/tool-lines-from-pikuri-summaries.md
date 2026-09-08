# Tool lines v2: consume pikuri's composed summaries

**Status:** **buildable now — the wait is over.** pikuri master ships both
events (`D_tool_summary_lines`, 2026-09-07), and the `Gemfile` points at
`../pikuri/<gem>`, so the fields below are live in this checkout. Do it as part
of [`catch-up-with-pikuri-master.md`](catch-up-with-pikuri-master.md), which is
the whole migration; this file stays the *design* half (what deletes, and the
decision not to lose).

Everything else in this note has landed and
been graduated — the thinking toggle, the short tool lines, the `[ui]` config
table and the leader-`u` submenu are in the code, their durable nuggets are in
AGENTS.md and the class rdocs, and pikuri-web has taken its own copy of the
design.

The exact shapes that shipped:

```ruby
ToolCall   = Data.define(:tool_call_id, :name, :arguments, :display_name, :argument)
ToolResult = Data.define(:tool_call_id, :name, :content, :summary)
```

Two notes from reading the upstream rdoc, neither of which the sketch below
anticipated: an `argument` of `""` renders the call **bare** (`EnterPlanMode`,
not `EnterPlanMode()`), and `tool_call_id` pairs a result with its call by key,
so the listener needs no call→result ordering assumption. Defanging every
string through `Pikuri::Sanitizer` stays this side's job — upstream is explicit
that a chrome "styles, caps and defangs" what it is handed.

## What v1 built, and what v2 deletes

`Shared::ConversationTextView::Listener` composes the short form itself, from
what today's events happen to carry:

```
  WebSearch(rails 8 credentials)
    OK, 4.1 kB
  Bash(rm -rf build)
    Error: exit 1: rm: cannot remove 'build': Permission denied
```

- the CamelCase transform on `ToolCall#name` (`#display_name`),
- the "first value of the `arguments` hash is the primary parameter" guess
  (`#display_argument`),
- the `Error:`-prefix check that decides OK-vs-failed (`#short_result_line`),
- the byte size standing in for a real summary (`#format_size`).

All four are stand-ins with known holes: the argument pick relies on models
emitting keys in schema order, and a `read` of a file whose first line starts
`Error:` misreports as a failure.

## The step

When `ToolCall` carries `display_name:` / `argument:` and `ToolResult` carries
`summary:` (+ `name:`), the listener prints those and the four helpers above
are deleted. The diff formatters drop the now-redundant summary under a diff
(the renderer's call, per the pikuri note). Nothing else moves — the v1 look
was chosen so that v2 changes no pixels except the result line's wording:

```
  Write(lib/shared/config.rb)
    Added 2 lines, removed 3 lines
  WebSearch(rails 8 credentials)
    Returned 23 search results
```

The `:verbose` form is untouched by any of this: it renders the raw event and
has nothing to consume.

## The one decision v2 must not lose

The summary is composed **by the tool, in pikuri,
in code**, and only ever echoes structure (counts, sizes, exit codes). Never
an excerpt, and never a model-written sentence. Rationale and mechanism have
since graduated upstream into `../pikuri/DECISIONS.md` `D_tool_summary_lines`
(plus `D_tool_always_returns_result` for the one-return-type half) — the
`../pikuri/ideas/tool-summary-lines.md` this used to cite is deleted, and the
slug this note called `D_tool_composes_summary` never existed under that name.
This note only consumes the result.

- Rejected `O_llm_composes`: the model is the one component an attacker can
  steer, and a narrated `Saved successfully` over a failed write is precisely
  the injection's goal.
- Rejected `O_ui_formatter` as the *permanent* answer: the summary derives
  from structured data the tool had and the renderer never sees, so a UI-side
  table re-parses flattened strings and drifts across three renderers. Fine as
  the throwaway v1 above; not fine as the destination.

(The first half of this pair is already in AGENTS.md's Scope decisions, so it
survives this file. The rejected alternatives are what would be lost.)

## When this is done

Delete this file. Nothing here needs backporting except a one-line check that
AGENTS.md's tool-line bullet no longer calls the short form "a tui-side
stand-in".
