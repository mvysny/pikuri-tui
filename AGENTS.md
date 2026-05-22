# CLAUDE.md

## What this project is

A pair of Tuile-based TUI front-ends on a shared core, wrapping the
[pikuri](https://codeberg.org/mvysny/pikuri) library:
`bin/pikuri-chat` (general-purpose chat) and `bin/pikuri-code`
(in-repo coding agent). Both bind the same `Pikuri::Agent` and the
same `Pikuri::Tool` set as pikuri's own demo scripts; they differ
only in their system prompt and which tools they register.

Pikuri ships those wirings as plain stdin/stdout REPL demos in its
own `bin/`. This project replaces the REPL with a Tuile component
tree — a conversation pane (the LLM-stream transcript), a log pane
(internal diagnostics), an input field, a status bar — and reuses
pikuri unchanged otherwise. All LLM transport, tool execution,
agent loop control, prompts: that's all pikuri. We own the UI
shell only.

## Status

Scaffold. `Gemfile` and the Zeitwerk-wired `lib/pikuri_tui.rb` boot
file are in; no bin scripts yet, no Tuile listener yet.

## Scope decisions

- **Reuse pikuri as runtime; this project owns the TUI shell.**
  `Pikuri::Agent` is the loop; `Pikuri::Tool::*` are the tools;
  `Pikuri::Agent::Event` is the stream we render. We add a Tuile
  listener (renders the event stream into a `TextView`), a Tuile
  confirmer (prompts via a `Popup` instead of stdin), and the
  layout / focus / input wiring around them. Anything beyond that
  is a bug or scope creep.

- **Two panes, two purposes.** The `TextView` shows the LLM
  conversation transcript — assistant Markdown, reasoning,
  tool-call lines, tool observations — driven by our pikuri
  listener. The `LogWindow` shows internal diagnostics —
  pikuri's per-subsystem loggers via `Pikuri.log_io=`,
  pikuri-tui's own loggers, anything we route through
  `Tuile.logger`. Never cross the streams: the conversation
  pane is what the user reads; the log pane is what we read
  when something's wrong.

- **The seam.** All `Pikuri::*` references stay inside the bin
  scripts (boot/wiring) and the small adapter set under
  `lib/pikuri_tui/` (the listener, the confirmer, anything else
  that needs to know what an event or a prompt is). Tuile-only
  components — layout containers, widgets, custom panels — must
  not reach into `Pikuri::*`. Same fork-or-swap rationale as
  pikuri's own seam: if pikuri's surface shifts under us, the cost
  is rewriting a small handful of files, not chasing references
  through every widget.

- **The threading rule.** Tuile is single-threaded: every UI
  mutation (`rect=`, `content=`, `add_line`, `invalidate`,
  `screen.focused=`) must run on the thread that owns
  `Screen#run_event_loop`. The agent loop blocks on the LLM and
  must NOT run on that thread, so it goes on a worker. The worker
  marshals every render back via
  `screen.event_queue.submit { … }`. This is non-negotiable: most
  Tuile UI methods raise `"UI lock not held"` if you violate it,
  and the ones that don't will silently corrupt the repaint set.

- **Streaming, mid-loop input, multi-window layouts beyond log +
  input — out of scope until there's a concrete need.** Pikuri
  exposes `Control::Interloper` for mid-loop user injection;
  wiring it through is a real feature, not a 5-minute add, so it
  waits.

## Layout

Per-file rationale lives in each source file's YARD header — this
is the package map. Everything we ship lives under the `PikuriTui::`
namespace; `lib/pikuri_tui.rb` boots Zeitwerk over `lib/pikuri_tui/`.

- `lib/pikuri_tui.rb` — Zeitwerk loader + eager-load over
  `lib/pikuri_tui/`; one require for callers.
- `lib/pikuri_tui/version.rb` — `PikuriTui::VERSION`.
- `lib/pikuri_tui/tuile_listener.rb` — `PikuriTui::TuileListener`,
  a `Pikuri::Agent::Listener::Base` subclass that renders the
  event stream into a `Tuile::Component::TextView` (the
  conversation pane). The equivalent of pikuri's
  `Pikuri::Agent::Listener::Terminal`, retargeted at the TUI.
  Shared by `Chat::App` and the planned `Code::App`.
- `lib/pikuri_tui/passthrough_buffer.rb` —
  `PikuriTui::PassthroughBuffer`, API-compatible variant of
  `StreamingMarkdownBuffer` (same `#append` / `#finalize` /
  `#finalized?` / `#source` surface and the same
  `(remove_last_n, lines_to_add)` sink contract) that skips the
  Markdown render and the block-cutter entirely — the accumulated
  source is split on `\n` and passed through to the sink as-is. For
  streams whose payload is already in display form (plain text,
  pre-formatted output) where `TTY::Markdown` would corrupt or
  re-style it.
- `lib/pikuri_tui/counting_log_io.rb` — `PikuriTui::CountingLogIO`,
  the `IO`-shaped sink that forwards every line to the diagnostic
  `LogWindow` and counts error-class writes so the `Ctrl+L`
  status-bar hint can flag "something broke." Shared by both
  shells.
- `lib/pikuri_tui/log_popup.rb` — `PikuriTui::LogPopup`, the
  `Popup` wrapper around the eager `LogWindow` that resets the
  unread-error counter on dismiss. Shared by both shells.
- `lib/pikuri_tui/chat.rb` — `PikuriTui::Chat` namespace shell
  for the chat front-end.
- `lib/pikuri_tui/chat/app.rb` — `PikuriTui::Chat::App`, the
  Tuile shell for `bin/pikuri-chat` (conversation `TextView` +
  diagnostic `LogWindow` + input field + status bar).
- `lib/pikuri_tui/chat/layout.rb` — `PikuriTui::Chat::Layout`,
  the vertical-split root layout (conversation top, input bottom).
- `lib/pikuri_tui/chat/input.rb` — `PikuriTui::Chat::Input`, the
  `TextArea` subclass that rebinds Enter to submit-and-clear.
- `bin/pikuri-chat` — boot script for the chat agent: configures
  `RubyLLM` for the local llama.cpp server, builds a
  `Pikuri::Agent` wired with the web/calc tools and a
  `PikuriTui::TuileListener`, hands it to `PikuriTui::Chat::App`.

Planned, not yet present:

- `lib/pikuri_tui/code/…` — sibling `PikuriTui::Code` namespace
  for the `bin/pikuri-code` shell. Will reuse the shared pieces
  (`TuileListener`, `CountingLogIO`, `LogPopup`) and add the
  code-agent-specific composition (Tuile-based confirmer,
  coding-tool wiring).
- `bin/pikuri-code` — same shape as `bin/pikuri-chat`, with the
  six coding tools, a `Pikuri::Tool::Workspace::Cwd` rooted at
  `Dir.pwd`, and a Tuile-based confirmer instead of
  `Pikuri::Tool::Confirmer::TERMINAL`.

## Conventions

- **Ruby, no Rails.** Plain classes, `Data.define` for value
  objects, Tuile for terminal UI, pikuri for the agent runtime.
  Don't add a parallel LLM SDK — pikuri owns that.
- **`# frozen_string_literal: true`** at the top of every Ruby
  file (`lib/`, `spec/`, `bin/*`). Add it to any new file you
  create.
- **YARD docs on every public module, class, and method in
  `lib/`.** Use concrete types in `@param` and `@return`
  (`String`, `Integer`, `Tuile::Component::LogWindow`,
  `Pikuri::Agent::Event::ToolCall`) — never bare `Object` or
  `Any`. Document expected exceptions with `@raise`. One-line
  summary first, then blank line, then tags. `bin/` and `spec/`
  files don't need it.
- **Bundler.** Entry-point scripts in `bin/` self-bootstrap via
  `require 'bundler/setup'` so callers don't need the
  `bundle exec` ceremony. Pin the `BUNDLE_GEMFILE` to this
  project's Gemfile via `__dir__` so the scripts work when
  symlinked into `~/.local/bin/`.
- **Internal logging goes to Tuile's `LogWindow`, not stderr.**
  Wire `Tuile.logger` and `Pikuri.log_io=` to a
  `Tuile::Component::LogWindow::IO` early in boot so pikuri-tui's
  own loggers, pikuri's per-subsystem loggers, and any
  third-party log noise we route here all land in the visible
  diagnostic pane. The conversation pane (`TextView`, driven by
  `PikuriTui::TuileListener`) is for the LLM stream — assistant
  Markdown, reasoning, tool calls, observations — and is not a
  log sink; never write log lines into it.
- **Our bugs raise; library exceptions are logged.** Two buckets:
  unexpected internal state in *this project's* code raises with
  the offending data included — silent fallbacks hide what
  actually happened. Exceptions thrown by libraries we depend on
  (pikuri, ruby_llm, Tuile, Faraday, tty-markdown, everything we
  didn't write) are caught at the call site, logged as `error`
  through the internal logger (so they surface in the `LogWindow`
  diagnostic pane), and the surrounding code returns to a safe
  state — degraded rendering, dropped event, abandoned turn.
  Rationale: the TUI's event loop owns the whole screen and an
  uncaught raise tears it down, losing the user's session. The
  diagnostic pane is the right place to surface upstream
  breakage — it's visible without being destructive. This is a
  deliberate departure from pikuri's "errors stay loud on the
  chat path" rule: pikuri is a CLI that can afford to crash,
  pikuri-tui is a long-running TUI that cannot.
- **Zeitwerk autoloads everything under `lib/`.** Don't add
  `require_relative` chains inside `lib/`; let the loader resolve
  internal references. The boot file (`lib/pikuri_tui.rb`)
  eager-loads at startup so any filename ↔ constant mismatch
  fails fast at boot, not at first reference inside the event
  loop. New files must define exactly the camelcased constant
  matching their path; if you want an acronym, add an entry to
  the `inflector.inflect` block in `lib/pikuri_tui.rb`.
- **Namespacing direction.** Everything we ship lives under the
  `PikuriTui::` namespace at the path Zeitwerk expects
  (`lib/pikuri_tui/foo/bar.rb` → `PikuriTui::Foo::Bar`). Don't
  introduce top-level constants.
- **Tests: rspec-core with minitest-style asserts.** Use the
  `rspec-core` runner (`describe`/`it`) but write assertions in
  the minitest style (`assert_equal`, `assert`, `refute`, …)
  rather than RSpec matchers. Same convention as pikuri — keeps
  the two codebases readable side-by-side.

## Working on this codebase

- **Pikuri owns the loop and the tools; we own the UI shell.**
  When changing pikuri-tui, the question is "what does the user
  see, and where is focus?" — the agent loop is somebody else's
  problem. Don't reimplement event dispatch, tool routing, or
  rescue paths in pikuri-tui; reach for a pikuri-side primitive
  (new listener, existing `Control`, new tool back in pikuri) if
  the answer isn't already a UI concern.
- **Tuile owns the event loop and repaint; we own the
  components.** Same shape one level down. Don't install your own
  `SIGWINCH` handler, don't `puts` directly to the terminal once
  the screen is up, don't repaint on a side thread.
- **Grow by adding components and listener variants, not by
  complicating the layout.** New UI surface should land as a new
  Tuile component composition or a new
  `Pikuri::Agent::Listener::Base` subclass with its own specs;
  neither `PikuriTui::Chat::App` nor the bin scripts should need
  to grow.
- **Readable, not obfuscated.** Prefer the simplest
  implementation that does the job. The audit-it-in-an-evening
  ceiling that pikuri sets for itself applies here too: this
  project is a thin shell, and every abstraction layer added "in
  case" loses every argument against concrete code.
