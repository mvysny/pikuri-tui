# CLAUDE.md

## What this project is

A pair of Tuile-based TUI front-ends on a shared core, wrapping the
[pikuri](https://codeberg.org/mvysny/pikuri) library:
`bin/pikuri-tui-chat` (general-purpose chat) and `bin/pikuri-tui-code`
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

Both shells are functional. `bin/pikuri-tui-chat` runs the full
Tuile UI — conversation pane with streamed Markdown, diagnostic
log popup (`Ctrl+L`), input field, footer spinner + token status —
against a local llama.cpp server, with specs and Woodpecker CI in
place. `bin/pikuri-tui-code` (the `PikuriTui::Code` namespace) is
the in-repo coding shell: the same Tuile UI plus a project-rooted
workspace, the bubblewrap sandbox, the six file/shell tools wired
with a modal y/n confirmer (`Code::ConfirmerPopup`) on writes and
bash, sub-agent-only network tools, and the skill / task / MCP /
sub-agent extensions — all ported from pikuri's `bin/pikuri-code`
demo onto the Tuile shell.

The two shells share their UI machinery as deliberate parallel
copies, not a common base (see `lib/pikuri_tui/code.rb`), and their
dependencies are split across Bundler groups: `bin/pikuri-tui-chat`
runs `Bundler.setup(:default)`, `bin/pikuri-tui-code` runs
`Bundler.setup(:default, :code)`, so the heavier coding gems stay
off the chat process's load path. `lib/pikuri_tui.rb` ignores the
`PikuriTui::Code` subtree entirely when the `:code` gems aren't
loaded.

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

- **Multi-window layouts beyond log + input — out of scope until
  there's a concrete need.** (Streaming and mid-loop input used
  to sit on this list; both have since landed. The chat agent
  runs with `streaming: true` and deltas reach the listener
  through a 15 fps `Listener::RateLimited` coalescer into
  `StreamingMarkdownBuffer`. Mid-loop input rides pikuri's
  `Control::Interloper`: Enter during a running turn injects into
  the agent's queue — drained at the next tool-result boundary
  and echoed by the listener as a `mid_loop:` `UserTurn` — the
  conversation footer shows an "N queued" count while injections
  are pending, and anything still queued when the turn ends is
  delivered as a fresh turn by `Chat::App`.)

## Layout

Per-file rationale lives in each source file's YARD header — this
is the package map. Everything we ship lives under the `PikuriTui::`
namespace; `lib/pikuri_tui.rb` boots Zeitwerk over `lib/pikuri_tui/`.

- `lib/pikuri_tui.rb` — Zeitwerk loader + eager-load over
  `lib/pikuri_tui/`; one require for callers.
- `lib/pikuri_tui/version.rb` — `PikuriTui::VERSION`.
- `lib/pikuri_tui/app_theme.rb` — `PikuriTui::AppTheme`, a
  `Tuile::Theme` subclass carrying the app's own color tokens
  (`:tool` / `:notice` / `:error` / `:thinking` / `:detail` /
  `:user`) on top
  of the built-in accents, with one coloring helper per token, plus
  `DARK` / `LIGHT` and the `THEME_DEF` pair the bins install via
  `screen.theme_def=` (and `spec_helper` via `ThemeDef.default=`).
  The single source of truth for every UI accent both shells paint;
  the listener, the apps, and the confirmer read these instead of
  hardcoding Rainbow colors. The markdown body palette
  (`AnsiConverter`) is deliberately left out — it renders content,
  not chrome, and runs screen-agnostically in specs.
- `lib/pikuri_tui/tuile_listener.rb` — `PikuriTui::TuileListener`,
  a `Pikuri::Agent::Listener::Base` subclass that renders the
  event stream into a `Tuile::Component::TextView` (the
  conversation pane). The equivalent of pikuri's
  `Pikuri::Agent::Listener::Terminal`, retargeted at the TUI.
  Shared by `Chat::App` and the planned `Code::App`.
- `lib/pikuri_tui/markdown_renderer.rb` —
  `PikuriTui::MarkdownRenderer`, the single entry point for
  turning Markdown into ANSI for the conversation pane. Parses
  with kramdown (GFM dialect via `kramdown-parser-gfm`, with an
  LLM-typo table-separator repair pre-pass) and renders through
  `AnsiConverter`. Both the non-streaming `Assistant` path and
  the streaming buffer render through it.
- `lib/pikuri_tui/markdown_renderer/ansi_converter.rb` —
  `PikuriTui::MarkdownRenderer::AnsiConverter`, this project's
  own `Kramdown::Converter::Base` subclass: parse tree → ANSI.
  Replaced `tty-markdown` (whose stale pins on `strings` and
  `rouge` blocked dependency updates) and natively fixes what the
  old renderer needed hacks for — loose lists render loose,
  ordered-list numbering survives, paragraphs wrap as a whole
  with inline styles flowing across lines. Emits only the SGR
  alphabet `Tuile::StyledString` models, since the thinking pane
  round-trips its output through `AnsiGrayscale`. Syntax
  highlighting via rouge; honors `NO_COLOR` (the spec suite
  relies on that).
- `lib/pikuri_tui/streaming_markdown_buffer.rb` —
  `PikuriTui::StreamingMarkdownBuffer`, stateful buffer that
  turns a stream of Markdown deltas into in-place rewrites of a
  `Tuile::Component::TextView::Region`, with a block-cutter that
  bounds per-token re-render cost to the currently-open block.
  Must be driven from the UI thread.
- `lib/pikuri_tui/passthrough_buffer.rb` —
  `PikuriTui::PassthroughBuffer`, API-compatible variant of
  `StreamingMarkdownBuffer` (same `#append` / `#finalize` /
  `#finalized?` / `#source` surface and the same
  `(remove_last_n, lines_to_add)` sink contract) that skips the
  Markdown render and the block-cutter entirely — the accumulated
  source is split on `\n` and passed through to the sink as-is. For
  streams whose payload is already in display form (plain text,
  pre-formatted output) where the Markdown renderer would corrupt or
  re-style it.
- `lib/pikuri_tui/ansi_grayscale.rb` — `PikuriTui::AnsiGrayscale`,
  repaints an ANSI-colored string as a single muted fg with
  structural attributes (bold, italic, underline) preserved. Used
  on the thinking-pane path so reasoning reads as visually
  distinct from the assistant's final answer. The tone is the
  `AppTheme` `:thinking` token the listener passes (`fg:`), so it
  tracks light/dark; the `GRAY` default is the screen-free fallback.
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
  Tuile shell for `bin/pikuri-tui-chat` (conversation `TextView` +
  diagnostic `LogWindow` + input field + status bar).
- `lib/pikuri_tui/chat/layout.rb` — `PikuriTui::Chat::Layout`,
  the vertical-split root layout (conversation top, input bottom).
- `lib/pikuri_tui/chat/input.rb` — `PikuriTui::Chat::Input`, the
  `TextArea` subclass that rebinds Enter to submit-and-clear.
- `lib/pikuri_tui/chat/footer_label.rb` —
  `PikuriTui::Chat::FooterLabel`, the conversation-window footer
  label: ticks a spinner while the agent is mid-turn, shows an
  "N queued" count while the agent's `Control::Interloper` holds
  pending mid-turn injections, and renders the main agent's
  context-window snapshot off a
  `Pikuri::Agent::Listener::TokenLog` — claiming the log's
  `on_status_line` observer slot so each fresh line repaints the
  footer the moment the `Tokens` event lands (sub-agent pushes,
  which inherit the observer, are filtered out by their non-empty
  id). Painted in the current
  theme's `hint_color` (the footer is status-hint chrome), read at
  paint time per Tuile's theming rule so OS light/dark appearance
  flips restyle it.
- `lib/pikuri_tui/code.rb` — `PikuriTui::Code` namespace shell for
  the coding front-end, and the home of the duplicate-don't-share
  rationale for the parallel `Code::*` copies.
- `lib/pikuri_tui/code/app.rb` — `PikuriTui::Code::App`, the Tuile
  shell for `bin/pikuri-tui-code`. A parallel copy of `Chat::App`
  that additionally owns a `Code::ConfirmerPopup` and yields it to
  the build block alongside the listener.
- `lib/pikuri_tui/code/layout.rb` / `code/input.rb` /
  `code/footer_label.rb` — parallel copies of the `Chat::`
  equivalents (vertical-split layout, Enter-submits input, footer
  spinner + queued-count + token status).
- `lib/pikuri_tui/code/confirmer_popup.rb` —
  `PikuriTui::Code::ConfirmerPopup`, a `Pikuri::Workspace::Confirmer`
  rendered as a modal Tuile popup instead of stdin. `confirm?` is
  called by the `Write` / `Bash` tools on the agent worker thread; it
  marshals popup construction to the UI thread via
  `screen.event_queue.submit` and blocks the worker on a `Queue`
  until a `y`/`n` (or ESC/`q` decline) resolves it. LLM-supplied
  question/detail pass through `Pikuri::Sanitizer`, whose
  neutralized text + per-attack-class warnings are rendered in the
  popup body (warnings in the `AppTheme` `:notice` tone + bold,
  detail in `:detail`, like `Confirmer::Terminal`).
- `bin/pikuri-tui-chat` — boot script for the chat agent
  (`Bundler.setup(:default)`): configures `RubyLLM` for the local
  llama.cpp server, builds a streaming `Pikuri::Agent` wired with
  the web/calc tools (search, scrape, fetch, calculator), a
  `TokenLog`, a `Control::Interloper` (for mid-turn message
  injection), and a rate-limited `PikuriTui::TuileListener`, hands
  it to `PikuriTui::Chat::App`.
- `bin/pikuri-tui-code` — boot script for the coding agent
  (`Bundler.setup(:default, :code)`): discovers the project root
  (VCS marker) and `chdir`s to it, builds a `Pikuri::Workspace`
  rooted there + a bubblewrap sandbox + skill catalog, then a
  streaming `Pikuri::Agent` wired with the six file/shell tools
  (the `Write` / `Bash` tools taking the `Code::ConfirmerPopup` the
  `App` yields, or `AUTO_APPROVE` under `--no-confirm`/`--yolo`),
  sub-agent-only network tools, and the skill / task / MCP /
  sub-agent extensions. Hands it to `PikuriTui::Code::App`. Ports
  pikuri's own `bin/pikuri-code` demo onto the Tuile shell.
- `bin/setup` — `bundle install` wrapper.
- `bin/install` / `bin/uninstall` — symlink `bin/pikuri-tui-chat`
  and `bin/pikuri-tui-code` into `$PREFIX` (default `~/.local/bin`)
  and remove them again. Uninstall only removes symlinks that point
  back into this checkout.

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
  (pikuri, ruby_llm, Tuile, Faraday, kramdown, rouge, everything we
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
