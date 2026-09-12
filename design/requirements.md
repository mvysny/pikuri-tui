# Requirements

What must hold — the promises the README's pitch makes, as official rules. One entry per
promise. A requirement *states*; it never argues: the fork behind it, if there is one, is a `D_`
entry it cites.

- **Owner-written.** An agent never adds, edits or retires an entry here; it proposes one — in
  conversation, or as a drafted entry in `design/ideas/<slug>.md` — and the owner moves it in.
- A requirement is a promise the README's pitch makes — what this project does differently, or
  better, than the alternatives. The owner's ruler for a proposal: **allow the opposite
  everywhere — is it still the pitched project?** "Nothing leaves the machine by default",
  "constant memory over any document" → not the same project → an entry. "Never peek ahead",
  "every subprocess goes through the chokepoint" → broken in places, same project → not an
  entry: an *invariant* — the rule that *keeps* a promise — is an `AGENTS.md` one-liner, named
  here under *Enforced by*; a rule true of one class is that class's rdoc.
- One file per pitch, at the root beside the README that makes it.
- Cite by slug — `R_<slug>`. `grep '^## R_' design/requirements.md` is the index.
- Shape: `## R_<slug> — <the promise in its operational form, one sentence>`, then **Status**,
  **If violated** (the observable failure), **Enforced by** (a test, a tripwire cited as `T_<slug>` —
  this line is that slug's home — or "review only"), **See** (the pitch passage and the `D_`s).
- A retired requirement stays as a tombstone. A requirement that wants a *Rejected:* section is a
  decision — move it to `decisions.md`.
- **The first entry is the ruler**: later entries are trimmed to its length, never the other way
  round.

---

## R_shell_only — Pikuri owns the agent loop, tool execution and LLM transport; this project owns nothing but the TUI shell

**Status:** Active.
**If violated.** A behaviour exists in two places and drifts: a tool-routing rule, a cancellation
path, a retry, a rescue that pikuri also implements — and these shells now answer differently from
pikuri's own `bin/` for the same input, with no way to tell which is current. The user sees it as
"the TUI does something the CLI doesn't", which is the one thing this project is not for.
**Enforced by.** `T_no_llm_sdk` keeps a second HTTP / LLM client out of `lib/` and `bin/`. Otherwise
review: the question for any new behaviour is whether it is about what the user *sees* and where
focus is — if it is not, it belongs back in pikuri as a listener event, a `Control`, or a tool.
**See.** README "Pikuri owns the agent loop…", `D_pikuri_owns_the_runtime`.

## R_human_gated_egress — In the coding and computer shells every outbound leg waits on a keystroke: a write, a `bash`, a research delegation, a mail or calendar hand-off

**Status:** Active. Scope is deliberate: the chat shell is the lean one, with `web_search` /
`web_scrape` / `fetch` as ordinary main tools, no confirmer and no filesystem — it makes no such
promise and is not a violation of this one.
**If violated.** A mail is sent, an event is written, a file changes or a research task reaches the
web without the user having answered for it — the promise the computer shell's pitch makes twice
("pikuri sends nothing itself"; web research "quarantined" behind a confirmed sub-agent hand-off).
A decision answered by a keystroke the user aimed at the prompt is the same violation.
**Enforced by.** {Code::TranscriptConfirmer} gates writes, `bash` and each `agent` research task,
and its keys are live only while the transcript holds focus; the web tools are registered
sub-agent-only, so the main agent holds no direct egress to gate; the Thunderbird hand-offs open in
Thunderbird's own UI for the user to Send. `--no-confirm` / `--yolo` are the documented opt-out.
Otherwise review.
**See.** README "Run the computer assistant", `D_transcript_confirmer`.
