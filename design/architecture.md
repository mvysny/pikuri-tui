# Architecture

The bird's-eye map of the code as it is: the major pieces, how they are wired, and the flows that
cross several of them. **The code and its rdoc are the authority; this file describes them.** When
they disagree, fix this file.

Keep it short. Anything true of one class belongs in that class's rdoc, not here. This file holds
only what no single symbol can: dependency direction, the threading and lifecycle story, and where
a newcomer should start reading. Cite `R_` for what must hold and `D_` for why; argue nothing here.
**The first entry in each section is the ruler** — later entries are trimmed to its length.

The **map** — which directory holds what, one line each — is not here: it is in `AGENTS.md`, because
an agent needs it every turn (root: one line per directory; `lib/shared/AGENTS.md` and
`lib/code/AGENTS.md`: one line per class). This file starts where the map stops.

## Wiring

- Dependencies point one way: `bin/*` → a shell's `App` → `Shared::*` and `Code::*` components → pikuri + Tuile. Nothing under `Shared::` references `Chat` / `Code` / `Computer` (`D_parallel_shells`).
- Each bin does only what must happen *before* a screen exists — CLI parsing, `Shared::Config`, project-root discovery, the interactive trust / privacy prompts, the sandbox probe — then mounts the `Tuile::Screen` and hands the results to its `App`, which builds the agent. `App.new` / `#run` are wrapped in the bin's `begin/ensure Tuile::Screen.close`.
- An `App` constructs, never inherits: it composes the shared blocks (`Shared::AgentSession`, `Shared::Log::UI`, `Shared::ConversationTextView`, `Shared::InputPane`, `Shared::StatusRuleLabel`, `Shared::LeaderMenu`) into its own `Layout`, and registers its own action and slash-command sets.
- A component that renders the agent's stream owns its own pikuri wiring — it exposes `#listener` and the host drops that into the agent's `ListenerList`. `Shared::ConversationTextView`, `Code::TaskListPane` and `Shared::StatusRuleLabel` each do this; `Code::GitWatcher` is the opposite case, a UI-independent service the sidebar subscribes to.
- Logging is one pipeline: each class's private `LOG = Pikuri.logger_for('<tag>')` → `Pikuri.log_io` → a `Shared::Log::BufferingIO` before the screen, a `Shared::Log::CountingIO` into the `LogWindow` after `Shared::Log::UI#wire!` replays the boot lines (`D_log_through_pikuri`). `Tuile.logger` carries Tuile's own noise into the same window and nothing else.

## Flows

**A turn** (the prompt's Enter, or a `/name` command that drives one):

1. `Shared::InputPane` submits the buffer; `Shared::AgentSession#submit` either starts a turn or — mid-turn — injects into pikuri's `Control::Interloper` queue.
2. The session spawns one worker thread and calls `Pikuri::Agent#run_loop` there: the UI thread stays free, which is the whole point (`Shared::StatusRuleLabel`'s spinner keeps ticking).
3. pikuri emits `Agent::Event`s on that worker. Every listener marshals its render back with `screen.event_queue.submit { … }` — the non-negotiable rule, since most Tuile mutators raise `"UI lock not held"` off-thread.
4. `Shared::ConversationTextView::Listener` renders each event: streamed deltas rewrite a `Shared::StreamedBlock` region in place through the Markdown buffers, tool events render short or verbose (`D_short_tool_lines`), and kinded blocks are filed for later re-render (`D_density_thunks`).
5. The turn ends; the session delivers anything still queued as a fresh turn, drains a pending model switch, and clears the spinner.

**A confirmation** (a write, a `bash`, a research task — `R_human_gated_egress`):

1. The tool thread calls `Code::TranscriptConfirmer#ask` and **blocks** there.
2. The confirmer marshals onto the UI thread, renders the request through `Code::ConfirmRenderer` and hands the pane a `Shared::PendingDecision`; the status rule shows the badge.
3. Nothing else happens until a key answers it *in the transcript* (`D_transcript_confirmer`) — or `Ctrl+C` / quit calls `#reject_pending!`, the only two places decline-by-default lives.
4. An `e` or `r` outcome borrows the prompt via `Shared::InputPane#capture`; the answer unblocks the tool thread, which returns into pikuri's loop.

## Where to start reading

`bin/pikuri-tui-chat` and `lib/chat/app.rb` — the smallest complete shell: a hundred lines of boot
and one `App` that composes every shared block without a sidebar, a confirmer or a sandbox. Then
`lib/shared/conversation_text_view.rb`, where the agent's event stream becomes the thing the user
actually reads.
