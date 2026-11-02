# `Shared::Config` on Typemap, typed through sord's RBS

`Shared::Config` checks the TOML by hand: ~340 lines of code (plus ~420 of comments), most of
them `is_a?` checks and unknown-key lists. [Typemap](https://github.com/mvysny/typemap) maps a
Hash onto our own `Data` classes and does exactly that checking. Its `RBSTypes` reads property
types from `sig/*.rbs`, which the `ruby` skill already wants generated from the YARD tags by
sord, so each type is written once, in the doc comment.

## The rounds, in order

1. **Done: the `ruby` skill's setup, minus rubocop.** Add sord, yard, redcarpet (development group) and
   simplecov (test group); `.yardopts` (`--markup markdown`, `lib/**/*.rb`, so YARD ≥ 0.9.45
   does not read `sig/` back in); `tasks/sig.rake` with the app variant that lets through a
   `[WARN]` only for a name Ruby resolves after eager-loading (`Tuile::*`, `Pikuri::*`);
   `sig` in `rake check`; `git diff --exit-code sig/` in `.woodpecker.yml`; simplecov at the top
   of `spec_helper`, plus `config.expect_with :minitest`. `sig:validate` probably cannot run
   here: tuile and pikuri ship no `sig/`, and `rbs collection install` downloads, so ask first.
2. **Rubocop, as its own round.** The repo has never run it; expect a big first diff, likely
   including the column-aligned `key:   value` style in `config.rb`.
3. **Done: fix the YARD gaps sord reports across `lib/`.** Done before round 2, since the gate needed
   it; `Shared::Config`'s private helpers got typed too, so the gate wasn't left waiting on
   Typemap, even though round 5 deletes most of them.
4. **Typemap gains `Object`** (`../typemap/design/ideas/object-values.md`). That one is a blocker.
5. **`Shared::Config` moves onto Typemap**, then the YARD left in `config.rb` gets fixed.

## What Typemap takes over

`validate_top!`, `validate_ui!`, `validate_code!`, `build_search`, `build_server`,
`build_mcp_env`, every type and unknown-key check in `build_llm` / `build_mcp` /
`build_basic_auth` / `build_mcp_headers`, and `non_empty_string?`. That's roughly 120–150 of the ~340
code lines. `tool_lines` becomes a literal union (`"short" | "verbose"`), or an `in:` list
read from `Shared::ConversationTextView::TOOL_DETAIL_MODES`, as `validate_ui!` reads it today.

## What stays here

- **The layered merge.** Typemap reads one Hash, and the README says merging files is the app's
  job. `candidate_paths` + `deep_merge` stay, and Typemap maps the merged Hash.
- **Resolving `[[llm]] server` into a URL**, with the three migration messages in
  `resolve_server` / `server_is_now_an_id`, plus the stray-`api_key` hint.
- **The unique-id checks** (`server id`, `llm name`, `code.mcp id`), which could move into the
  root file class's `validate`.
- **Folding `bearer_token` / `basic_auth` into `headers`, and "exactly one of `command` / `url`"**:
  the second becomes the file-shaped MCP class's `validate`.
- **`warn_loose_perms` / `holds_secret?`**, which run per file before the merge, on the raw Hash.
- **`overrides:` and `pick`** for the CLI safety switches.
- **Wrapping `Typemap::DataError` into `Config::Error`**, so the bins' `rescue` stays as it is.

## The shape

Two of today's value objects don't match the file. `Llm#server` is a resolved URL and
`Llm#api_key` comes from the server, while `McpServer#headers` already has the auth folded in.
So the file gets its own classes, mapped by Typemap, and the resolved ones stay as they are:

- file shape: `Root` (`server`, `llm`, `search`, `code`, `ui`, `titler`, `web`; not `File`,
  which would shadow `::File` inside `Config`), `LlmEntry`, `Code`, `McpEntry`, `BasicAuth`, `Ui`;
- shared as-is: `Server`, `Search`, which already match the file 1:1;
- resolved, unchanged for callers: `Llm`, `McpServer`, `Config`.

Every new class needs `@!attribute [r]` docs, so some of the saved code returns as comments.
The net saving is maybe 60–100 lines of code; the real gain is that the schema is a set of
declared types rather than imperative checks.

`[titler]` and `[web]` are another program's tables, today checked "is a table" only: typed
`Hash[String, Object]?` they keep exactly that strictness. The same type covers `[[llm]] params`.

## Costs

- **Error messages change.** `` server "grok": `url` is required `` becomes
  `server[0].url: required`, an index where today's message has the entry's name;
  see `../typemap/design/ideas/error-path-names-the-entry.md`.
  `spec/shared/config_spec.rb` has 62 `assert_raises` to revisit.
- **`rbs` becomes a runtime gem in `:default`**, so the lean chat shell loads it too:
  `require "rbs"` measured 0.16–0.22 s here. Typemap needs only its parser, not the type
  environment, so the unresolved `Tuile::*` / `Pikuri::*` names elsewhere in `sig/` are no
  problem.
- **`sig/` must be current at runtime**, since a stale file means stale config types. The CI
  `git diff --exit-code sig/` covers it; a local edit without `rake sig` gets caught at
  `rake check`.
- **Typemap is pre-release**, so it rides its git master like tuile and pikuri do (`Gemfile`).

## Open questions

- `Q_nonempty`: `id` / `name` / `url` / `model` must be non-blank today. `format: /\S/` prints
  the pattern in its message; a `validate` per class keeps our wording but brings back some of
  the code Typemap was supposed to remove. Or Typemap gains a non-empty limit.
- `Q_rbs_boot_cost`: is 0.2 s on every boot acceptable for the chat shell, or does Config use
  `constrain type:` (no `rbs` at runtime) and give up "a type is written once"?
- `Q_rescue_wrap`: does `Config::Error` survive as our own class, or do the bins rescue
  `Typemap::DataError` directly?
