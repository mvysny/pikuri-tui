# Decisions

Why this project is the way it is: one entry per decision *already taken*, with the
roads not taken. Not what the code does (the code and its rdoc), not what must hold
(`requirements.md`), not what upstream does (pikuri's and Tuile's own docs).

- Cite an entry by slug — `D_<slug>` — never by position. `grep '^## D_' design/decisions.md`
  is the index; there is no table of contents.
- **An entry is earned by what happened, not by having had an alternative:** the decision shaped
  what the project is (reverse it and the README's first paragraph changes), or it cost research
  the next person would otherwise redo — and *Rejected:* then says what was done to rule the road
  out. A tool, a library among equals, the CI host, a version bump: a comment at the site of the
  choice, never an entry. Nothing about `design/` itself is an entry.
- Entries are mutable: refine in place, newest first. A *shipped* decision that is reversed
  keeps its entry as a tombstone (`Status: Superseded by D_<slug>`); the replacement is written fresh.
- Shape: `## D_<slug> — <title> (<decided date>)`, then **Status**, **Context**, **Decision**,
  one **Rejected: …** paragraph per alternative, **Consequences**.
- **The oldest entry — at the bottom — is the ruler**: later entries are trimmed to its length,
  never the other way round.

---

## D_density_thunks — Every density toggle re-runs a per-block thunk; never clear-and-replay (2026-09-07)

**Status:** Accepted; shipped.

**Context.** Two transcript-density switches ship: reasoning shown/hidden and tool lines
short/verbose. The case each exists for is *retrospective* — "that answer looks wrong, show me its
reasoning" — so a filter applied as events arrive is useless: it reaches only the next block.

**Decision.** {Shared::ConversationTextView#add_kinded_block} files each block's render *thunk*
under a kind; `#rerender(kind:)` re-runs them in place against the current flags, and the pane —
not the thunk — decides whether a kind is hidden. A hidden reasoning block collapses to `""`,
keeping its region and its thunk, so a later reveal paints the full text.

**Rejected: `#clear` plus a replay of the event log.** `#clear` drops *every* region, including the
one a parked {Code::TranscriptConfirmer} question lives in — so a toggle would erase a question
while the tool thread is still blocked on its answer. Replay also cannot reconstruct a stream that
was cancelled mid-flight.

**Consequences.** A block can only be re-rendered if it was filed with a kind, which is what keeps
the `edit` / `write` diffs un-hideable (they are deliberately not kinded). Reasoning cancelled
mid-stream has no bookend, so hiding and revealing it shows only what streamed — accepted.

## D_transcript_confirmer — Ask the confirmation in the transcript, and let focus arm the keys (2026-09-04)

**Status:** Accepted; shipped.

**Context.** Writes, `bash` and each sub-agent research task need a human y/n. This is the one
surface these shells open *unbidden*, mid-typing, so it is the one that must not be able to
swallow a keystroke meant for the prompt.

**Decision.** {Code::TranscriptConfirmer} appends the question as a block in the conversation
pane, and `y`/`n`/`e`/`r` answer it *only while that pane holds focus*. Prose goes to the prompt,
decisions go to the transcript; no amount of typing can answer a question nobody has read. The two
typing outcomes borrow the prompt via {Shared::InputPane#capture}.

**Rejected: a modal popup over the app.** It answers the stolen-keystroke problem by stealing
every keystroke, and the typed outcomes then need a text field inside the modal — a second place
prose is entered, which is exactly the surface a mis-aimed `y` would land in.

**Rejected: a grace window or a timer before the keys arm.** A pause does not prove attention, and
the swallowed key is how this went wrong the first time. Focus is a structural answer where a
timer is a statistical one.

**Consequences.** Dismissal is not decline — tabbing away parks the decision, so decline-by-default
must live explicitly in `Ctrl+C` and quit (`#reject_pending!`) or a parked tool leaves `Ctrl+C`
looking broken. A parked decision is loud on the status rule, since an inline block can be ignored
where a modal cannot.

## D_borderless_panes — One untinted primary pane, tinted secondaries, hairlines where frames were (2026-08-31)

**Status:** Accepted; shipped.

**Context.** The shells were built out of framed `Window`s: every pane carried a box and a caption
painted into its top border. On a 24-row terminal the frames cost two rows per pane, and the
captions competed with the transcript for attention.

**Decision.** Nothing in the running UI is framed. The conversation is the *primary* pane and keeps
the terminal's own background; every secondary surface — status rule, prompt, sidebar — paints
`:pane_bg`, one step of HSL lightness toward mid-grey from the reported terminal background, hue
held ({Shared::Tint}). What was a border is a hairline: a `─` status rule, a `│` sidebar column, a
{Shared::PaneCaptionLabel} where a caption sat. Only modal popups keep frames.

**Rejected: tinting toward the theme's pole (darker in dark, lighter in light).** Measured in
virtui first, whose `DECISIONS.md` → `tint_toward_grey` carries the table: stepping away from
mid-grey runs out of headroom on a pure-black or pure-white terminal, where toward-grey always has
somewhere to go.

**Rejected: labeled focus chips, as a multi-pane borderless app would need.** There are exactly two
focus targets, and an unfocused `TextView` publishes no cursor position — so the caret *vanishes*
when focus moves to the transcript, which says it more plainly than a chip.

**Consequences.** The primary pane's background is never painted, so the app stays translucent
under a transparent terminal while the tinted furniture goes solid — intended. The prompt's tint is
a spatial anchor, not a focus state: tying it to focus would flip the shade as focus moves.

## D_short_tool_lines — The short tool line is the tool's own words, never a tui-side phrasing (2026-09-07)

**Status:** Accepted; shipped.

**Context.** The transcript is read *while* the agent works, where `→ bash(command=…)` and a
200-character observation dump are noise. A call wants to render as `Bash(rm -rf build)` over
`Returned 3 lines` — which means someone has to compose those two strings.

**Decision.** Pikuri composes them: `ToolCall#display_name` / `#argument` and `ToolResult#summary`
arrive on the events, and this side only styles, caps and defangs them (every value on the short
path goes through `Pikuri::Sanitizer`, since unlike the raw path it does not get `inspect`'s
escaping for free). The raw dump stays one keystroke away.

**Rejected: a tui-side table mapping tool names onto phrasings.** The structure a summary counts is
the tool's — a renderer sees only a flattened string — and pikuri-web and pikuri's own CLI would
each need the same table, which is three copies to drift. pikuri's `D_tool_summary_lines` carries
the summary-is-written-in-code half.

**Consequences.** A tool that composes no summary renders a bare call line here; the fix is in
pikuri, not in a fallback table on this side.

## D_command_precedence — One typed `/name`, three namespaces: built-in > file command > skill (2026-08-17)

**Status:** Accepted; shipped.

**Context.** Three sources feed the slash palette: the shell's built-ins, pikuri's on-disk `.md`
prompt templates (`.pikuri/commands` / `.claude/commands`), and one `/<skill-name>` per skill in
play. A cloned repo can ship any name it likes.

**Decision.** Built-ins match first, then file commands, then skills — the order pikuri's
`Command::Registry` states for the same reason: a checked-in `.claude/commands/plan.md` must not
capture the `/plan` that flips plan mode. Collisions are rare, so the loser is dropped with one
`LOG.warn` and only the winner is listed.

**Rejected: a disambiguating suffix, or listing both.** A palette entry the user cannot predict
costs more than the collision it resolves, and collisions are rare enough that the warn is a
cheaper remedy than a name nobody can type from memory.

**Consequences.** What the loss costs differs per loser and is accepted: a shadowed *skill* is still
reachable by asking for it in plain language, a shadowed *file command* is genuinely unreachable and
the warn is the whole remedy.

## D_visible_not_detach — Hide a pane with `visible=`, never by detaching it from its box (2026-09-04)

**Status:** Accepted; shipped.

**Context.** The sidebar disappears on a leader key and, independently, whenever the terminal
narrows past `MIN_SIDEBAR_WIDTH`. Tuile documents `Layout::Box#remove` plus `#add(…, at:)` as *the*
way to hide a box child.

**Decision.** `Tuile::Component#visible = false`. The component keeps its parent, its rect and
everything it is running; it fires no lifecycle hook.

**Rejected: the documented remove/add.** It fires `on_detached` down the subtree, and
{Code::WorkspaceSidebar} owns the {Code::GitWatcher} poll that keeps the status-rule digest alive
*precisely* while the column is off screen — so the documented road stops the data feed that hiding
exists to preserve. It also churns the tree on every resize across the starve floor.

**Consequences.** The Gemfile's `tuile ~> 0.15` floor is this decision's: `Component#visible=`
landed there together with the `Layout::Box` / `Screen#repaint` half of the same fix (tuile#17),
which is what stops a hidden pane painting back at stale coordinates. `#sidebar_visible?` answers
on visibility, not on the mode, since a `:narrow` column can still be starved out.

## D_tui_degrades_not_crashes — A library exception is logged and degraded; only our own bugs raise (2026-05-18)

**Status:** Accepted; shipped.

**Context.** pikuri's rule is that errors stay loud on the chat path — it is a CLI and can afford
to crash. This project is a long-running TUI that owns the alternate screen buffer: an uncaught
raise inside the event loop tears the screen down and takes the user's session with it.

**Decision.** Two buckets. Unexpected internal state in *this* project raises, with the offending
data in the message. An exception from anything we did not write (pikuri, ruby_llm, Tuile,
kramdown, rouge) is caught at the call site, logged as `error` through that class's `LOG`, and the
surrounding code returns to a safe state — degraded rendering, dropped event, abandoned turn.

**Rejected: pikuri's own posture, inherited unchanged.** It makes every upstream hiccup a session
loss, and the diagnostic pane already exists as a place to surface upstream breakage without being
destructive.

**Consequences.** A silent fallback is the failure mode to watch: a rescue that neither logs nor
degrades visibly hides exactly what this split exists to surface.

## D_log_through_pikuri — Every log line goes through `Pikuri.logger_for`, never `Tuile.logger` (2026-05-18)

**Status:** Accepted; shipped.

**Context.** Two logging facilities are in reach, and lines are emitted from the first moment of
boot — before any screen exists — as well as from inside the event loop.

**Decision.** Each logging class keeps one private `LOG = Pikuri.logger_for('<tag>')` constant.
`Pikuri.log_io` defaults to `$stderr`, so a `LOG` built at class-load time works immediately, and
`Pikuri.log_io=` rewires *every* logger already handed out in one shot — so pointing it at the
`LogWindow::IO` after the screen is up moves the whole stream, pikuri's and ours, with no
per-logger rewiring. `Tuile.logger` is reserved for one job: capturing Tuile's own internal noise
into the same window.

**Rejected: `Tuile.logger` for our lines.** It defaults to `IO::NULL`, so everything logged before
it is wired is dropped outright, and it is a single untagged logger — the diagnostic pane would
lose the per-subsystem tag that makes it readable.

**Consequences.** Lines emitted before the swap would still only reach `$stderr`, invisible under
the alternate screen buffer, so each bin installs a {Shared::Log::BufferingIO} that tees and
retains them for {Shared::Log::UI#wire!} to replay. {Shared::AgentSession} takes an injected
`logger:` rather than owning a constant, so its warnings carry the composing shell's tag.

## D_bundler_groups — Three Bundler groups, one per shell, and the loader skips what is absent (2026-06-08)

**Status:** Accepted; shipped.

**Context.** The coding shell needs the workspace, sandbox, task, MCP, skill and sub-agent gems;
the computer shell needs most of those plus `pikuri-os` and `pikuri-thunderbird`; the chat shell
needs none of them. All three are one Gemfile and one `lib/`.

**Decision.** Each bin calls its own `Bundler.setup` — `(:default)`, `(:default, :code)`,
`(:default, :computer)` — with the shared heavier gems in both groups via `groups:`. `lib/pikuri_tui.rb`
ignores the `Code` and `Computer` subtrees entirely when the heavier gems are absent, gated on
`Pikuri::Workspace` (the computer subtree reuses the `Code::*` adapters and needs the same gems).

**Rejected: one group for everything.** The chat process would pay the load path and the
eager-load of gems it can never call — bubblewrap wiring, MCP, Thunderbird — for a shell whose
whole point is being the lean one that runs against a bare local llama.cpp.

**Consequences.** The gate is a single constant check, so a new `Code::*` file needs no loader
change — but a *shared* file that requires a `:code` gem would break the chat process's eager-load,
which is why `Shared::FileCommands` is duck-typed on the registry rather than requiring pikuri.

## D_parallel_shells — Three shells duplicate `App` / `Layout`; everything smaller is shared (2026-06-08)

**Status:** Accepted; shipped; confirmed by the third shell (2026-07-15).

**Context.** The shell machinery — worker-thread turn loop, log wiring, leader menu, shortcuts,
status rule — is ~90% identical across `Chat`, `Code` and `Computer`, which diverge in their tool
set, their safety machinery and their layout. The obvious move is a common `App` base with hooks.

**Decision.** The final composition stays as deliberate parallel copies — no base class, no generic
`App` — while every *smaller* piece with a clear contract and no shell-specific divergence is
extracted once into `Shared::` (or reused from `Code::*`, as the computer shell does with the
confirmer and diff adapters). {Code} carries the same rule next to the code it governs.

**Rejected: an `AbstractApp` with template methods.** It is the junk drawer the `cop` skill names:
the hooks multiply with each divergence, and a reader of `Chat::App` can no longer see what the
chat shell does without reading two files and a decision table. The project's readable-not-DRY
ceiling does not ask for the win.

**Consequences.** A triplicated field or method across the three `App`s is the signal that a block
is waiting to be pulled out — that is how {Shared::AgentSession}, {Shared::Log::UI} and
{Shared::StatusRuleLabel} arrived. The cost is real and accepted: a genuinely cross-shell change
is edited three times.

## D_pikuri_owns_the_runtime — Wrap pikuri unchanged; own nothing but the Tuile shell (2026-05-18)

**Status:** Accepted; shipped.

**Context.** pikuri ships its agent wirings as plain stdin/stdout REPL demos in its own `bin/`.
They work, and they are unreadable the moment a turn streams, a tool asks for confirmation, or the
user wants to see what changed on disk.

**Decision.** Replace the REPL with a Tuile component tree and reuse pikuri otherwise unchanged.
`Pikuri::Agent` is the loop, `Pikuri::Tool::*` are the tools, `Pikuri::Agent::Event` is the stream
we render. This side adds a listener, a confirmer, and the layout / focus / input wiring around
them — and nothing else (`R_shell_only`).

**Rejected: forking the demos into a TUI app that owns its own loop.** It buys the freedom to
render whatever is convenient and costs a second implementation of tool routing and cancellation
that drifts from pikuri's the first week.

**Consequences.** A gap in the UI is often a missing pikuri primitive: the answer is a new listener
event or a new tool back in pikuri, not a workaround here. Three shells' worth of behaviour ride on
pikuri's release cadence.
