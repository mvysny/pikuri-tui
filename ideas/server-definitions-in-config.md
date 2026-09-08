# `[[server]]` definitions in config.toml

Moved here from `../pikuri-web/ideas/`, where it was drafted: the schema is this shell's to author
(pikuri-web's `D_schema_complete_config` has the file authored in the family and the web shell
carrying all of it), so the change lands in `Shared::Config` first and pikuri-web ports it. The
web side's own residue — `--turns` retiring, its `ModelCatalog#servers`, its DECISIONS entries —
stays in `../pikuri-web/ideas/port-server-definitions.md`. Line references below are to *this*
repo's `lib/shared/config.rb`; pikuri-web's `config.rb` is a near-identical port.

Normalize the config file. Today every `[[llm]]` repeats its whole connection, so four Grok models
means the same URL and the same API key written four times:

```toml
[[llm]]
name = "Grok 4 Fast"
server = "https://api.x.ai/v1"
api_key = "xai-..."
model = "grok-4-fast"

[[llm]]
name = "Grok 4"
server = "https://api.x.ai/v1"   # again
api_key = "xai-..."              # again
model = "grok-4"
```

Split the physical resource out from the model running on it:

```toml
[[server]]
id = "grok"
url = "https://api.x.ai/v1"
api_key = "xai-..."
max_concurrent_requests = 4

[[llm]]
name = "Grok 4 Fast"
server = "grok"
model = "grok-4-fast"
context_window = 131072   # a *model* fact — stays on [[llm]]
```

**The split.** Server: `url`, `api_key`, `max_concurrent_requests`. LLM: `name` (displayed),
`model` (id), `context_window`, `server` (reference). `context_window` is per-model, not
per-server, and that is load-bearing below.

## `id`, not `name`

`[[code.mcp]]` already uses `id` for exactly this role — *"unique id the LLM uses to call
`mcp_connect`"* — while `name` throughout this schema means a human-facing label (`[[llm]] name`
is the model-picker string; `check_unique!(llms.map(&:name), 'llm name')`). So the file gets a
readable rule: **`id` is referenced by machine, `name` is shown to a person.** An `[[llm]]` then
carries both without ambiguity.

**The trap `id` opens: do not let it reach any per-conversation state.** pikuri-web's
`D_per_conversation_model` rejects storing a name because names are renameable, and `id` buys no
stability — it is still a user-editable TOML string. Worse, an id is only meaningful *relative to a
config file*, so `[model, "grok"]` on disk would orphan every conversation minted on a `[[server]]`
that later gets deleted, where a stored URL is self-contained. **Resolve to the URL inside
`Config`; the `id` never leaves it.**

## Keep `Llm`'s shape; resolve into it

The one design point the first draft left open. Recommendation: `Llm = Data.define(:name,
:server, :model, :api_key, :context_window)` stays exactly as it is, with `server` and `api_key`
arriving **already resolved** from the referenced `[[server]]` — `server` is the URL, never the
id. Then `Shared::Model::Choice.from_llm` (reads `llm.server`, `llm.api_key`), the three
`app.rb`s' `config.llms.map { Choice.from_llm }`, and pikuri-web's `ModelCatalog.from_llms` plus
its specs are all untouched. The new surface is one value object and one reader:

```ruby
Server = Data.define(:id, :url, :api_key, :max_concurrent_requests)
config.servers   # => [Server, …], declaration order
```

`max_concurrent_requests` is `Integer` (positive) or `nil` when omitted. `api_key` stays
optional on `[[server]]` (nil → `"not-needed"` at the bin, as today).

## This is what the throttle was looking for

`max_concurrent_requests` is the per-server throttle value that `[[llm]]` had no honest home
for (N models, one physical server, so the file could state two contradictory facts about one
resource and the schema could only answer with a reducer nobody can guess or an error on a DRY
violation it forced).

It composes with pikuri's auto-sizing without a precedence rule, because `ServerPermits`' own rdoc
already settles the order:

> `{.limit}` wins over any such default.

So: `max_concurrent_requests` → `ServerPermits.limit(url, n)`, the `/props` probe →
`ServerPermits.default`, and `.limit` wins **by decision rather than by ordering** — precisely
the fragility pikuri-web's `D_upstream_request_throttle` rejected `.default` over. A server with
the key set gets the operator's number; one without gets probe-sized from its own `total_slots`
(and nothing is called for it — omitted means "let the probe decide", and there is deliberately
no way to spell "explicitly unlimited"). Per-server, mixed, no timing dependency.

**`Q_tui_wires_permits` — decided: yes, and in all three shells.** This repo calls
`ServerPermits` nowhere today, so as written the key would be one this shell *carries* but does
not consume. It consumes it. The coding and computer shells run sub-agents and every
sub-agent's requests contend for the same box; the chat shell gets it too, because it is one
file for all three and a person with two shells open contends with themselves.

```ruby
config.servers.each do |s|
  Pikuri::Agent::ServerPermits.limit(s.url, s.max_concurrent_requests) if s.max_concurrent_requests
end
```

Two things that make this safe to write without thinking about ordering:

- **`.limit` wins by decision, not by timing** — `ServerPermits.store` marks an explicit size and
  refuses to let `.default` overwrite it, so this may run before or after the agent is built.
- **The key cannot drift from the connection.** `ServerPermits.key_for` strips a trailing `/` and
  `/v1` exactly as `ChatTransport.from_openai_server` normalizes a server, and after this change
  an `[[llm]]`'s `server` *is* the `[[server]] url` we hand `.limit`. A separate throttle-config
  key would have had two strings to keep in step; resolution leaves one.

An **unused** `[[server]]` still gets `.limit` called. Sizing a server nobody dials is a no-op,
which is cheaper than filtering `#servers` by what `#llms` references.

**`Q_where_permits_wired` — decided: a shared adapter, called from each `App`.** The two
alternatives, for the record: a line per *bin* (matches "host boot configures the process", but
the chat and computer bins touch no `Pikuri::*` transport today, so it would be the first Pikuri
wiring in `bin/pikuri-tui-chat`), or a line per *`App`* inline. What ruled both out is that this
does not stay one line — a `LOG.info` naming each sized server is worth having in the diagnostic
pane, because it is otherwise invisible *why* a turn is queueing. With that it is a small box
with a clear contract, which is what AGENTS.md's extract-the-building-block rule points at.

Called from each `App`, beside the `@models = config.llms.map { Choice.from_llm }` line that
already derives the other Pikuri-side fact from the same config. One consequence to plan for:
this mutates a process-global registry from an `App`, so App specs want a `ServerPermits.reset!`
`after` hook — pikuri's own `request_throttle_spec.rb` is the precedent.

**Name: `Shared::RequestPermits`, with a `.install(servers)` module function.** Not
`Shared::ServerPermits` (shadows pikuri's own name at every reference site) and not
`Shared::Model::Permits` (that namespace is documented as the model-switch subsystem, which this
is not). `Request` rather than `Server` also states the true unit: upstream's permit covers one
HTTP request, not one turn. The shape to copy is `Shared::FileCommands` — a stateless module with
one entry point that maps a pikuri-side surface onto this app's terms, no `Shared::` sub-namespace
of its own. `.install` matches `Shared::AppTheme.install`'s sense of "apply this to the process".

Not settled by the name: whether `.install` also *logs* the servers it skipped for want of a
key. Probably not, since an absent key is the common case and the log pane is for what went
wrong.

## Settled in review

**`Q_key_name` — the key is `max_concurrent_requests`.** The first draft's `max_requests` reads
as a *quota* ("cap how many requests I spend"), which is a plausibly-expected but entirely
different feature. What the key states is a concurrency ceiling. It is written once per server
and read forever, so the long precise name wins over the short ambiguous one. Also rejected:
`parallel` (mirrors the `llama-server` flag the operator typed, opaque on its own in a TOML
file) and `slots` (mirrors the probe field, leaks pikuri's vocabulary into this app's schema).
The rdoc should still name `--parallel` explicitly, because that *is* the number and saying so
saves the reader a guess.

**`Q_migration_errors` — do all three.** "A backtrace must not be the first-run experience" is
already the rule for an empty config, and the same argument covers an existing one: there is no
compat path, so the raise *is* the entire migration experience. Three shapes an old file has:

| old file says | unhelped | helped |
|---|---|---|
| `[[llm]] server = "http://localhost:8080"` | "unknown server id `http://localhost:8080`" | "`server` now names a `[[server]]` `id`, not a URL — add …" |
| `[[llm]] api_key = "sk-…"` | "unknown key(s): api_key" | "`api_key` moved to `[[server]]`" |
| `[[llm]]` but no `[[server]]` at all | "unknown server id" | the paste-ready block |

The first row earns real effort: a URL and an id are both strings, so the old value parses
cleanly and fails as a *lookup*, which reads like the user's fault rather than a moved key. An
`include?('://')` check on an unresolvable reference costs one line and turns it into an
instruction.

**`Q_server_context_window` — no, `[[server]]` carries no `context_window` default.** Four Grok
models on one server do repeat the same window four times, and that is the DRY argument this
whole idea is built on, so the rejection needs the stronger reason: a server-level default gives
`context_window` three sources (model table, server table, probe) and so needs a precedence rule
nobody can guess, and models on one provider genuinely differ — a 2M-window model can sit beside
a 131k one. The case that argues *for* it, a single-model llama-server whose launched `n_ctx`
really is a server fact, is exactly the case where the probe already answers and nobody types
anything.

**`Q_cross_process_scope` — the key is per process, and the docs must say so.** `ServerPermits`
is a process-wide registry, not a machine-wide one. Chat, code and computer open at once against
one local llama.cpp gives each of them the full allowance, so three shells put three times the
number in flight. What this key therefore promises is a ceiling on *one shell's* fan-out, which
is the case that actually bites: a coding turn spawning three sub-agents. The name stays
`max_concurrent_requests` without a per-process qualifier — the scope belongs in the rdoc and
the README, not in a key every reader has to type. llama.cpp queues rather than failing, so
overshooting costs latency plus the retry stampede pikuri's `D_llm_request_throttle` describes,
and none of that arrives labelled as this key's fault.

**`Q_example_config_home` — one frozen `EXAMPLE_CONFIG` in `Config`.** Quoted by the raise and
by the README, so the paste-ready block has a single home. The message also names the *exact
path* to write it to, which is `candidate_paths(env).last`, the `XDG_CONFIG_HOME` layer: a
copy-paste plus a filename beats a copy-paste plus a hunt.

**There is deliberately no way to spell "explicitly unlimited."** `ServerPermits.limit(url, nil)`
exists upstream, so the spelling is available — but a server the probe *can* size is a llama.cpp,
where unlimited is the wrong answer, and a server it cannot size is unlimited already. The key
would be a no-op everywhere it could be typed.

## Decided: no defaults, no compat, hard failure

A missing or unresolvable server is a config error. Raise `Config::Error`; every bin already
catches it at boot and exits rather than letting a backtrace escape. **A backtrace must not be the
first-run experience.**

`DEFAULT_MODEL` dies too, so `model` becomes required on `[[llm]]`, and so does `server`. An entry
naming a server but no model is no more meaningful than one naming neither, and `DEFAULT_MODEL =
'unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M'` is a hardcoded model tag — stale by construction, and a
*silent* fallback to it is exactly the second, invisible connection source the one-source rule
exists to forbid.

The zero-config path is not a UX consideration here (it does not produce a working session), but
the **code** for it is live and needs deleting: `Config.load` with no file still returns
`Llm(name: "Local Qwen 3.6", server: "http://localhost:8080", model: "unsloth/...")` and logs
*"config: no config file found; using built-in defaults"*.

Still worth doing even so: **raise with the file that would work** — a paste-ready `[[server]]` +
`[[llm]]` block for local llama.cpp, in the error text. Same knowledge, relocated from code the user
cannot see into a message they can edit. The magic fallback becomes documentation. The README's
quick start then starts with "write this file".

## Snags — the one that breaks silently comes first

**`holds_secret?` disarms.** `config.rb:357-359` looks for `api_key` inside `parsed['llm']`. Move
the key to `[[server]]` and that check keeps passing on a file full of plaintext keys — the
`chmod 600` advisory just stops firing, with nothing going red. Must move in the same commit. It
runs per file, pre-merge, so it is `parsed['server']` it must read.

**Two arrays that reference each other, under replace-wholesale layering.** Tables merge
key-by-key, arrays replace wholesale, nearest file wins. References must therefore resolve
*after* the full merge — which is how `load` is already shaped (merge every layer, then build) —
or a user file adding one `[[llm]]` would have to re-paste the entire `[[server]]` block, secrets
included — the duplication this whole idea removes. Consequence to state in the rdoc: a nearer file
replacing `[[server]]` can dangle a farther file's `[[llm]]`, and that **must raise, never fall
back**.

**Uniqueness is on `id` only.** `check_unique!` on `id`, same as `code.mcp id`. Decided *not* to
also check the URL: `Config` is Pikuri-free in pikuri-web and cannot call `ServerPermits.key_for`,
and a copy of the normalization rule is not worth the drift. Accepted consequence: two `[[server]]`
entries pointing at one URL with different `max_concurrent_requests` both call `.limit` on the same
normalized key and the later one wins, silently. An **unused** `[[server]]` stays legal — erroring
on it would make commenting out an `[[llm]]` break the file.

## What deletes

- `DEFAULT_LLM_NAME` / `DEFAULT_SERVER` / `DEFAULT_MODEL`
- `default_llm` (`config.rb:604`) and its `private_class_method` entry
- the `empty? ? [default_llm] :` branch (`config.rb:260`)
- the `|| DEFAULT_SERVER` / `|| DEFAULT_MODEL` fallbacks (`config.rb:473-474`)
- the specs asserting the defaults directly; they invert into "no file raises" and "an `[[llm]]`
  with no `server` / no `model` / a dangling `server` raises"
- the README's config example and the "no file needed" claim, if any survives

## `Q_upstream_probe_skip` — closed; fixed upstream as `D_probe_when_unknown`

Filed in `../pikuri/ideas/`, implemented and graduated the same day, so that idea file is gone
and the decision entry is the reference. The `Gemfile` points every `pikuri-*` gem at
`../pikuri/<gem>` so this repo consumes it directly; the rest of master's post-0.1.0 API has
been absorbed too, so the suite is green on the path dep and stays that way until pikuri cuts
0.2.0 (see the `Gemfile` comment — that cut is what un-blocks CI).

**What shipped, and why it matters to this schema.** The skip is now keyed on what is still
*unknown* rather than on the cap: the probe runs unless the transport states a `context_window`
**and** `ServerPermits.sized?(base)` says the server's concurrency is already on record. The
registry is thereby the probe's own memo — a probe that answered is recorded even when it
reported no slots, and a probe that failed records nothing.

Three consequences here, one of them a genuine reward for the schema:

- **A `[[server]]` stating `max_concurrent_requests` alongside a `[[llm]]` stating
  `context_window` costs zero network at boot.** Both facts are on record, so nothing is probed.
  That is the shape this file recommends, and it is now also the cheapest one.
- **A `[[llm]]` with a `context_window` and no `max_concurrent_requests` gets probe-sized**
  instead of running unthrottled. That was the bug.
- **Against a cloud endpoint, that same combination costs one 404 per process.** Setting
  `max_concurrent_requests` removes it. Worth a sentence in the README next to the key, since it
  is the one case where the schema's optional key buys something invisible.

Note for whoever is holding that upstream branch: `D_probe_when_unknown` cites the downstream key
as `max_requests`, which this file has since renamed to `max_concurrent_requests` in two places.

The original note, kept for the argument it makes:

`pikuri-core/lib/pikuri/agent.rb`, `detect_and_emit_context_cap!`: one `/props` probe reports two
independent facts, and `context_window` overrides exactly one of them — yet it suppresses both.

```ruby
props = if @transport.context_window
          ContextWindowDetector::Props::NONE      # <- kills total_slots too
        else
          ContextWindowDetector.detect(@transport, openai_base: base)
        end
```

That conflation is the entire reason pikuri-web's `D_upstream_request_throttle` argues for sizing
explicitly ("an entry that opts out of the probe must not silently opt out of the throttle").
Probe for slots regardless of `context_window` and every server gets sized from its own truth,
which beats any typed number.

**This schema change makes the wart visible rather than fixing it**: afterwards a key in the
*model* table suppresses a probe that seeds the *server* table, which reads as obviously wrong.
Cost of the upstream fix, honestly: an explicit `context_window` currently also buys *no boot-time
network call*, so a remote paid API would start eating one pointless request per boot (`detect`
tolerates the 404 and returns `NONE`, so it is cost, not breakage) — which the memo reduces to
one per *process*, and only for an openai-provider transport.

## On graduation (this repo)

- The fork (normalize the schema; no defaults; hard raise; `id`-only uniqueness) → this repo's
  decision log, per its AGENTS.md map.
- The layering rule (resolve after merge; dangling raises) → `Config`'s class rdoc, next to the
  existing **Precedence** section.
- The new `[[server]]` block and the required keys → `README.md`, whose quick start now starts
  with "write this file"; plus the per-process honesty note from `Q_cross_process_scope` wherever
  it explains `max_concurrent_requests`.
- The permits wiring → a **Layout** line for `Shared::RequestPermits`,
  and its "`.limit` wins by decision, not ordering" contract into that class's rdoc (it is the one
  fact a future reader would otherwise re-derive from pikuri's source). Its per-process scope
  belongs there too, next to that contract.
- The three `Q_migration_errors` messages are self-documenting once written; nothing to backport
  beyond a spec each, so that they cannot silently regress into a bare "unknown server id".
- Then pikuri-web ports it: `../pikuri-web/ideas/port-server-definitions.md` — already updated to
  the settled key name, since a port file spelling the old one is a trap.
