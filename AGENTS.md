# pikuri-tui — AGENTS.md

## What this is

Terminal UI front-ends for [pikuri](https://github.com/mvysny/pikuri) — a Ruby LLM agent framework.

- **`pikuri-tui-chat`** — general-purpose chat with web search and calculator tools.
- **`pikuri-tui-code`** — in-repo coding agent (sandboxed file/shell tools, git diff view, plan mode).
- **`pikuri-tui-computer`** — desktop assistant for this machine: the OS helper (file + network-severed sandboxed bash tools) plus local Thunderbird mail + calendar (search/read + human-gated draft hand-offs), with web research quarantined behind an isolated sub-agent.

Pikuri owns the agent loop, tool execution, and LLM transport; pikuri-workshop's `Pikuri::Conversations` hosts the conversation — its threads, injection, cancel, clear and model switch. This project owns nothing but the TUI shell: a conversation pane, a diagnostic log pane, an input field, and a status bar.

## Promises

- **A terminal UI and nothing else.** Loop, tools, transport *and prompts* stay pikuri's; a behaviour implemented on both sides drifts, and the user sees it as "the TUI does something the CLI doesn't".
- **pikuri's *Privacy first* holds at this layer.** No LLM connection ships built in, and no shell acquires a network reach its own pitch does not state — a convenience that quietly widens egress is a violation even when nobody triggers it.
- **pikuri's *trifecta broken by construction*, kept by structure first.** Untrusted content is separated by construction — the computer shell's web research runs in a quarantined sub-agent, its `bash` is network-severed — never by filtering, because filters lose to adversarial text.
- **Every outbound leg waits on a keystroke** in the coding and computer shells — a write, a `bash`, a research delegation, a mail or calendar hand-off. The computer shell holds all three trifecta legs at once, so where construction cannot separate them the human is the gate. The chat shell is deliberately the lean one and makes no such promise.

## Design docs

| File | Owns | Loaded |
|---|---|---|
| `README.md` | the operator: positioning, install, the config schema, how to run each shell | — |
| `AGENTS.md` (this) | promises, invariants, the module map, conventions, commands | every turn |
| `design/architecture.md` | how the pieces compose — wiring, dependency direction, threads, the two flows; normative | lazy |
| `design/decisions.md` | why this and not that — `D_` entries, FAQ-shaped | lazy |
| `design/ideas/` | not yet decided — one file per idea, `ls` is the index, deleted on graduation | transient |
| class rdoc / `bin/` script comments | what one symbol does and why it is shaped so; a script's arguments and boot sequencing | at the symbol |

Every fact lives in exactly one of these; the others link to it.

## Invariants

- **Every UI mutation runs on the UI thread** — the one that owns `Screen#run_event_loop`; anything off it marshals back through `screen.event_queue.submit { … }`. Most Tuile mutators raise `"UI lock not held"` off-thread and the rest silently corrupt the repaint set. The threading story is in `design/architecture.md`.
- **Tuile owns the event loop and repaint.** No `SIGWINCH` handler, no `puts` to the terminal once the screen is up, no repaint on a side thread.
- **No second HTTP or LLM client in `lib/` or `bin/`.** pikuri owns the transport; a retry or a rescue added here drifts from the one it already implements. `spec/no_second_llm_client_spec.rb` is the check.
- **A gap in the UI is a missing pikuri primitive** — a new listener event, an existing `Control`, a new tool — never a workaround on this side. See `D_pikuri_owns_the_runtime`.
- **A short tool line's words are pikuri's**, never a tui-side table mapping tool names onto phrasings. See `D_short_tool_lines`.
- **Nothing under `Shared::` references `Chat` / `Code` / `Computer`.** A block that needs to know its host takes it as a constructor argument or surfaces a listener the host subscribes to.
- **Nothing under `Shared::` may require a `:code` / `:computer` gem.** The chat process eager-loads that whole directory; `Shared::FileCommands` is duck-typed on pikuri's registry for exactly this reason. See `D_bundler_groups`.
- **Log through `Pikuri.logger_for`, never `Tuile.logger`.** One private `LOG` constant per class; `Tuile.logger` is reserved for capturing Tuile's own noise. See `D_log_through_pikuri`.
- **Our bugs raise; a library's exceptions are logged and degraded.** An uncaught raise in the event loop tears the screen down and takes the session with it. See `D_tui_degrades_not_crashes`.
- **The conversation pane is never a log sink.** It is what the user reads; the log pane is what we read when something is wrong.
- **A confirmation is answered in the transcript, and focus is what arms it.** No grace window, no timer, no text-entry popup. See `D_transcript_confirmer`.
- **A parked question ends on the turn's cancel, never through a hook of its own.** `Code::TranscriptConfirmer#ask` waits in pikuri's `Agent::Control::Handoff` on the token the tool passes it, so `Ctrl+C`, quit and any other `cancel!` make it raise `Cancellable::Cancelled`. Wait on anything else and a parked tool leaves `Ctrl+C` looking broken, or the shutdown waiting.
- **An agent is one conversation, and pikuri-workshop's `Pikuri::Conversations` hosts it.** No turn thread, injection queue or cancel token of our own; each `App` opens one conversation, and a `/clear` boots a new agent through its `configure_agent`. So per-agent state — an extension, a `TokenLog`, a skill activation — is built there or reset on `Booting`, never once in `App.new`. See `D_pikuri_owns_the_runtime`.
- **A gated skill must not be *listed*.** `Code::SkillActivationListener` builds the palette's skill half from pikuri's activation, not its catalog, and re-lists as the `paths:` gate opens and closes.
- **`Shared::ConversationTextView#clear` is not a redraw.** It drops every region, a parked confirmer question included; a density toggle re-runs kinded thunks instead. See `D_density_thunks`.
- **The `edit` / `write` diff blocks are never kinded**, so no density toggle can hide them: a diff is reviewed, not skimmed. See `D_density_thunks`.
- **Hide a pane with `visible=`, never by detaching it from its box.** Detaching fires `on_detached` and stops whatever the pane is running — a data feed that hiding exists to preserve. See `D_visible_not_detach`.
- **`Code::GitWatcher` must keep polling while the sidebar is off screen** — the status-rule digest stands in for the hidden panes. See `D_visible_not_detach`.
- **A container assigns its child rects in `relayout`, all of them on every pass** — an empty rect included (`Code::WorkspaceSidebar`), or a child keeps painting at the columns it used to hold. Coordinates are measured inside the parent; screen-space wants `absolute_rect`.
- **Layout is deferred**: a parent's `rect=`, a `visible=` flip and `Code::Layout#sidebar_mode=` only mark, and Tuile settles at the end of the event — read a rect in the turn that dirtied it only after `flush_layout`, which a spec calls itself (an unsettled read raises there). A spec sizes a component with `Tuile::Testing.place`, never `rect=`, which only a parent's `relayout` may call.
- **Every accent comes from `Shared::AppTheme`**, `theme.hint` first; a component that invents an RGB is the exception and says why in its rdoc. See `D_borderless_panes`.

## Module map

- `lib/shared/` — the toolkit all three shells compose out of; `log/`, `markdown/` and `model/` are its sub-namespaces.
- `lib/code/` — the coding shell, and the confirmer / diff adapters the computer shell reuses, so a change here changes two shells.
- `lib/chat/` — `Chat::App` + `Chat::Layout`: the baseline shell the other two were copied from.
- `lib/computer/` — `Computer::App` + `Computer::Layout`: chat's layout, the coding shell's safety machinery.
- `lib/pikuri_tui.rb` — the Zeitwerk loader (root `lib/`) + eager-load; skips `Code` / `Computer` when their gems are absent.
- `bin/` — one boot script per shell (CLI, config, pre-screen prompts, then the `App`), plus `setup` / `install` / `uninstall`.
- `sig/pikuri_tui.rbs` — generated from the YARD tags by `rake sig`, never edited by hand; `Shared::Config` reads its types at runtime (`D_config_through_typemap`).
- `spec/support/` — `wait_until` (a real worker thread's UI hand-off), the tool-event builders and `paint` / `painted_region` (one component through its own canvas).

## Conventions

- **Ruby, no Rails.** Plain classes, `Data.define` for value objects, Tuile for the terminal, pikuri for the runtime.
- **`# frozen_string_literal: true`** atop every Ruby file, `spec/` and `bin/*` included.
- **YARD on every public module, class and method in `lib/`**, `@raise` for expected exceptions; `bin/` and `spec/` are exempt.
- **A concrete YARD type on every method, attribute and constant in `lib/`, private ones included** — sord compiles them into `sig/pikuri_tui.rbs` and `rake sig` fails on a missing or unresolvable one. `Object` only for a value that can truly be anything (raw TOML); a `LOG` constant's whole doc is `# @return [Logger]`.
- **`UI-thread-confined` in a class header** means exactly the thread that owns `Screen#run_event_loop`, with off-thread-safe exceptions marked on the methods themselves.
- **No umbrella namespace.** `lib/` is the Zeitwerk root, so every file maps to a top-level constant (`lib/shared/log/ui.rb` → `Shared::Log::UI`); reusable blocks under `Shared::`, shell-specific code under `Chat` / `Code` / `Computer`.
- **No `require_relative` inside `lib/`** — Zeitwerk resolves internal references and the boot file eager-loads, so a filename ↔ constant mismatch fails at boot. An acronym needs an `inflector.inflect` entry in `lib/pikuri_tui.rb`.
- **A namespace-only module gets no doc *and no file*** — leave it a Zeitwerk implicit namespace. Add `foo.rb` back only when it states a rule next to the code it governs, as `code.rb` / `computer.rb` do.
- **Widget-class suffix on Tuile subclasses and wrappers only**, named for what the component does rather than where it sits (`Shared::ConversationTextView`, not `TopTextView`); a non-widget takes a plain agent-noun name. The exception is `Layout`: a composite borderless pane takes `*Pane`, and each shell's root layout stays plain `Layout`.
- **Grow by adding a component or a listener variant**, not by complicating the layout — neither `Chat::App` nor the bins should need to grow for a new surface.
- **Dedup by extracting a block into `Shared::`, never by sharing scaffolding.** The test is "does it stand alone with a clear contract?", not "is it a widget"; the three `App` / `Layout` copies stay parallel. See `D_parallel_shells`.
- **Readable, not obfuscated.** This is a thin shell, and an abstraction added "in case" loses every argument against concrete code.
- **Bundler.** `bin/*` self-bootstrap via `require 'bundler/setup'` with `BUNDLE_GEMFILE` pinned through `__dir__`, so the scripts work symlinked into `~/.local/bin/`. Each bin sets up only its own group. See `D_bundler_groups`.
- **Tests: rspec-core with minitest-style asserts.** `describe` / `it`, but `assert_equal` / `refute` — the same convention as pikuri, so the two codebases read side by side.
- **A spec asserting after a direct call runs `Tuile::Testing.loop` first.** Tuile's fake queue holds every `submit`, the UI thread's own included, until a loop turn plays it; `FakeScreen#key` plays one around the keystroke, and `wait_until` keeps playing them while a real worker thread finishes.
- **Never plain `rspec`.** `spec_helper` pulls the whole `:code` group, and only the Bundler environment resolves it to the versions `Gemfile.lock` pins — doubly so while a pikuri gem is switched to a local `path:`.

## Commands

- `bundle exec rake check` — the sord signatures, the spec suite, rubocop, then the doc-layer tripwire; also the default task, and what CI runs (`.github/workflows/ci.yml`).
- `bundle exec rspec spec/code/app_spec.rb:42` — one test, still through Bundler.
- `bundle exec rubocop -a` — fix what rubocop can; `.rubocop.yml` says why each cop is tuned.
- `bundle exec rake sig` — regenerate `sig/pikuri_tui.rbs` after a YARD change, and commit it; CI fails on a stale one.
- `bundle exec rake design_tripwires` — the doc-layer checks alone.

## Skills this project follows

- **Component-oriented:** cohesive components with a minimal API that reach what they need directly, no MVC layers and no `Abstract*View` base; the `cop` skill has the rules.
- **Tuile mechanics:** the single-threaded event loop, the `event_queue.submit` rule, and how a widget subclass composes with a nested listener; the `tuile` skill has them. Nearly every task here is UI work — read it and `cop` before writing or refactoring a component.
- **Doc comments** carry the per-symbol what *and* why, complete standalone; the `writing-rdoc` skill has the rules.
- **Ideas:** loose ideas live one per file in `design/ideas/` and are deleted on graduation, their lasting nuggets moved to the homes the *Design docs* table names; the `ideas-folder` skill has the procedure.

## Maintenance of this file

Loaded every turn; cap 34 KB, a module's own `AGENTS.md` 10 KB. Over it, in this order:
delete what has no home — status, history, class lists, what the code already says; trim
each line to its fact plus one clause and send the explanation home — why →
`design/decisions.md`, how across symbols → `design/architecture.md`, how in one symbol →
its rdoc; only then a module's own `AGENTS.md`, peripheral modules first, never the core.
Never paraphrase a lazy entry into a line here. `design/verify_design_tripwires.sh` checks
the caps and the cites.
