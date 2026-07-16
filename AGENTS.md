# AGENTS.md

## What this project is

A trio of Tuile-based TUI front-ends on a shared core, wrapping the
[pikuri](https://codeberg.org/mvysny/pikuri) library:
`bin/pikuri-tui-chat` (general-purpose chat), `bin/pikuri-tui-code`
(in-repo coding agent), and `bin/pikuri-tui-computer` (desktop
assistant for this machine: the OS helper + local Thunderbird mail /
calendar). All three bind the same
`Pikuri::Agent` and the same `Pikuri::Tool` set as pikuri's own demo
scripts; they differ only in their system prompt and which tools they
register.

Pikuri ships those wirings as plain stdin/stdout REPL demos in its
own `bin/`. This project replaces the REPL with a Tuile component
tree — a conversation pane (the LLM-stream transcript), a log pane
(internal diagnostics), an input field, a status bar — and reuses
pikuri unchanged otherwise. All LLM transport, tool execution,
agent loop control, prompts: that's all pikuri. We own the UI
shell only.

## Status

All three shells are functional. `bin/pikuri-tui-chat` runs the full
Tuile UI — conversation pane with streamed Markdown, a diagnostic
log popup, input field, footer spinner + token status —
against a local llama.cpp server, with specs and Woodpecker CI in
place. `bin/pikuri-tui-code` (the `Code` namespace) is
the in-repo coding shell: the same Tuile UI plus a project-rooted
workspace, the bubblewrap sandbox, the six file/shell tools wired
with a modal y/n confirmer (`Code::ConfirmerPopup`) on writes and
bash (provably read-only bash commands auto-approve via pikuri's
`Code::Bash::ReadOnlyAutoConfirmer`, leaving the popup for mutations;
read-only git additionally auto-approves once the user affirms a
one-time, persisted git-config trust prompt — `Code::TrustStore`),
sub-agent-only network tools, the skill / task / MCP /
sub-agent extensions, and a plan-mode toggle (a read-only
posture surfaced as a footer badge) — all ported from pikuri's
`bin/pikuri-code` demo onto the Tuile shell. `bin/pikuri-tui-computer`
(the `Computer` namespace) is the desktop assistant: the
chat shell's layout (one conversation pane over an input strip, no
sidebar — no git or task window) carrying the coding shell's safety
machinery, composing two pikuri surfaces. `Pikuri::Os::Extension`
brings the OS helper (the five file tools + a network-severed
`FullFsNoNet`-sandboxed `bash` + the machine-facts / MACHINE.md
system-prompt sections); `Pikuri::Thunderbird::Extension` brings local
mail + calendar (search/read + two human-gated outbound hand-offs —
compose a reply, add an event — that the user Sends/confirms in
Thunderbird's own UI, so they need no confirmer here). This is pikuri's
"reassembled trifecta" (whole disk + attacker-authorable email +
egress), every egress leg human-gated. Web research is on by default
but quarantined: the web tools (`web_search` / `web_scrape` / `fetch`)
are registered sub-agent-only, so the main agent holds no direct egress
and delegates via the `agent` tool to an isolated
`Pikuri::SubAgent::RESEARCHER` (web tools, no filesystem), with the
`Code::ConfirmerPopup` gating each research task before it runs;
`--no-internet` drops the researcher. It owns a `Code::ConfirmerPopup`
on writes/bash, surfaces plan mode (footer badge + leader `p` toggle),
and renders `edit` / `write` diffs — all reusing the coding shell's
`Code::*` adapters verbatim, ported from pikuri's
`pikuri-os/bin/pikuri-computer` demo. All three shells route every
command through one leader key (`Ctrl+K` → `Shared::LeaderMenu`); only
`Ctrl+C` (cancel/quit) stays a direct shortcut.

The three shells keep their genuinely-divergent scaffolding (`App` /
`Layout`) as deliberate parallel copies, not a common base (see
`lib/code.rb` and `lib/computer.rb`; the computer shell
additionally reuses the `Code::*` confirmer / diff adapters directly).
The pieces that carried no divergence are shared top-level components
instead: the Enter-submits input (`Shared::InputWindow`) and the
conversation-window footer updater (`Shared::StatusFooterUpdater`) — the footer's
only cross-shell difference, chat's lack of a plan-mode badge, collapses
to chat simply never calling `Shared::StatusFooterUpdater#plan_active=`. Their dependencies are
split across Bundler groups: `bin/pikuri-tui-chat` runs
`Bundler.setup(:default)`, `bin/pikuri-tui-code` runs
`Bundler.setup(:default, :code)`, and `bin/pikuri-tui-computer` runs
`Bundler.setup(:default, :computer)` — so the heavier gems stay off the
chat process's load path, and the coding-only gems
(tasks/skills/mcp) stay off the computer process's. The shared
heavier gems (`pikuri-workspace`/`pikuri-code`/`diff-lcs`/`pikuri-subagents`)
sit in both `:code` and `:computer` via `groups:` (the coding shell spawns
several personas, the computer shell the RESEARCHER for web research);
`pikuri-os` and `pikuri-thunderbird` are `:computer`-only.
`lib/pikuri_tui.rb` ignores both the `Code` and
`Computer` subtrees entirely when the heavier gems aren't
loaded (gated on `Pikuri::Workspace` — the computer subtree reuses the
`Code::*` adapters and needs the same gems).

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
  both pikuri's and pikuri-tui's per-subsystem loggers, routed
  through `Pikuri.log_io=` (pikuri-tui logs via `Pikuri.logger_for`,
  not `Tuile.logger` — see Conventions), plus any `Tuile`-internal
  noise we still capture through `Tuile.logger`. Never cross the
  streams: the conversation pane is what the user reads; the log
  pane is what we read when something's wrong.

- **Design with components (COP); let each component's
  responsibility decide what it touches.** Follow
  [component-oriented programming](https://mvysny.github.io/component-oriented-programming/):
  every component is a cohesive box with a single responsibility and
  a minimal API, taking what it needs through its own constructor /
  setters / listeners and surfacing interactions for callers to
  consume (a `Button` exposes clicks; a `PersonForm` owns its fields,
  validation, and save). Whether a component references `Pikuri::*`
  is not a constraint we impose from outside — it falls out of what
  the component is *for*. A conversation window that renders the
  agent's event stream, the `Shared::StatusFooterUpdater` footer, the
  `Code::ConfirmerPopup`, and the `Shared::Model::*` adapters all
  legitimately own their Pikuri wiring (build their own listener,
  register their own confirmer); a pure layout container like
  `Chat::Layout` simply never needs it. There is no "keep Pikuri out
  of the components" rule and no preference for Pikuri-free ones —
  only "is this component well-designed?" Extract a component into
  `Shared::` (or `Code::*`) when reuse earns it, whether or not it
  touches Pikuri. The general shape (the composition-over-inheritance UI
  carve-out, the model/view sizing seam, the render-verb seam) lives in the
  `cop` skill and the two posts it cites; the Tuile mechanics live in the
  `tuile` skill. Live exemplars: `Shared::ConversationWindow` /
  `ConversationTextView` (widget owns rendering, thin nested `Listener`) is
  the big-nested case; `Code::GitWatcher` feeding two panes is the
  shared-injected case.

- **The threading rule.** Tuile is single-threaded: every UI
  mutation (`rect=`, `content=`, `add_line`, `invalidate`,
  `screen.focused=`) must run on the thread that owns
  `Screen#run_event_loop`. The agent loop blocks on the LLM and
  must NOT run on that thread, so it goes on a worker. The worker
  marshals every render back via
  `screen.event_queue.submit { … }`. This is non-negotiable: most
  Tuile UI methods raise `"UI lock not held"` if you violate it,
  and the ones that don't will silently corrupt the repaint set.
  In class rdoc, **the UI thread** names exactly this thread — the one
  that owns `Screen#run_event_loop` — and a class whose every method must
  run on it is tagged `UI-thread-confined` (per the global CLAUDE.md
  thread-safety rule), with any off-thread-safe exceptions marked on the
  methods themselves. This is the project-specific definition that rule's
  `<Role>-thread-confined` tag defers to; everything else about
  thread-safety (the mutable/not-thread-safe default, the vocabulary) is
  global and lives there, not here.

- **Multi-window layouts beyond log + input — out of scope until
  there's a concrete need.** (Streaming and mid-loop input used
  to sit on this list; both have since landed. The chat agent
  runs with `streaming: true` and deltas reach the listener
  through a 15 fps `Listener::RateLimited` coalescer into
  `Shared::Markdown::StreamingBuffer`. Mid-loop input rides pikuri's
  `Control::Interloper`: Enter during a running turn injects into
  the agent's queue — drained at the next tool-result boundary
  and echoed by the listener as a `mid_loop:` `UserTurn` — the
  conversation footer shows an "N queued" count while injections
  are pending, and anything still queued when the turn ends is
  delivered as a fresh turn by `Chat::App`.)

## Layout

Per-file rationale lives in each source file's YARD header (or, for the
`bin/` scripts, their inline comments) — this is the package map: one-line
pointers, not a second copy of the docs. This is an end app, not a library,
so it carries **no umbrella namespace**: `lib/` itself is the Zeitwerk
root and every file maps to a top-level constant — the three shells (`Chat`,
`Code`, `Computer`) and the shared toolkit (`Shared::…`). `lib/pikuri_tui.rb` boots
Zeitwerk over `lib/` and eager-loads it.

- `lib/pikuri_tui.rb` — Zeitwerk loader (root `lib/`, so files map to
  top-level constants) + eager-load; one require for callers. Lives inside
  the root and excludes itself via `loader.ignore(__FILE__)`; its basename is
  only the `require 'pikuri_tui'` target, not a namespace (no `PikuriTui`
  constant exists).
- `Shared` — namespace (implicit — no `lib/shared.rb`, autovivified
  from `lib/shared/`) for the building blocks reused across all three
  shells, as opposed to each shell's own deliberately-duplicated `App` /
  `Layout` scaffolding — and as distinct from the `Code::*` adapters the
  computer shell also reuses. Grouped by subsystem below.
- `lib/shared/app_theme.rb` — `Shared::AppTheme`, the
  `Tuile::Theme` subclass carrying the app's accent tokens; single
  source of truth for every UI accent all three shells paint.
- `lib/shared/config.rb` — `Shared::Config`, the layered
  XDG-path TOML config all three shells load at boot (connections,
  sandbox/confirm switches, MCP servers), CLI overrides on top,
  hand-validated.
- `lib/shared/conversation_text_view.rb` — `Shared::ConversationTextView`,
  the `Tuile::Component::TextView` subclass that owns the vocabulary for
  rendering an agent conversation (blocks, streaming buffers, Markdown /
  grayscale, tool formatters) plus a nested
  `Shared::ConversationTextView::Listener` (a `Pikuri::Agent::Listener::Base`)
  that translates the event stream into those render calls. The COP
  inversion of the old listener-owns-rendering shape: the widget owns "how
  a conversation is drawn," the listener is a thin event→verb adapter that
  holds the per-stream state and mints indented siblings for sub-agents.
  Shared by all three shells.
- `Shared::Markdown` — namespace (implicit — no `lib/shared/markdown.rb`,
  autovivified from `lib/shared/markdown/`) for the Markdown → ANSI
  rendering path (renderer over converter, the in-place streaming buffers,
  the thinking-pane grayscale recolorizer).
- `lib/shared/markdown/renderer.rb` —
  `Shared::Markdown::Renderer`, the single entry point turning
  Markdown into ANSI for the conversation pane (kramdown GFM →
  `Shared::Markdown::AnsiConverter`).
- `lib/shared/markdown/ansi_converter.rb` —
  `Shared::Markdown::AnsiConverter`, the in-house
  `Kramdown::Converter::Base` subclass rendering parse tree to ANSI;
  honors `NO_COLOR`.
- `lib/shared/markdown/streaming_buffer.rb` —
  `Shared::Markdown::StreamingBuffer`, buffer rewriting a
  `TextView::Region` in place from Markdown deltas; must be driven
  from the UI thread.
- `lib/shared/markdown/passthrough_buffer.rb` —
  `Shared::Markdown::PassthroughBuffer`, the render-free
  `Shared::Markdown::StreamingBuffer` variant for streams already in display
  form.
- `lib/shared/markdown/grayscale.rb` — `Shared::Markdown::Grayscale`,
  repaints ANSI as one muted fg with structure preserved, for the
  thinking-pane path.
- `Shared::Model` — namespace (implicit — no `lib/shared/model.rb`,
  autovivified from `lib/shared/model/`) for the model-switch subsystem
  (the connection/transport value object, the leader-menu picker). The
  `ModelSwitched`→footer listener that once lived here is now the footer's
  own `Shared::StatusFooterUpdater#on_event` (see that entry).
- `lib/shared/model/choice.rb` — `Shared::Model::Choice`, a
  `Data.define` pairing a connection's display name with its
  `ChatTransport`; the one place the Pikuri seam is crossed for model
  switching.
- `lib/shared/model/picker.rb` — `Shared::Model::Picker`, the shared
  leader-menu model-switch picker (connection catalog, name map, pending
  switch, `PickerWindow` popup) all three shells compose.
- `Shared::Log` — namespace (implicit — no `lib/shared/log.rb`,
  autovivified from `lib/shared/log/`) for the diagnostic-log subsystem
  (the eager `LogWindow`, its popup, the IO sinks).
- `lib/shared/log/counting_io.rb` — `Shared::Log::CountingIO`,
  the `IO`-shaped sink forwarding lines to the diagnostic `LogWindow`
  and counting error-class writes for the `Ctrl+K` hint. Shared by all
  three shells.
- `lib/shared/log/buffering_io.rb` — `Shared::Log::BufferingIO`,
  the boot-time `Pikuri.log_io` sink that tees pre-screen lines to
  `$stderr` and retains them for `#replay_into` the `LogWindow`. Shared
  by all three shells.
- `lib/shared/log/popup.rb` — `Shared::Log::Popup`, the `Popup`
  wrapper around the eager `LogWindow` that resets the unread-error
  counter on dismiss. Shared by all three shells.
- `lib/shared/log/ui.rb` — `Shared::Log::UI`, the diagnostic-log
  subsystem shared by all three shells: it owns the eager `LogWindow`,
  its `Shared::Log::Popup`, the `Shared::Log::CountingIO` wiring (`#wire!` — the
  former per-`App` `wire_logging`, incl. the `Shared::Log::BufferingIO` boot-line
  replay), the unread-error tally, and the `Ctrl+K` leader shortcut whose
  status-bar hint carries that tally. The `Ctrl+K` registration lives here
  (not in each `App`'s `register_shortcuts`, which keeps the shell-agnostic
  `Ctrl+C`) because the tally is surfaced only through that hint and
  `Tuile::Screen` refreshes a hint by re-registering — so bumping the
  counter and refreshing the hint are one act. Each `App` supplies only
  *what* `Ctrl+K` does via `#install_shortcut { @leader_menu.open }`, and
  drives the two phases: `#wire!` early (before the agent is built),
  `#install_shortcut` late (once the leader menu exists). Extracted from
  the byte-identical `wire_logging` / `menu_hint` / error-counter cluster
  the three `App`s each used to carry.
- `lib/shared/leader_menu.rb` — `Shared::LeaderMenu`, the
  lazyvim-style which-key command menu: `Ctrl+K` opens a modal
  `PickerWindow` of app actions, each on one follow-up key. Shared by
  all three shells; each `App` registers its own action set.
- `lib/shared/input_window.rb` — `Shared::InputWindow`, the `Window`
  captioned "Prompt" framing a private nested `TextArea` subclass that
  rebinds Enter to submit-and-clear (blank buffers are a no-op); the host
  focuses the window and Tuile's content-focus cascade lands the caret on
  the area. Shared by all three shells.
- `lib/shared/status_footer_updater.rb` — `Shared::StatusFooterUpdater`, the
  presenter that keeps the conversation window's footer chrome current
  (it drives `Window#footer_text`; it is not itself a widget), shared by
  all three shells: model name, mid-turn spinner, queued-injection count,
  token snapshot, and a plan-mode badge. Also duck-types as an agent
  listener — its `#on_event` catches `ModelSwitched` and re-points the
  footer's model name — so the footer goes straight into the agent's
  `ListenerList` (no separate listener object; `#current_model=` owns the
  transport→display-name resolution the picker's name map feeds).
- `lib/shared/conversation_window.rb` — `Shared::ConversationWindow`, the
  conversation transcript as one cohesive `Tuile::Component::Window`
  subclass shared by all three shells: frames a `Shared::ConversationTextView`
  (which owns its own transcript listener) and carries a
  `Shared::StatusFooterUpdater` footer that itself doubles as the
  `ModelSwitched` listener. Exposes `#listener` (the transcript) /
  `#status_footer_updater` (the footer) for the host to compose into the
  agent's `ListenerList`. The COP domain component that collapsed the
  conversation-pane wiring each `App` used to hand-assemble.
- `Chat` — namespace (implicit — no `lib/chat.rb`, autovivified from
  `lib/chat/`) for the chat front-end (`Chat::App` + `Chat::Layout`); the
  baseline shell the `Code` / `Computer` siblings were copied from.
- `lib/chat/app.rb` — `Chat::App`, the Tuile
  shell for `bin/pikuri-tui-chat` (conversation `TextView` + diagnostic
  `LogWindow` + input + status bar); takes a `models:` list and wires
  the `Shared::LeaderMenu` and shortcuts.
- `lib/chat/layout.rb` — `Chat::Layout`,
  the vertical-split root layout (conversation top, input bottom).
- `lib/code.rb` — `Code`, namespace for the
  coding front-end; home of the duplicate-don't-share rationale for the
  parallel `Code::*` copies.
- `lib/code/app.rb` — `Code::App`, the Tuile
  shell for `bin/pikuri-tui-code`; like `Chat::App` but adds the
  `Code::ConfirmerPopup`, task + git sidebar, `Code::GitDiffPopup`, and
  plan-mode toggle.
- `lib/code/layout.rb` — `Code::Layout`, the
  coding shell's dual-pane root: a 60/40 conversation-over-input left
  column beside a task + git sidebar (collapsed when too narrow).
- `lib/code/task_list_window.rb` —
  `Code::TaskListWindow`, the sidebar task pane: a `Window` framing a
  `Code::TaskListTextView`; exposes `#listener` (the view's) for the
  agent's `ListenerList`. The frame-over-view sibling of
  `Shared::ConversationWindow` ↔ `Shared::ConversationTextView`.
- `lib/code/task_list_text_view.rb` —
  `Code::TaskListTextView`, the `TextView` subclass that owns how a task
  list is drawn (glyphs, placeholder, per-status tone) via the `#items=`
  verb, plus a nested `Listener` (a `Pikuri::Agent::Listener::Base`)
  translating the `Pikuri::Tasks::ListChanged` stream into `#items=` calls.
- `lib/code/plan_mode_listener.rb` —
  `Code::PlanModeListener`, a `Pikuri::Agent::Listener::Base`
  driving the footer plan-mode badge off `Pikuri::Code::PlanModeChanged`;
  coding/OS-shell-only.
- `lib/code/git_watcher.rb` —
  `Code::GitWatcher`, the background git poller feeding the
  sidebar change summary and the `GitDiffPopup`'s full diff.
- `lib/code/git_diff_popup.rb` —
  `Code::GitDiffPopup`, the fullscreen `Popup` wrapping the
  long-lived Git diff window `GitWatcher` keeps current; opened from the
  leader menu's `d` entry.
- `lib/code/git_diff_renderer.rb` —
  `Code::GitDiffRenderer`, renders a plain `git diff` into
  `DiffRenderer`'s two-tier inline form so the popup matches the
  `edit`/`write` tool diffs.
- `lib/code/confirmer_popup.rb` —
  `Code::ConfirmerPopup`, a `Pikuri::Workspace::Confirmer`
  rendered as a modal Tuile popup instead of stdin; gates the
  `Write` / `Bash` / `agent` tools with approve / edit / reject.
- `lib/code/trust_store.rb` —
  `Code::TrustStore`, the persisted set of git-config-trusted
  project roots that gate read-only-git auto-approval; asked at most once
  per project.
- `lib/code/diff_renderer.rb` —
  `Code::DiffRenderer`, renders a before/after string pair as
  a two-tier ANSI unified diff for the conversation pane; screen-agnostic,
  `diff-lcs`-aligned.
- `lib/code/diff_tool_formatting.rb` —
  `Code::DiffToolFormatting`, module functions shared by the
  `edit` / `write` formatters: the call-time diff block and the
  result-time error line.
- `lib/code/edit_formatter.rb` —
  `Code::EditFormatter`, the `tool_formatters` entry for
  `edit`; diffs `old_string` → `new_string` straight from the `ToolCall`
  arguments, no file read.
- `lib/code/write_formatter.rb` —
  `Code::WriteFormatter`, the `tool_formatters` entry for
  `write`; diffs the on-disk file (read via `filesystem`) against
  `content`, falling back when unreadable.
- `lib/computer.rb` — `Computer`, namespace for the
  desktop-assistant front-end (OS helper + local Thunderbird mail /
  calendar); home of the duplicate-only-the-shell rationale
  (copies `Computer::App` / `Computer::Layout`, reuses the `Code::*` adapters).
- `lib/computer/app.rb` — `Computer::App`, the Tuile shell for
  `bin/pikuri-tui-computer`; laid out like `Chat::App` (no sidebar) but carrying
  the coding shell's safety machinery (confirmer, plan mode, diff
  formatters). The bin wires both `Pikuri::Os::Extension` and
  `Pikuri::Thunderbird::Extension`.
- `lib/computer/layout.rb` — `Computer::Layout`, a parallel copy
  of `Chat::Layout` (vertical split: conversation top, fixed-height input
  strip bottom, no sidebar).
- `bin/pikuri-tui-chat` — boot script for the chat agent
  (`Bundler.setup(:default)`): wires a streaming `Pikuri::Agent`
  (web/calc tools) onto `Chat::App`. Ports pikuri's chat demo.
- `bin/pikuri-tui-code` — boot script for the coding agent
  (`Bundler.setup(:default, :code)`): discovers the project root, builds
  the workspace + sandbox + six file/shell tools (with the confirmer /
  trust / plan-mode wiring), and hands them to `Code::App`. Ports
  pikuri's `bin/pikuri-code` demo.
- `bin/pikuri-tui-computer` — boot script for the desktop assistant
  (`Bundler.setup(:default, :computer)`): builds the full-fs, network-severed
  sandbox + `Pikuri::Os::Extension` + `Pikuri::Thunderbird::Extension` (mail /
  calendar, both outbound hand-offs) + a quarantined web RESEARCHER onto
  `Computer::App`. Ports pikuri's `pikuri-os/bin/pikuri-computer` demo.
- `bin/setup` — `bundle install` wrapper.
- `bin/install` / `bin/uninstall` — symlink `bin/pikuri-tui-chat`,
  `bin/pikuri-tui-code` and `bin/pikuri-tui-computer` into `$PREFIX` (default
  `~/.local/bin`) and remove them again. Uninstall only removes symlinks
  that point back into this checkout.

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
  files don't need it. Exception: the per-class `LOG` logger
  constants (see "Log through pikuri" below) carry no rdoc — the
  declaration is self-explanatory. Exception: a **namespace-only
  module** — one that holds no methods or constants of its own, only
  serving as the parent of the files beneath it — needs no doc *and no
  file*; leave it as a Zeitwerk implicit namespace (autovivified from
  the directory) and let this package map be its sole description.
  Add an explicit `foo.rb` back only when the module gains real content
  (constants, methods) or carries design rationale that belongs next to
  the code rather than in this map — as `code.rb` / `os.rb` do for the
  duplicate-don't-share rationale.
- **Bundler.** Entry-point scripts in `bin/` self-bootstrap via
  `require 'bundler/setup'` so callers don't need the
  `bundle exec` ceremony. Pin the `BUNDLE_GEMFILE` to this
  project's Gemfile via `__dir__` so the scripts work when
  symlinked into `~/.local/bin/`.
- **Log through pikuri, not `Tuile.logger`.** Emit every pikuri-tui
  log line through a named pikuri logger —
  `Pikuri.logger_for('<subsystem>')` — never `Tuile.logger`. Each
  logging class/module stores its logger as a private constant, the
  Ruby form of Java's `private static final Logger log = …`: one
  per class, created once, not per instance:

  ```ruby
  LOG = Pikuri.logger_for('git')
  private_constant :LOG
  # ... LOG.error("git poll failed: …")
  ```

  These `LOG` constants are exempt from the YARD rule above — no rdoc
  on them, the one line speaks for itself. Use a short subsystem tag
  (several classes may share one — `Pikuri.logger_for` memoizes per
  name, so they share the `Logger` object): `'markdown'` (renderer /
  grayscale / streaming buffer), `'formatter'` (edit / write), plus
  `'listener'`, `'git'`, `'log'`, `'config'`, and `'chat'` / `'code'` /
  `'computer'` for the three `App`s. The bins are plain scripts, not classes, so when one
  needs to log it keeps a local (`main_log = Pikuri.logger_for('main')` —
  the coding bin does, for project-root / skill / safety notices).

  Why pikuri and not `Tuile.logger`: pikuri's `Pikuri.log_io` defaults
  to `$stderr`, so a logger works from the first line of boot, *before*
  any screen exists (a `LOG` constant built at class-load time logs
  fine); `Pikuri.log_io=` rewires every logger already handed out in
  one shot, so when each bin's `App` points it at the
  `Tuile::Component::LogWindow::IO` the whole stream — including loggers
  created earlier at stderr — follows to the diagnostic pane for every
  *subsequent* line with no per-logger rewiring. Lines emitted *before*
  that swap only ever hit `$stderr` (invisible once the alternate screen
  buffer is up), so the bins install a `Shared::Log::BufferingIO` as the boot
  `log_io` that tees to `$stderr` and retains them; the `App`'s `Shared::Log::UI#wire!`
  replays the retained lines into the LogWindow right after the swap.
  `Tuile.logger` defaults to `IO::NULL` (dropped until
  wired) and is a single untagged logger, so it's reserved for one job:
  `Shared::Log::UI#wire!` still assigns `Tuile.logger = Logger.new(io)` to capture
  `Tuile`'s *own* internal noise into the same LogWindow. The
  conversation pane (`Shared::ConversationTextView`, driven by its
  `Shared::ConversationTextView::Listener`)
  is for the LLM stream — assistant Markdown, reasoning, tool calls,
  observations — and is not a log sink; never write log lines into it.
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
- **Namespacing direction.** No umbrella namespace — this is an
  end app, not a library, so files map to top-level constants at
  the path Zeitwerk expects (`lib/shared/log/ui.rb` →
  `Shared::Log::UI`, `lib/chat/app.rb` → `Chat::App`).
  Reusable building blocks go under `Shared::` (grouped by
  subsystem — `Shared::Log` / `Shared::Model` / `Shared::Markdown`,
  or directly under `Shared` when standalone); shell-specific code
  goes under its shell namespace (`Chat` / `Code` / `Computer`). Don't
  add a bare top-level constant outside those homes.
- **Widget-class suffix on Tuile subclasses/wrappers only.** A class
  that extends or wraps a Tuile component carries that component's
  class as its name suffix, so the primitive it's built on is
  legible at the reference site: `Shared::InputWindow` (a `Window`),
  `Shared::Log::Popup` / `GitDiffPopup` (both `Popup`s), `LogWindow` /
  `PickerWindow` (both `Window`s). Name the prefix for what the
  component *does*, never for the slot it sits in — `Shared::InputWindow`
  (what it does), not `BottomWindow` (where it sits). A class that is
  *not* a Tuile subclass or wrapper takes no widget suffix at all:
  `Shared::StatusFooterUpdater` is a presenter — it drives a
  `Window`'s `footer_text` but owns no widget of its own — so it gets a
  plain agent-noun name in the `GitWatcher` / `GitDiffRenderer` /
  `*Listener` family, and would have been actively misleading as a
  `*Label` (there is no `Label` there). "Footer" in its name is its
  contract — the border chrome it keeps current — not an incidental
  slot.
- **Tests: rspec-core with minitest-style asserts.** Use the
  `rspec-core` runner (`describe`/`it`) but write assertions in
  the minitest style (`assert_equal`, `assert`, `refute`, …)
  rather than RSpec matchers. Same convention as pikuri — keeps
  the two codebases readable side-by-side.
- **Run the suite with `bundle exec rspec`.** Always go through
  Bundler — never plain `rspec`. Sometimes during the development, the pikuri gems are local path
  dependencies (`../pikuri/*`), and `spec_helper` pulls in the
  whole `:code` group; only the Bundler environment puts those
  paths on the load path. Plain `rspec` fails on the first path-only
  gem (`require 'pikuri-mcp'`) and, where stale system-installed
  pikuri gems exist, silently tests against those instead of the
  local checkout.

## Working on this codebase

- **Read the `cop` and `tuile` skills before writing or
  refactoring any UI component here.** This is a component-oriented Tuile
  app; those two skills carry the architecture (`cop` = the general
  component/model-view/render-verb rules and the composition-over-inheritance
  UI carve-out; `tuile` = the single-threaded event loop, extension points, naming, and
  the mandatory UI-thread rendering rule). Not conditional — nearly every
  task here is UI work.

- **Ideas live in `ideas/*.md`, then evaporate.** A new idea — a
  refactor, a feature, a design worth chewing on before touching code —
  gets its own markdown file under `ideas/` and is brainstormed *there*:
  the problem, the sketch, open questions, decisions as they settle. The
  file is scratch space, not documentation; it may be messy and is not
  held to the doc rules the rest of the tree follows. Once the idea is
  implemented, **delete the file** — but first propagate its durable
  nuggets to where they belong: a contract or gotcha into the relevant
  class rdoc, a package-map line into this file's Layout section, a
  cross-cutting rule into Conventions / Scope decisions. `ideas/` holds
  only *pending* thinking; anything worth keeping after the work lands
  moves to a durable home, and the transient container disappears.
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
- **Dedup by extracting reusable building blocks, not by sharing
  app scaffolding.** This is component-oriented programming: the
  three shells' final composition (`App` / `Layout`) stays as
  deliberate parallel copies — we never fold them into a common
  base or a shared "generic App" — but everything *smaller* that
  they compose out of is a candidate for extraction. When the same
  UI component, listener, adapter, or well-defined standalone class
  appears in more than one shell, extract it once into the
  `Shared::` namespace (or `Code::*` when it's coding-family) and
  reuse it — that is how we kill duplication. The building blocks
  already living this way: `Shared::InputWindow`,
  `Shared::StatusFooterUpdater`,
  `Shared::ConversationWindow`,
  `Shared::LeaderMenu`, `Shared::Log::Popup`, `Shared::Log::UI`, `Shared::Log::CountingIO`, `Shared::Model::Choice`, and
  the `Code::*` confirmer / diff classes the computer shell reuses verbatim.
  The test for extraction is not "is it a widget" but "does this
  piece stand alone with a clear contract and carry no
  shell-specific divergence?" — if yes, it belongs in a shared
  block; a triplicated field or method across the three `App`s is
  the signal that a block is waiting to be pulled out. Only the
  genuinely-divergent scaffolding that wires those blocks together
  stays duplicated (see the `code.rb` / `os.rb` rationale).
- **Grow by adding components and listener variants, not by
  complicating the layout.** New UI surface should land as a new
  Tuile component composition or a new
  `Pikuri::Agent::Listener::Base` subclass with its own specs;
  neither `Chat::App` nor the bin scripts should need
  to grow.
- **Readable, not obfuscated.** Prefer the simplest
  implementation that does the job. The audit-it-in-an-evening
  ceiling that pikuri sets for itself applies here too: this
  project is a thin shell, and every abstraction layer added "in
  case" loses every argument against concrete code.
