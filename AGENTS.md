# pikuri-tui — AGENTS.md

An index, not a manual: each entry is the one-line invariant ("what you must not break") plus
pointers to where the truth and its rationale live — a class's rdoc (`See {Class}`), a decision
(`See D_<slug>`), a requirement (`See R_<slug>`). Never the explanation itself. **Size cap: 34 KB.** Over it,
garbage-collect by moving, never summarising: a rationale to its `D_`, a per-symbol rule to its
rdoc, a cross-symbol flow to `design/architecture.md`, a directory's own invariants and class map
to that directory's `AGENTS.md` (`git ls-files '*AGENTS.md'` for the set; ≤ 10 KB each, loaded
only when work touches the directory). `CLAUDE.md` is exactly `@AGENTS.md`, here and beside every
nested `AGENTS.md`.

## What this is

Three Tuile-based TUI front-ends on one shared toolkit, wrapping the
[pikuri](https://codeberg.org/mvysny/pikuri) library: `bin/pikuri-tui-chat` (general chat),
`bin/pikuri-tui-code` (in-repo coding agent), `bin/pikuri-tui-computer` (desktop assistant — the OS
helper plus local Thunderbird mail / calendar). Pikuri ships those same wirings as stdin/stdout
REPL demos; this project replaces the REPL with a component tree and nothing else. All LLM
transport, tool execution, agent-loop control and prompts are pikuri's; the UI shell is ours
(`R_shell_only`).

## Design docs

Rationale and reference live under `design/`; this file holds only what its header says it may.
Each file has one audience and *what it is allowed to own*; every file's preamble states its
entry shape and how to cite it. This section is the whole contract — nothing outside the repo
is needed to follow it.

| File | Owns | Loaded? |
|---|---|---|
| `README.md` | the operator: positioning, install, the config schema, how to run each shell | — |
| `AGENTS.md` (this) | what you must not break from a distance; the module map; this table — its rules are in its header | **every turn** |
| `design/requirements.md` | what must hold — `R_` entries, stated not argued | lazy |
| `design/architecture.md` | **the map** of the code as it is — wiring, threading, the turn and confirmation flows; **the code is the truth** | lazy |
| `design/decisions.md` | why this and not that — `D_` entries, roads not taken | lazy |
| `design/ideas/` | not yet decided — one file per idea, `ls` is the index, deleted on graduation | transient |
| class rdoc / `bin/` script comments | per-symbol truth and its local rationale; a script's arguments and boot sequencing | source of truth |

Rules that keep the split from drifting:

- **One home per fact; the others link.** A one-line restatement that saves a jump is fine —
  repeat the *fact*, defer the *explanation*. Compressing a `D_` entry into a bullet here is a
  third copy, not a summary.
- **`decisions.md` argues, `requirements.md` states, `architecture.md` composes and never
  argues.** A paragraph explaining *why* in any file but `decisions.md` has drifted; move it and
  cite the `D_`.
- **A `D_` is earned by what happened, not by having had an alternative:** it shaped what the
  project is (reverse it and the README's first paragraph changes), or it cost research the next
  person would otherwise redo. A testing library, a CI host, a version bump — a comment at the site
  of the choice, never an entry. Only decisions already taken; ideas, TODOs and open questions go
  to `design/ideas/`. A shipped decision that is reversed keeps its entry as a tombstone. Nothing
  about `design/` itself or its tooling is an entry.
- **An `R_` is a promise the README's pitch makes, made an official rule — and the owner writes
  it.** An agent never adds, edits or retires one; it proposes, in conversation or as a drafted
  entry in `design/ideas/`. The owner's ruler: allow the opposite everywhere — is it still the
  pitched project? "This project owns nothing but the TUI shell" → not the same project → `R_`.
  "Every UI mutation runs on the UI thread", "hide with `visible=`" → broken in places, same
  project → an *invariant*: one line in this file, named in the promise's *Enforced by*, no `R_`.
- **An invariant is one line here, and nothing more:** the rule, at most one clause of
  consequence, `T_<slug>` if tripwired, `See D_<slug>` only when a `D_` exists — no fork, no cite;
  the agent has the code. A directory's own invariants live in its `AGENTS.md`. A line that will
  not fit belongs in the chokepoint's rdoc.
- **Slugs:** `D_` decisions, `R_` requirements, `T_` tripwires (cited from a requirement's
  *Enforced by* or a seam line here, defined by the check), `Q_` open questions inside
  `design/ideas/` only — a durable doc never cites a `Q_`. Underscores throughout, backticked in
  prose, cited by slug never by position; `grep '^## D_' design/decisions.md` is the index. A
  sibling repo's slug is cited *without* the prefix (pikuri's `design/decisions.md` →
  `tool_summary_lines`), since the tripwire demands a local heading for anything spelled `D_…`.
- **`rake design_tripwires`** — the two scripts under `design/`, and part of `rake check`. Fails on
  any cited `D_` / `R_` without a heading, a `T_` cited with no check or checked with no citation,
  an oversized `AGENTS.md`, or a `CLAUDE.md` that isn't the shim. A failure is as often a stale
  expectation as a real violation: read the line before "fixing" the doc.

### Ideas & their graduation

An idea graduates the moment it is acted on, and graduation is not done until its file is gone.
Where the lasting nuggets land:

- the choice made + the alternatives rejected → a `D_` entry in `design/decisions.md` if it passes
  the gate above; otherwise a comment at the site of the choice
- a promise the pitch makes that must hold from now on → a proposal for the owner, who writes the
  `R_`; the invariant that keeps one → a line in this file
- a new class, or a changed responsibility → one line in the class map (`lib/shared/AGENTS.md`,
  `lib/code/AGENTS.md`) or in the module map below
- how the pieces work together — wiring, threading, a flow crossing several of them →
  `design/architecture.md`
- how one class works and why it is shaped so → its rdoc; a boot step → the bin's comments
- what a user or operator must know → `README.md`
- a cross-cutting invariant ("never …") → one line in this file
- work deferred *as a consequence of a logged decision* → that entry's *Consequences*

*Layout seeded from the `design-docs` skill (mvysny, `~/.claude/skills`); this project needs
nothing from it.*

## Invariants

- **Every UI mutation runs on the UI thread** — the one that owns `Screen#run_event_loop`. The agent loop blocks on the LLM, so it runs on a worker and marshals every render back through `screen.event_queue.submit { … }`; most Tuile mutators raise `"UI lock not held"` off-thread and the rest silently corrupt the repaint set. See `design/architecture.md`.
- **No second HTTP or LLM client in `lib/` or `bin/`.** pikuri owns the transport; a retry or a rescue added here drifts from the one it already implements. `T_no_llm_sdk`, `R_shell_only`.
- **Log through `Pikuri.logger_for`, never `Tuile.logger`.** One private `LOG` constant per class; `Tuile.logger` is reserved for capturing Tuile's own noise. See `D_log_through_pikuri`.
- **Our bugs raise; a library's exceptions are logged and degraded.** An uncaught raise in the event loop tears the screen down and takes the session with it. See `D_tui_degrades_not_crashes`.
- **A confirmation is answered in the transcript, and focus is what arms it.** Prose goes to the prompt, decisions go to the transcript; don't add a grace window, a timer, or a text-entry popup. See {Code::TranscriptConfirmer}, `D_transcript_confirmer`, `R_human_gated_egress`.
- **Hide a pane with `visible=`, never by detaching it from its box.** Detaching fires `on_detached` and stops whatever the pane is running — a data feed that hiding exists to preserve. See `D_visible_not_detach`.
- **Never short-circuit `rect=` on an empty rect** in a container that computes its own child rects: children keep painting at the columns they used to hold. See {Code::WorkspaceSidebar}.
- **The conversation pane is never a log sink.** It is what the user reads; the log pane is what we read when something is wrong. See `D_log_through_pikuri`.

## Module map

- `lib/shared/` — the toolkit all three shells compose out of; own `AGENTS.md`.
- `lib/code/` — the coding shell, plus the confirmer / diff adapters the computer shell reuses; own `AGENTS.md`.
- `lib/chat/` — `Chat::App` + `Chat::Layout`: the baseline shell the other two were copied from.
- `lib/computer/` — `Computer::App` + `Computer::Layout`: chat's layout, the coding shell's safety machinery.
- `lib/pikuri_tui.rb` — the Zeitwerk loader (root `lib/`) + eager-load; skips `Code` / `Computer` when their gems are absent.
- `bin/pikuri-tui-{chat,code,computer}` — one boot script per shell: CLI, config, pre-screen prompts, then the `App`.
- `bin/setup`, `bin/install`, `bin/uninstall` — `bundle install`; symlink the three shells into `$PREFIX` and back out.
- `spec/support/` — `marshalling_fake_screen.rb` (`fake_screen`, `wait_until`) and the tool-event builders.

## Conventions

- **Ruby, no Rails.** Plain classes, `Data.define` for value objects, Tuile for the terminal, pikuri for the runtime.
- **`# frozen_string_literal: true`** atop every Ruby file, `spec/` and `bin/*` included.
- **YARD on every public module, class and method in `lib/`**, concrete types in `@param` / `@return` (never `Object`), `@raise` for expected exceptions; `bin/` and `spec/` are exempt, as are the `LOG` constants. The `writing-rdoc` skill has the rules.
- **`UI-thread-confined` in a class header** means exactly the thread that owns `Screen#run_event_loop`, with off-thread-safe exceptions marked on the methods themselves. This is the definition the global `<Role>-thread-confined` rule defers to.
- **A namespace-only module gets no doc *and no file*** — leave it as a Zeitwerk implicit namespace and let the class map describe it. Add `foo.rb` back only when it gains real content or states a rule next to the code it governs, as `code.rb` / `computer.rb` do for the duplicate-don't-share rule.
- **No umbrella namespace.** `lib/` is the Zeitwerk root, so every file maps to a top-level constant (`lib/shared/log/ui.rb` → `Shared::Log::UI`). Reusable blocks go under `Shared::`, shell-specific code under `Chat` / `Code` / `Computer`; no bare top-level constant outside those homes.
- **No `require_relative` inside `lib/`** — Zeitwerk resolves internal references, and the boot file eager-loads so a filename ↔ constant mismatch fails at boot rather than mid-event-loop. An acronym needs an `inflector.inflect` entry in `lib/pikuri_tui.rb`.
- **Widget-class suffix on Tuile subclasses and wrappers only**, named for what the component does rather than where it sits: `Shared::ConversationTextView`, not `TopTextView`. A non-widget takes a plain agent-noun name (`GitWatcher`, `*Renderer`, `*Listener`). The sanctioned exception is `Layout`: a composite borderless pane built on one takes `*Pane` instead (`Shared::InputPane`), and each shell's root layout stays plain `Layout`.
- **Bundler.** `bin/*` self-bootstrap via `require 'bundler/setup'` with `BUNDLE_GEMFILE` pinned through `__dir__`, so the scripts work symlinked into `~/.local/bin/`. Each bin sets up only its own group. See `D_bundler_groups`.
- **Tests: rspec-core with minitest-style asserts.** `describe` / `it`, but `assert_equal` / `refute` — the same convention as pikuri, so the two codebases read side by side.
- **A spec that crosses a thread mounts `fake_screen`, not `Tuile::Screen.fake`.** Tuile's fake queue runs an off-thread `submit` inline on the caller, where it raises and the worker dies silently; `spec/support/marshalling_fake_screen.rb` queues instead and `wait_until` drains on the example thread. Use the two together.
- **Never plain `rspec`.** `spec_helper` pulls the whole `:code` group, and only the Bundler environment resolves it to the versions `Gemfile.lock` pins — doubly so while a pikuri gem is switched to a local `path:`.

## Commands

- `bundle exec rake check` — the spec suite, then both tripwire scripts; also the default task, and what CI runs (`.woodpecker.yml`).
- `bundle exec rspec spec/code/app_spec.rb:42` — one test, still through Bundler.
- `bundle exec rake design_tripwires` — the doc-layer and `T_` checks alone.

## Skills this project follows

- **Component-oriented:** cohesive components with a minimal API that reach what they need directly, no MVC layers and no `Abstract*View` base; the `cop` skill has the rules.
- **Tuile mechanics:** the single-threaded event loop, the `event_queue.submit` rule, and how a widget subclass composes with a nested listener; the `tuile` skill has them. Read both before writing or refactoring any UI component here — nearly every task in this repo is UI work.
- **Doc comments** carry the per-symbol what *and* why, complete standalone; the `writing-rdoc` skill has the rules.

## Working on this codebase

- **The question here is always "what does the user see, and where is focus?"** If the answer is not about that, it belongs back in pikuri — a new listener event, an existing `Control`, a new tool — not in a workaround on this side. See `D_pikuri_owns_the_runtime`.
- **Tuile owns the event loop and repaint.** Don't install a `SIGWINCH` handler, don't `puts` to the terminal once the screen is up, don't repaint on a side thread.
- **Dedup by extracting a block, never by sharing scaffolding.** A triplicated field or method across the three `App`s is the signal; the `App` / `Layout` copies themselves stay parallel. See `D_parallel_shells`.
- **Grow by adding a component or a listener variant, not by complicating the layout.** Neither `Chat::App` nor the bins should need to grow for a new surface.
- **A short tool line's words are pikuri's, not ours** — don't reintroduce a tui-side table mapping tool names onto phrasings. See `D_short_tool_lines`.
- **Readable, not obfuscated.** The audit-it-in-an-evening ceiling pikuri sets for itself applies here too: this is a thin shell, and an abstraction added "in case" loses every argument against concrete code.
