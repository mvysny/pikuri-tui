# AGENTS.md

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
Tuile UI — conversation pane with streamed Markdown, a diagnostic
log popup, input field, footer spinner + token status —
against a local llama.cpp server, with specs and Woodpecker CI in
place. `bin/pikuri-tui-code` (the `PikuriTui::Code` namespace) is
the in-repo coding shell: the same Tuile UI plus a project-rooted
workspace, the bubblewrap sandbox, the six file/shell tools wired
with a modal y/n confirmer (`Code::ConfirmerPopup`) on writes and
bash, sub-agent-only network tools, the skill / task / MCP /
sub-agent extensions, and a plan-mode toggle (a read-only
posture surfaced as a footer badge) — all ported from pikuri's
`bin/pikuri-code` demo onto the Tuile shell. Both shells route
every command through one leader key (`Ctrl+K` → `LeaderMenu`);
only `Ctrl+C` (cancel/quit) stays a direct shortcut.

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
  both pikuri's and pikuri-tui's per-subsystem loggers, routed
  through `Pikuri.log_io=` (pikuri-tui logs via `Pikuri.logger_for`,
  not `Tuile.logger` — see Conventions), plus any `Tuile`-internal
  noise we still capture through `Tuile.logger`. Never cross the
  streams: the conversation pane is what the user reads; the log
  pane is what we read when something's wrong.

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
  `:user` / `:added` / `:removed`) on top
  of the built-in accents, with one coloring helper per token, plus
  `DARK` / `LIGHT` and the `THEME_DEF` pair the bins install via
  `screen.theme_def=` (and `spec_helper` via `ThemeDef.default=`).
  The single source of truth for every UI accent both shells paint;
  the listener, the apps, and the confirmer read these instead of
  hardcoding Rainbow colors. The markdown body palette
  (`AnsiConverter`) is deliberately left out — it renders content,
  not chrome, and runs screen-agnostically in specs.
- `lib/pikuri_tui/config.rb` — `PikuriTui::Config`, the layered
  TOML configuration both shells load at boot. Resolves the model
  connections (`[[llm]]`), the coding shell's `sandbox` / `confirm`
  switches, and its MCP servers (`[[code.mcp]]`) from the XDG search
  path (`/etc/xdg` → `$XDG_CONFIG_HOME`, deep-merged, arrays replace)
  with CLI overrides on top. Parsed with `tomlrb` (parse-only,
  zero-dep) and validated by hand. References nothing from the
  `:code`-group gems — it is eager-loaded by the chat shell, whose
  `Bundler.setup(:default)` lacks `pikuri-mcp` — so MCP servers
  surface as plain `Config::McpServer` value objects whose field
  names match `Pikuri::Mcp::Registry`'s entries 1:1, and the coding
  bin does the trivial pass-through into `Registry::StdioEntry` /
  `HttpEntry`. Its one `Pikuri` touch is `pikuri-core`'s logging
  facade (in `:default`, so both shells have it): `load` reports each
  config file it reads — and any `chmod 600` loose-permissions advisory —
  through `Pikuri.logger_for('config')`, surfacing on `$stderr` at boot.
  `Config` only *logs*; it no longer collects advisories for the caller to
  replay (there is no `#warnings` reader). The bins install a
  `BufferingLogIO` as the boot `log_io`, so these pre-screen lines are
  retained and replayed into the LogWindow when each bin's `App` rewires
  `Pikuri.log_io`. HTTP MCP auth rides `HttpEntry`'s `headers`: an entry's
  `bearer_token` / `basic_auth` (username+password) conveniences are
  folded into the `headers` hash at load time alongside any raw custom
  `headers`. A stdio entry's `env` table passes straight through to
  `StdioEntry`'s `env` (subprocess environment overrides). An LLM API
  key is stored **literally** in `[[llm]]`'s
  `api_key` (never an env var name, never a CLI flag, and with no
  project-local config layer): the environment is inherited by every
  subprocess pikuri spawns — sandboxed bash, stdio MCP — so a key
  there leaks to agent-run code, whereas this file is parent-only and
  outside the agent's readable tree. `load` logs a non-fatal
  `chmod 600` advisory when a key-bearing file has loose permissions.
  Hosts the built-in defaults (`DEFAULT_SERVER` / `DEFAULT_MODEL` / …)
  the bins show in `--help`.
- `lib/pikuri_tui/tuile_listener.rb` — `PikuriTui::TuileListener`,
  a `Pikuri::Agent::Listener::Base` subclass that renders the
  event stream into a `Tuile::Component::TextView` (the
  conversation pane). The equivalent of pikuri's
  `Pikuri::Agent::Listener::Terminal`, retargeted at the TUI.
  Shared by `Chat::App` and `Code::App`. Tool calls render through an
  injected `tool_formatters` map (tool name → formatter) when one is
  registered, otherwise the default `→ name(args)` / `= result` lines; the
  formatter handling a `ToolCall` is stashed so the paired `ToolResult`
  routes back to it. The chat shell registers none; the coding shell wires
  the `edit` / `write` diff formatters.
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
- `lib/pikuri_tui/model_choice.rb` — `PikuriTui::ModelChoice`, a
  `Data.define(:name, :transport)` pairing a connection's display name
  with the `Pikuri::Agent::ChatTransport` selecting it switches to. Its
  `.from_llm(llm)` factory builds one per `Config#llms` entry — the single
  place the Pikuri seam is crossed (the `Pikuri`-free `Config` value object
  → a connection-bearing transport via `ChatTransport.from_openai_server`,
  with the `nil`/blank-key → `"not-needed"` fallback) so the bins just map
  `config.llms` through it. The connection rides the transport's own
  per-chat `RubyLLM::Context`, so neither bin calls `RubyLLM.configure`. The
  bins hand the list to each shell's `App` as `models:`; the transport is
  opaque to the UI (stashed as pending, forwarded to the next `run_loop`).
- `lib/pikuri_tui/model_listener.rb` — `PikuriTui::ModelListener`, a
  `Pikuri::Agent::Listener::Base` subclass that consumes
  `Pikuri::Agent::Event::ModelSwitched` (emitted at the top of `run_loop`
  when a `transport:` switch lands) and pushes the new model's display
  name onto the conversation footer (`current_model=`, marshaled to the UI
  thread). Shared by both shells; the model switch is surfaced in the
  footer only, never echoed into the transcript, so the footer reflects
  the model the agent is *actually* on. Resolves the raw model id to the
  friendly `ModelChoice#name` via a map the `App` builds.
- `lib/pikuri_tui/counting_log_io.rb` — `PikuriTui::CountingLogIO`,
  the `IO`-shaped sink that forwards every line to the diagnostic
  `LogWindow` and counts error-class writes so the `Ctrl+K` menu
  status-bar hint can flag "something broke." Shared by both
  shells.
- `lib/pikuri_tui/buffering_log_io.rb` — `PikuriTui::BufferingLogIO`,
  the `IO`-shaped sink the bins install as the boot-time `Pikuri.log_io`.
  Tees every pre-screen line to `$stderr` (so a crash before the screen
  still prints) *and* retains it; `#replay_into(sink)` re-feeds the
  retained lines through the `CountingLogIO` once the `App` wires it, so
  config-file reads / `chmod 600` advisories / model-wiring lines that
  only hit `$stderr` at boot land in the `LogWindow` too — error lines
  among them bumping the counter like a live write. Bounded ring buffer
  (oldest drop past the cap, noted on replay). Shared by both shells.
- `lib/pikuri_tui/log_popup.rb` — `PikuriTui::LogPopup`, the
  `Popup` wrapper around the eager `LogWindow` that resets the
  unread-error counter on dismiss. Shared by both shells.
- `lib/pikuri_tui/leader_menu.rb` — `PikuriTui::LeaderMenu`, the
  lazyvim-style "which-key" command menu: a leader shortcut
  (`Ctrl+K`) opens a modal `PickerWindow` popup listing app actions,
  each bound to a single printable follow-up key (`l` logs / `d` git
  diff / `p` plan mode / `m` switch model / `q` quit). One reserved
  unprintable leader key replaces a fistful of per-action global
  shortcuts (and dodges the tmux/flow-control collisions in that
  scarce namespace); the follow-up keys can be printable because the
  popup consumes them directly (`q` quits the app, not the popup —
  `PickerWindow` intercepts option keys before the wrapping `Popup`'s
  `q`-closes handler, while ESC and `Ctrl+C` both cancel the menu via
  a `CancelPopup` subclass — `Ctrl+C` is otherwise suppressed while a
  popup is open, so folding it in makes the universal "get me out"
  key behave like ESC here). Each picked
  callback is deferred via `screen.event_queue.submit` so the menu
  closes before an action that opens its own popup runs. Shared by
  both shells (like `LogPopup`); each `App` registers its own action
  set via the chainable `#add`. This menu plus `Ctrl+C` (cancel/quit
  escalation, the one direct accelerator kept) are the only global
  shortcuts — every other binding lives behind the leader. The
  always-visible `^K` status-bar hint also carries the unread-error
  tally (`^K ⚠ menu (N)`), the role the old `^L` hint played.
- `lib/pikuri_tui/chat.rb` — `PikuriTui::Chat` namespace shell
  for the chat front-end.
- `lib/pikuri_tui/chat/app.rb` — `PikuriTui::Chat::App`, the
  Tuile shell for `bin/pikuri-tui-chat` (conversation `TextView` +
  diagnostic `LogWindow` + input field + status bar). Takes a `models:`
  list (`ModelChoice`s) and yields a `ModelListener` to the build block
  alongside the conversation listener; the `LeaderMenu`'s `m` entry
  (registered only when more than one model is configured) opens a
  `Tuile::Component::PickerWindow` popup whose pick stashes a pending
  `ChatTransport`, applied at the top of the next `run_loop` via its
  `transport:` arg. Builds its `LeaderMenu` (logs / switch model / quit)
  and registers the `Ctrl+K` leader + `Ctrl+C` cancel shortcuts in
  `#register_shortcuts`.
- `lib/pikuri_tui/chat/layout.rb` — `PikuriTui::Chat::Layout`,
  the vertical-split root layout (conversation top, input bottom).
- `lib/pikuri_tui/chat/input.rb` — `PikuriTui::Chat::Input`, the
  `TextArea` subclass that rebinds Enter to submit-and-clear.
- `lib/pikuri_tui/chat/footer_label.rb` —
  `PikuriTui::Chat::FooterLabel`, the conversation-window footer
  label: shows the current model's display name as the leading segment
  (set once to the boot model, then updated by `ModelListener` when a
  model switch lands), ticks a spinner while the agent is mid-turn,
  shows an
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
  that additionally owns a `Code::ConfirmerPopup`, the sidebar task
  + git-change-summary windows, the `Code::GitDiffPopup` (full diff,
  opened from the leader menu's `d` entry) + its `Code::GitWatcher`, a
  `Code::TaskListener`, and a
  `Code::PlanModeListener`, and yields the confirmer, the task listener,
  the `ModelListener`, and the `PlanModeListener` to the build block
  alongside the conversation listener. Forwards a
  `tool_formatters` map (the bin's `edit` / `write` diff formatters) to its
  `TuileListener`. Like `Chat::App` it takes a `models:` list and wires the
  model picker + footer model segment. Its `LeaderMenu` carries the extra
  `d` git diff / `p` plan mode entries on top of the chat set; the
  `p` entry's `#toggle_plan_mode` calls `enter!`/`exit!` on the shared
  `Pikuri::Agent::Control::PlanMode` flag and the footer plan-mode badge
  tracks it via the `PlanModeListener`. The `plan_mode:` control defaults
  to a fresh one (not in plan mode); the host passes the same instance it
  hands `Agent.new` so the menu toggle and the model's enter/exit tools
  flip one flag.
- `lib/pikuri_tui/code/layout.rb` — `PikuriTui::Code::Layout`, the
  coding shell's dual-pane root layout: a 60/40 width split with the
  conversation pane over a fixed-height input strip on the left and
  a full-height sidebar (a fixed `TASK_HEIGHT` task window over the
  git change-summary window) on the right. Collapses the sidebar to zero width
  on terminals too narrow to read it. Diverges from `Chat::Layout`'s
  simple top/bottom split (the coding shell duplicates rather than
  shares — see `code.rb`).
- `lib/pikuri_tui/code/task_listener.rb` —
  `PikuriTui::Code::TaskListener`, a `Pikuri::Agent::Listener::Base`
  subclass that renders the agent's task list into the sidebar task
  window. Consumes the `Pikuri::Tasks::ListChanged` events
  `Pikuri::Tasks::Extension` emits after every mutation (each
  carries a frozen, cross-thread-safe `items` snapshot), rewriting
  the `TextView` last-wins with a status glyph per item toned via
  `AppTheme` (`:notice` for `in_progress`, `:detail` for
  `completed`). The companion to `TuileListener`: same
  worker-thread-to-UI-thread marshaling, a much smaller slice of the
  event stream. Not rate-limited (task mutations are rare).
- `lib/pikuri_tui/code/plan_mode_listener.rb` —
  `PikuriTui::Code::PlanModeListener`, a `Pikuri::Agent::Listener::Base`
  subclass that consumes the `Pikuri::Code::PlanModeChanged` event
  `Pikuri::Code::Extension` re-emits on every real plan-mode transition
  and pushes the new posture onto the footer (`plan_active=`, marshaled to
  the UI thread). Coding-shell-only (not top-level like `ModelListener`):
  the event is a `:code`-group constant and only `Code::FooterLabel` shows
  the badge. Driven off the *event*, not the control, so a model-initiated
  `enter_plan_mode` lights the footer exactly like the leader menu's
  `p` toggle.
- `lib/pikuri_tui/code/git_watcher.rb` —
  `PikuriTui::Code::GitWatcher`, the background poller feeding two views:
  a compact change summary in the sidebar (one `XY path  +N -N` line per
  changed file, from `git status --porcelain` + `--numstat`; each file's
  label toned by kind via `AppTheme` — new green, deleted red, modified
  yellow — and its `+N`/`-N` markers green/red) and the full diff in the
  `GitDiffPopup`. Polls on its own thread every `POLL_INTERVAL`
  seconds and, only when the capture changes, rewrites both `TextView`s
  (marshaled onto the UI thread). The diff is plain (uncolored) `git diff
  HEAD` (tracked, staged + unstaged) plus each untracked file diffed against
  `/dev/null` with `diff --no-index` (a synthetic "new file" diff — surfacing
  brand-new files without `git add -N` mutating the index), rendered through
  `Code::GitDiffRenderer` (both renderings produced in `capture` on the poll
  thread, like the summary's theming). Not a listener — the working tree
  changes without an agent event to subscribe to. Started/stopped by
  `App#run`.
- `lib/pikuri_tui/code/git_diff_popup.rb` —
  `PikuriTui::Code::GitDiffPopup`, the `Tuile::Component::Popup` wrapping
  the long-lived "Git diff" window (the full, scrollable diff `GitWatcher`
  keeps current). Opened near-fullscreen from the leader menu's `d` entry;
  overrides `max_height` to the screen height so the base 12-row cap
  doesn't crop the diff. Same eager-window/reopen pattern as `LogPopup`.
- `lib/pikuri_tui/code/git_diff_renderer.rb` —
  `PikuriTui::Code::GitDiffRenderer`, renders a plain `git diff` into the
  popup's two-tier form by reusing `DiffRenderer`: it parses the
  unified diff into files → hunks and feeds each hunk's reconstructed
  before/after pair to `DiffRenderer` (so the per-line split and
  character-level emphasis are re-derived by LCS, identical to the
  `edit`/`write` tool diffs), assembled as a themed `✎ path` header over dim `@@ line N @@`
  separators. Pads line bars to `min(longest content line, max_width)` so
  they never exceed the pane width (which `TextView` would word-wrap).
  Screen-agnostic like `DiffRenderer` / `DiffToolFormatting` — takes a
  `theme` and a width, renders without a `Tuile::Screen`. Handles
  new/deleted/binary sections (header markers; binary shows a `(binary)`
  note).
- `lib/pikuri_tui/code/input.rb` / `code/footer_label.rb` —
  parallel copies of the `Chat::` equivalents (Enter-submits input,
  footer spinner + queued-count + token status). The coding shell's
  `FooterLabel` additionally leads with a notice-toned "‖ Plan Mode"
  badge (`plan_active=`, driven by `PlanModeListener`) when plan mode is
  active.
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
- `lib/pikuri_tui/code/diff_renderer.rb` —
  `PikuriTui::Code::DiffRenderer`, renders a before/after string pair as a
  two-tier ANSI unified diff for the conversation pane: a full-width dim
  line background per changed line plus a brighter background on the
  characters that actually differ within a modified pair (Claude-Code
  polarity). A modified line stays two continuous lines — the full removed
  line then the full added line, each on its line tier with the changed
  characters in the brighter span tier — rather than an inline merge, so a
  multi-change line stays legible. `-`/`+`/` ` gutter markers survive
  `NO_COLOR`. Line- and character-level alignment via `diff-lcs`
  (`Diff::LCS.sdiff`).
  Screen-agnostic like `MarkdownRenderer::AnsiConverter` — colors come from
  an injected `Palette`, width from a parameter — so it renders and tests
  without a `Tuile::Screen`. Output is built from `Tuile::StyledString`
  spans. Caps long diffs with a `… +N more lines` tail.
- `lib/pikuri_tui/code/diff_tool_formatting.rb` —
  `PikuriTui::Code::DiffToolFormatting`, module functions shared by the
  `edit` / `write` formatters: the call-time diff block (themed header over
  a `DiffRenderer` body, palette read from the theme's four `:diff_*`
  tokens at render time) and the result-time line (`nil` on success — the
  diff already showed the change — a themed `✗ Error: …` line otherwise).
- `lib/pikuri_tui/code/edit_formatter.rb` —
  `PikuriTui::Code::EditFormatter`, the `tool_formatters` entry for `edit`.
  Diffs `old_string` → `new_string` straight from the `ToolCall` arguments
  (self-contained, no file read). Degrades to the default tool-call line
  (returns `nil`) on a rendering failure.
- `lib/pikuri_tui/code/write_formatter.rb` —
  `PikuriTui::Code::WriteFormatter`, the `tool_formatters` entry for
  `write`. Reads the existing file through the captured `filesystem` for the
  diff's "before" side (a missing file renders as an all-added `create`),
  diffing it against `content`. Falls back (`nil`) when the path is
  unreadable, outside the workspace, a directory, or binary.
- `bin/pikuri-tui-chat` — boot script for the chat agent
  (`Bundler.setup(:default)`): maps every `Config#llms` connection to a
  `ModelChoice` (via `ModelChoice.from_llm`) carrying a connection-bearing
  `ChatTransport` (`api_base` / `api_key` on the transport, so a model
  switch can cross servers), builds a
  streaming `Pikuri::Agent` (booted on the first transport) wired with
  the web/calc tools (search, scrape, fetch, calculator), a
  `TokenLog`, a `Control::Interloper` (for mid-turn message
  injection), the `App`-yielded `ModelListener`, and a rate-limited
  `PikuriTui::TuileListener`, hands it to `PikuriTui::Chat::App` (with the
  `models:` list).
- `bin/pikuri-tui-code` — boot script for the coding agent
  (`Bundler.setup(:default, :code)`): discovers the project root
  (VCS marker) and `chdir`s to it, builds a `Pikuri::Workspace`
  rooted there + a bubblewrap sandbox + skill catalog, then a
  streaming `Pikuri::Agent` wired with the six file/shell tools via
  two pikuri extensions: the five read/grep/glob/edit/write file tools
  via `Pikuri::Workspace::Extension` (which wraps the `Filesystem` in
  one shared `Workspace` composite so the read-before-edit gate works
  across them), and `Bash` + the sub-agent-only `git_clone` via
  `Pikuri::Code::Extension` (Bash isn't a read/edit/write tool and
  takes the raw `Filesystem`, not the read record, so it lives in the
  code extension, not the workspace one). Both replace the per-tool
  `add_tool` lines this bin used to repeat. The `Write` / `Bash` tools
  take the `Code::ConfirmerPopup` the `App` yields, or `AUTO_APPROVE`
  under `--no-confirm`/`--yolo`. Also sub-agent-only network tools, and
  the skill / task / MCP / sub-agent extensions. Constructs a shared
  `Pikuri::Agent::Control::PlanMode` and hands it to BOTH `Agent.new`
  (so `Code::Extension` wires the model's `enter_plan_mode`/`exit_plan_mode`
  tools + the `PlanModeChanged` event, and `Edit`/`Write` refuse while
  active) AND `Code::App` (so the leader menu's `p` entry toggles the same
  flag). Wires the
  `App`-yielded `Code::TaskListener`, `ModelListener`, and
  `PlanModeListener` into the agent's `ListenerList` so the
  `Pikuri::Tasks::Extension` list mutations reach the sidebar task pane,
  model switches reach the footer, and plan-mode transitions light the
  footer badge. Builds the `edit` /
  `write` diff formatters (the `write` one over the same `filesystem`)
  and passes them as `Code::App`'s `tool_formatters`. Maps `Config#llms`
  through `ModelChoice.from_llm` to the `models:` list (connection-bearing
  `ChatTransport`s) for the
  leader menu's `m` model picker. Hands it to
  `PikuriTui::Code::App`. Ports pikuri's own `bin/pikuri-code` demo
  onto the Tuile shell.
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
  files don't need it. Exception: the per-class `LOG` logger
  constants (see "Log through pikuri" below) carry no rdoc — the
  declaration is self-explanatory.
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
  `'listener'`, `'git'`, `'log'`, `'config'`, and `'chat'` / `'code'`
  for the two `App`s. The bins are plain scripts, not classes, so when one
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
  buffer is up), so the bins install a `BufferingLogIO` as the boot
  `log_io` that tees to `$stderr` and retains them; `App#wire_logging`
  replays the retained lines into the LogWindow right after the swap.
  `Tuile.logger` defaults to `IO::NULL` (dropped until
  wired) and is a single untagged logger, so it's reserved for one job:
  `App` still assigns `Tuile.logger = Logger.new(io)` to capture
  `Tuile`'s *own* internal noise into the same LogWindow. The
  conversation pane (`TextView`, driven by `PikuriTui::TuileListener`)
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
- **Namespacing direction.** Everything we ship lives under the
  `PikuriTui::` namespace at the path Zeitwerk expects
  (`lib/pikuri_tui/foo/bar.rb` → `PikuriTui::Foo::Bar`). Don't
  introduce top-level constants.
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
