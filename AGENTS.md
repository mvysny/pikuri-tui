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
bash (provably passive bash commands auto-approve via pikuri's
`Pikuri::Code::Bash::PassiveCommandDetector`, leaving the popup for mutations;
read-only git additionally auto-approves once the user affirms a
one-time, persisted git-config trust prompt — `Code::TrustStore`),
sub-agent-only network tools, the skill / command / task / MCP /
sub-agent extensions, a plan-mode toggle (a read-only
posture surfaced as a footer badge), and a second one-time,
persisted startup question — does this project hold anything you'd
mind leaking? (`Code::PrivacyStore`) — whose answer sets the
workspace's `private:` and so the private leg of the `/trifecta`
report — all ported from pikuri's
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
`Ctrl+C` (cancel/quit) stays a direct shortcut. All three also carry
`/trifecta`, which echoes pikuri's own lethal-trifecta report for the
running wiring (`Shared::TrifectaRenderer`) — the one built-in slash command
with no leader-menu counterpart, since it is a read-it-when-you-wonder
diagnostic rather than an action. The coding and computer shells additionally
list pikuri's on-disk `/name` prompt templates (`.pikuri/commands` /
`.claude/commands`, via `Shared::FileCommands`), and the coding shell one
`/<skill-name>` per skill currently in play.

The three shells keep their genuinely-divergent scaffolding (`App` /
`Layout`) as deliberate parallel copies, not a common base (see
`lib/code.rb` and `lib/computer.rb`; the computer shell
additionally reuses the `Code::*` confirmer / diff adapters directly).
The pieces that carried no divergence are shared top-level components
instead: the Enter-submits input (`Shared::InputWindow`), the
conversation-window footer updater (`Shared::StatusFooterUpdater`) — the footer's
only cross-shell difference, chat's lack of a plan-mode badge, collapses
to chat simply never calling `Shared::StatusFooterUpdater#plan_active=` — and the
turn-lifecycle engine (`Shared::AgentSession`, the worker thread + mid-turn
injection + spinner + `Ctrl+C` escalation each `App` used to carry byte-identically). Their dependencies are
split across Bundler groups: `bin/pikuri-tui-chat` runs
`Bundler.setup(:default)`, `bin/pikuri-tui-code` runs
`Bundler.setup(:default, :code)`, and `bin/pikuri-tui-computer` runs
`Bundler.setup(:default, :computer)` — so the heavier gems stay off the
chat process's load path, and the coding-only gems
(tasks/mcp) stay off the computer process's. The shared
heavier gems (`pikuri-workspace`/`pikuri-code`/`diff-lcs`/`pikuri-subagents`/
`pikuri-skills`)
sit in both `:code` and `:computer` via `groups:` (the coding shell spawns
several personas, the computer shell the RESEARCHER for web research;
`pikuri-skills` carries two surfaces on one scan, and the computer shell wires
only the `Pikuri::Command::Registry` half — no skill catalog);
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
  carve-out, the model/view sizing seam, the data-in-renders-itself rule) lives in the
  `cop` skill and the two posts it cites; the Tuile mechanics live in the
  `tuile` skill. Live exemplars: `Shared::ConversationWindow` (a `Window`
  that renders into its own content view, with a thin nested `Listener`) is
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

- **One typed `/name`, three namespaces: built-in > file command >
  skill.** Match built-ins first or a cloned repo shipping
  `.claude/commands/plan.md` captures the `/plan` that flips plan mode
  (pikuri's `Command::Registry` rdoc states the same order for the same
  reason). Collisions are rare, so the loser is simply dropped with one
  `LOG.warn` and only the winner appears in the palette — no disambiguating
  suffix, no second entry. What that costs differs per loser and is accepted:
  a shadowed *skill* stays reachable by asking the agent for it in plain
  language, a shadowed *file command* is genuinely unreachable and the warn is
  the whole remedy.

  The skill half is additionally **gated**: a skill declaring `paths:` is not
  in play until a `read`/`write`/`edit` touches a matching file, and pikuri
  applies that gate at *every* invocation surface — `schedule_load_skill`
  refuses a pending skill exactly as the `skill` tool does (`DECISIONS.md`
  `D-skill-path-activation`, decision 7, which explicitly closed the operator
  exemption). So the palette must not merely survive a gated skill, it must not
  *list* one; `Code::SkillActivationListener` reads the activation and re-lists
  as the gate opens (`Skill::Promoted`) and closes (`/clear`).

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
- `lib/shared/streamed_block.rb` — `Shared::StreamedBlock`, a
  `Tuile::Component::TextView::Region` + its streaming buffer as one unit:
  lazy-open on first `#append`, then `#finalize` (commit) / `#wipe` (drop
  region + content) / `#preserve` (drop handle, keep content). The
  `Shared::ConversationWindow::Listener` holds two (assistant + thinking).
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
  the area. With an optional `slash_menu:` it also arbitrates slash-command
  entry (opens/filters the palette on change, runs a command on Enter for a
  leading-`/` buffer instead of submitting a turn, forwards Up/Down/ESC while
  shown) — the prompt owns Enter and the buffer, so it's the only place that
  can. It likewise owns shell-style history recall: submissions land in its
  `Shared::PromptHistory`, Up/Down recall them at the buffer's first/last row
  (asking Tuile's `TextArea#caret_row` / `#row_count`, and *declining* the key
  when the store is exhausted so the plain TextArea edge-snap survives), and
  its `on_escape` replaces Tuile's clear-focus default with "leave history,
  else clear the buffer". With an optional `conversation:` it also pages that
  pane — PageUp/PageDown scroll it half a screen (Tuile's
  `TextView#scroll_half_page_up` / `#scroll_half_page_down`) without the caret
  leaving the prompt, and a visible slash palette gets those keys first, since
  only the prompt knows it is up. Shared by all three shells.
- `lib/shared/prompt_history.rb` — `Shared::PromptHistory`, the prompt's
  in-memory record of what was submitted this session (turns, injections and
  slash commands alike), with the unsent draft pinned below the newest entry;
  append-only, frozen entries, consecutive duplicates collapsed, `nil` at
  either end of the walk. UI-free and Pikuri-free — deliberately not derived
  from the agent's conversation log, which `/clear` wipes, which never sees a
  slash command, and which has nowhere to put an unsent draft.
- `lib/shared/slash_command.rb` — `Shared::SlashCommand`, a `Data.define`
  value object (name / description / callback) for one slash command; sibling
  of `Shared::LeaderMenu::Action`. The `description` is the autocomplete hint;
  the callback takes the rest-of-line as one `String` arg (`""` when none — an
  action command ignores it, a skill command forwards it as a follow-up
  message) and its `String` return is the outcome echoed below the command
  (`nil` → no echo, for a command whose own effect is the feedback).
- `lib/shared/slash_menu_popup.rb` — `Shared::SlashMenuPopup`, the slash-command
  palette: a `Tuile::Component::ListDropdown` (Tuile's reusable borderless/tinted/
  non-focusable floating list, the `ComboBox` panel half — brings the
  `input_bg_color` tint, the never-steals-the-caret list, and `#move`/`#choose`
  key-forwarding) sized full width less one column each edge, 10 tall, floating
  over the input. Adds the driver-specific parts: filters its command catalog by
  the first token (hiding once a space starts the argument), renders two-column
  rows, navigates, splits `/name rest` and runs the picked command with `rest`,
  and echoes the command + any outcome into the conversation pane via
  `#add_block` (never the agent context; an unknown command echoes a red
  "Command not found"). Driven by `Shared::InputWindow` (`#sync` /
  `#handle_nav_key` / `#submit`); each `App` registers its own command set, and
  `#commands=` re-sets it mid-session (the coding shell's
  `Code::SkillActivationListener` does, as the `paths:` gate opens and closes).
  Shared by all three shells.
- `lib/shared/file_commands.rb` — `Shared::FileCommands`, maps
  `Pikuri::Command::Registry`'s on-disk `.md` prompt templates
  (`.pikuri/commands` / `.claude/commands`) onto `Shared::SlashCommand`s: each
  expands its template against the rest of the typed line and drives it as an
  ordinary *user* turn, a refused one (`allowed-tools:`, a `` !`cmd` ``
  directive) stays listed as `(unavailable)` and answers with the reason, and a
  name a built-in already took is dropped with a warn. Stateless module
  (`.build`), duck-typed on the registry so it carries no pikuri require and
  the lean chat process can still eager-load it. Used by the coding and
  computer shells.
- `lib/shared/trifecta_renderer.rb` — `Shared::TrifectaRenderer`, paints a
  `Pikuri::Trifecta::Report` for the conversation pane (advisory toned by
  verdict, map untoned) — what `/trifecta` echoes in all three shells;
  screen-agnostic (takes the theme) like `Code::DiffRenderer`.
- `lib/shared/status_footer_updater.rb` — `Shared::StatusFooterUpdater`, the
  presenter that keeps the conversation window's footer chrome current
  (it drives `Window#footer_text`; it is not itself a widget), shared by
  all three shells: model name, mid-turn spinner, queued-injection count,
  token snapshot, and a plan-mode badge. Also duck-types as an agent
  listener — its `#on_event` catches `ModelSwitched` and re-points the
  footer's model name — so the footer goes straight into the agent's
  `ListenerList` (no separate listener object; `#current_model=` owns the
  transport→display-name resolution the picker's name map feeds).
- `lib/shared/agent_session.rb` — `Shared::AgentSession`, the turn-lifecycle
  engine all three shells compose: owns one agent's worker thread, the
  `@turn_in_progress` concurrency guard, mid-turn interloper injection +
  leftover delivery (splitting `:user` leftovers into the fresh turn's message
  from `:system` ones it re-injects as context), the blank-submit split (idle →
  a bare `run_loop`; mid-turn → no-op) with an `EmptyTurnError` rescue that dims
  a notice instead of red-lining, the conversation spinner, the pending
  model-switch drain, and the `Ctrl+C` escalation. A coordinator/presenter (holds the `screen` +
  conversation window, drives its spinner/error verbs) — sibling of
  `Shared::StatusFooterUpdater`, *not* a UI-independent service like
  `Code::GitWatcher`. Each `App` constructs one, sets `#agent=` after its build
  block, and delegates Enter/`Ctrl+C`/leader-`c` into it; the `App` keeps its
  own construction/layout/leader-menu/shortcuts/`run` loop plus `quit` /
  `on_screen_error` (which touch neither the agent nor the turn flag).
- `lib/shared/conversation_window.rb` — `Shared::ConversationWindow`, the
  conversation transcript as one cohesive `Tuile::Component::Window`
  subclass shared by all three shells: renders the agent event stream into
  its own content view (blocks, `Shared::StreamedBlock` streaming buffers,
  Markdown / grayscale, tool formatters) via a thin nested `Listener` (a
  `Pikuri::Agent::Listener::Base` that holds the per-stream state and mints
  indented siblings for sub-agents), and carries a
  `Shared::StatusFooterUpdater` footer that itself doubles as the
  `ModelSwitched` listener. Exposes `#listener` (the transcript) /
  `#status_footer_updater` (the footer) for the host to compose into the
  agent's `ListenerList`, plus `#render_notice` (a dim, non-error transcript
  line, sibling of `#render_turn_error`); a `SystemInjected` event renders as a
  dim `⊕` block, except that the two skill-shaped payloads are collapsed — a
  loaded `SKILL.md` body to `⊕ loaded skill: <name>`, a `paths:` promotion block
  to nothing at all (the promoting host announces its own line, carrying the
  matched path the block has no room for). `#scroll_half_page_up` /
  `#scroll_half_page_down` page the viewport for a host holding focus elsewhere
  (the prompt's PageUp/PageDown); paging back to the bottom re-arms tailing.
- `Chat` — namespace (implicit — no `lib/chat.rb`, autovivified from
  `lib/chat/`) for the chat front-end (`Chat::App` + `Chat::Layout`); the
  baseline shell the `Code` / `Computer` siblings were copied from.
- `lib/chat/app.rb` — `Chat::App`, the Tuile
  shell for `bin/pikuri-tui-chat` (conversation `TextView` + diagnostic
  `LogWindow` + input + status bar); takes the loaded `config:` and builds
  its own streaming `Pikuri::Agent` (web/calc tools) from it, plus the
  `Shared::LeaderMenu` and shortcuts. An optional block overrides the
  agent build for tests.
- `lib/chat/layout.rb` — `Chat::Layout`,
  the vertical-split root layout (conversation top, input bottom).
- `lib/code.rb` — `Code`, namespace for the
  coding front-end; home of the duplicate-don't-share rationale for the
  parallel `Code::*` copies.
- `lib/code/app.rb` — `Code::App`, the Tuile
  shell for `bin/pikuri-tui-code`; like `Chat::App` but adds the
  `Code::ConfirmerPopup`, the `Code::WorkspaceSidebar` (tasks + git changes +
  diff popup), plan-mode toggle, and the full three-namespace slash palette
  (built-ins, then `Shared::FileCommands`, then the skill half
  `Code::SkillActivationListener` keeps current). Like the other two shells it
  builds its own agent (models, MCP registry, the six file/shell tools +
  task/skill/command/sub-agent extensions — keeping the `Skill::Extension`
  reference for `schedule_load_skill` and the activation gate) with an optional
  no-arg block overriding the build for
  tests — but because the git-trust prompt / skill-catalog / CLI-flag-driven
  workspace can't be a pure post-screen graph, it takes the bin-built
  `filesystem:` / `sandbox:` / `skill_catalog:` / `command_registry:` /
  `system_prompt:` /
  `trusted_repo:` as constructor args (see the class header for the split).
  `#run` no longer closes the screen — the bin's `begin/ensure` owns teardown.
- `lib/code/skill_activation_listener.rb` — `Code::SkillActivationListener`, a
  `Pikuri::Agent::Listener::Base` mirroring pikuri's `paths:` activation gate
  into the two places the human reads it: the palette's `/<skill-name>` half
  (built from the `Skill::Extension`'s *activation*, not its catalog, so a
  gated skill is unlisted until it fires — see the precedence rule in Scope
  decisions) and a transcript notice naming the file that fired it. `#refresh`
  re-lists (the host calls it after `clear_conversation`; a `Event::Reset` arm
  would run *before* the activation is cleared). Coding-shell-only.
- `lib/code/layout.rb` — `Code::Layout`, the
  coding shell's dual-column root: a 60/40 conversation-over-input left
  column beside a full-height `Code::WorkspaceSidebar` (collapsed when too
  narrow).
- `lib/code/workspace_sidebar.rb` — `Code::WorkspaceSidebar`, the tasks + git
  sidebar as one `Tuile::Component::Layout`: frames `Code::TaskListWindow`
  over the git "Changes" pane, owns the `Code::GitWatcher` lifecycle
  (`#start_git_watching` / `#stop_git_watching`) + the `Code::GitDiffPopup`
  (`#open_diff`), and exposes `#task_listener` for the agent's `ListenerList`.
  Coding-shell-only.
- `lib/code/task_list_window.rb` —
  `Code::TaskListWindow`, the sidebar task pane: a `Window` domain component
  that draws a task list into its own content view (glyphs, placeholder,
  per-status tone) via the `#items=` verb, plus a nested `Listener` (a
  `Pikuri::Agent::Listener::Base`) translating the `Pikuri::Tasks::ListChanged`
  stream into `#items=` calls; exposes `#listener` for the agent's
  `ListenerList`. Coding-shell-only.
- `lib/code/plan_mode_listener.rb` —
  `Code::PlanModeListener`, a `Pikuri::Agent::Listener::Base`
  driving the footer plan-mode badge off `Pikuri::Code::PlanModeChanged`;
  coding/OS-shell-only.
- `lib/code/git_watcher.rb` —
  `Code::GitWatcher`, the background git poller as a **UI-independent
  service**: it emits a `Snapshot` (a `Change` list + raw diff) to
  `#on_change` listeners on its poll thread and knows nothing of the UI;
  `Code::WorkspaceSidebar` subscribes, marshals onto the event loop, and
  projects onto the panes. Owns `Snapshot` / `Change`.
- `lib/code/git_summary_window.rb` —
  `Code::GitSummaryWindow`, the sidebar "Changes" pane: a `Window` domain
  component (subclasses the generic `Window`, renders into its own content view)
  that draws a git change summary (per-file `XY path +A -D` line, kind-toned
  label) via `#snapshot=`; fed by `GitWatcher`.
- `lib/code/git_diff_window.rb` —
  `Code::GitDiffWindow`, the "Git diff" pane (inside `GitDiffPopup`): a `Window`
  domain component that draws a working-tree diff via `#snapshot=`, re-rendering
  at the new width on resize (`#on_width_changed`); fed by `GitWatcher`.
- `lib/code/git_diff_popup.rb` —
  `Code::GitDiffPopup`, the fullscreen `Popup` wrapping the
  long-lived `GitDiffWindow` `GitWatcher` keeps current; opened from the
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
- `lib/code/privacy_store.rb` —
  `Code::PrivacyStore`, the persisted per-project private/public answer
  (tri-state: never-asked is not "no") feeding the workspace's `private:`,
  i.e. the `/trifecta` private leg; asked at most once per project.
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
  formatters) and the `Shared::FileCommands` half of the palette (no skill
  catalog is wired here, so there is no skill half and no `paths:` gate). Like
  `Chat::App`, it takes the loaded `config:` (plus the
  `internet_enabled:` / `profile_dir:` flags, and a `command_registry:` whose
  production default scans the launch dir + `$HOME`) and builds its own agent —
  composing `Pikuri::Os::Extension` + `Pikuri::Thunderbird::Extension` + the
  quarantined web RESEARCHER — with an optional no-arg block overriding the
  build for tests. The `FullFsNoNet` sandbox (whose bwrap probe may raise) is
  built on this production path; the bin's `begin/ensure Tuile::Screen.close`
  owns teardown, so `#run` no longer closes the screen itself.
- `lib/computer/layout.rb` — `Computer::Layout`, a parallel copy
  of `Chat::Layout` (vertical split: conversation top, fixed-height input
  strip bottom, no sidebar).
- `bin/pikuri-tui-chat` — boot script for the chat agent
  (`Bundler.setup(:default)`): parses CLI + loads `Shared::Config`, mounts
  the `Tuile::Screen`, and hands the config to `Chat::App` (which builds the
  agent). Ports pikuri's chat demo.
- `bin/pikuri-tui-code` — boot script for the coding agent
  (`Bundler.setup(:default, :code)`): does the pre-screen boot sequencing App
  can't — CLI + `--readable`/`--writable` validation, project-root discovery +
  `Dir.chdir`, config, the skill catalog + command registry (whose roots both
  ride in the workspace's `readable:`) + workspace + sandbox, the two
  interactive prompts — is this project private? (→ the workspace's
  `private:`, asked before the workspace exists) and the git-trust one
  (→ `trusted_repo`) — and the posture-reflecting
  system prompt — then hands those to `Code::App` (which builds the agent) and
  wraps `App.new`/`run` in `begin/ensure Tuile::Screen.close`. Ports pikuri's
  `bin/pikuri-code` demo.
- `bin/pikuri-tui-computer` — boot script for the desktop assistant
  (`Bundler.setup(:default, :computer)`): parses CLI + loads `Shared::Config`,
  probes the Thunderbird profile (a friendly warn+exit pre-screen), mounts the
  `Tuile::Screen`, and hands the config (+ `internet_enabled` / `profile_dir`)
  to `Computer::App` (which builds the agent — sandbox + `Pikuri::Os::Extension`
  + `Pikuri::Thunderbird::Extension` + the RESEARCHER). Wraps `App.new`/`run`
  in `begin/ensure Tuile::Screen.close` so the screen is torn down on any
  escape, construction (the bwrap probe) or loop. Ports pikuri's
  `pikuri-os/bin/pikuri-computer` demo.
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
  `Shared::AgentSession` is the one exception to the own-your-`LOG`-constant
  rule: it takes an injected `logger:` instead, so its dropped-injection /
  clear-during-turn warnings keep the *composing* shell's tag
  (`'chat'` / `'code'` / `'computer'`) in the diagnostic pane — each `App`
  passes its own `LOG`. It defines no `LOG` of its own and adds no new tag.

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
  conversation pane (`Shared::ConversationWindow`, driven by its nested
  `Shared::ConversationWindow::Listener`)
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
- **A spec that crosses a thread mounts `fake_screen`, not
  `Tuile::Screen.fake`.** Tuile confines the UI to one thread even under
  `FakeScreen` (tuile 0.10.0 dropped the fake's bypass of `check_locked`),
  and `Tuile::FakeEventQueue#submit` runs its block *inline on the calling
  thread* — so production code submitting from a worker (`Shared::AgentSession`'s
  per-turn thread, the tool thread blocking in `Code::ConfirmerPopup#ask`)
  raises there and the worker dies silently, leaving the example to time out
  on a render that never happened. `spec/support/marshalling_fake_screen.rb`
  fixes the seam rather than the symptom: `fake_screen` mounts a screen whose
  queue *queues* off-thread submits, and the shared `wait_until` drains them
  on the example thread — the manual equivalent of the real loop draining its
  queue, so the worker's UI work runs where production runs it. Use them
  together; a spec that only presses keys and asserts needs neither (an
  on-UI-thread submit still runs inline).
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
  component/model-view/data-in rules and the composition-over-inheritance
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
  cross-cutting rule into Conventions / Scope decisions. A **rejected**
  idea graduates the same way — delete the file — but backport only a
  *one-line why-not note* into the durable place a future reader would
  look, and only when the trap it prevents is both invisible in the code
  and silent under test (the regression-guard gate); if nothing meets
  that bar, delete outright. `ideas/` holds only *pending* thinking;
  anything worth keeping after the work lands moves to a durable home,
  and the transient container disappears.
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
  `Shared::PromptHistory`, `Shared::StatusFooterUpdater`,
  `Shared::ConversationWindow`, `Shared::AgentSession`,
  `Shared::LeaderMenu`, `Shared::SlashMenuPopup`, `Shared::SlashCommand`,
  `Shared::FileCommands`,
  `Shared::Log::Popup`, `Shared::Log::UI`, `Shared::Log::CountingIO`, `Shared::Model::Choice`, and
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
