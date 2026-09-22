# Decisions

Why this project is the way it is and not otherwise — FAQ-shaped: each entry is a question and
its current answer. Rewrite the answer when it changes; delete the entry when nobody asks any
more. An entry is earned by what it would cost to reverse — half the code base — or by research
the next person would otherwise redo. Not an entry: a glyph, this colour over that colour, a
keybinding, the testing library, the CI host, a version bump — a comment at the site of the
choice, or nothing; nothing about `design/` itself. A sibling project's decision is cited by repo
and bare slug (virtui's `decisions.md` → `tint_toward_grey`), never with the `D_` prefix, which
belongs to this file alone. Cite by slug, `D_<slug>`, never by position; `grep '^## D_'
design/decisions.md` is the index. The first entry is the ruler: every later one trims to its
length — which is how long this file gets, so keep it short. When you have written an entry,
re-read it against the one above, check it says nothing the rdoc already says, and cut what is
left over.

---

## D_pikuri_owns_the_runtime — Why wrap pikuri unchanged rather than own the agent loop?

pikuri ships its agent wirings as plain stdin/stdout REPL demos in its own `bin/`. They work, and
they are unreadable the moment a turn streams, a tool asks for confirmation, or the user wants to
see what changed on disk. So this project replaces the REPL with a Tuile component tree and reuses
pikuri otherwise untouched: `Pikuri::Agent` is the loop, `Pikuri::Tool::*` are the tools,
`Pikuri::Agent::Event` is the stream we render, and this side adds a listener, a confirmer, and
the layout / focus / input wiring around them — nothing else. Why not fork the demos into a TUI
app that owns its own loop: it buys the freedom to render whatever is convenient and costs a
second implementation of tool routing and cancellation that drifts from pikuri's within the week,
so the two front ends would answer differently for the same input with no way to tell which is
current. What we carry instead: a gap in the UI is usually a missing pikuri primitive — the answer
is a new listener event or a new tool back there, not a workaround here — and three shells' worth
of behaviour rides on pikuri's release cadence.

## D_parallel_shells — Why three duplicated `App` / `Layout` pairs rather than a shared base class?

The shell machinery — worker-thread turn loop, log wiring, leader menu, shortcuts, status rule —
is ~90% identical across `Chat`, `Code` and `Computer`, which diverge in their tool set, their
safety machinery and their layout. The final composition stays as deliberate parallel copies: no
base class, no generic `App`. Every *smaller* piece with a clear contract and no shell-specific
divergence is extracted once into `Shared::` instead, or reused from `Code::*` as the computer
shell does with the confirmer and diff adapters; {Code} carries the same rule next to the code it
governs. Why not an `AbstractApp` with template methods: it is the junk drawer the `cop` skill
names — the hooks multiply with each divergence, and a reader of `Chat::App` can no longer see
what the chat shell does without also reading a base class and a decision table. The
readable-not-DRY ceiling this project sets itself does not ask for that win. A triplicated field
or method across the three `App`s is the signal that a block is waiting to be pulled out — that is
how {Shared::AgentSession}, {Shared::Log::UI} and {Shared::StatusRuleLabel} arrived. The cost is
real and accepted: a genuinely cross-shell change is edited three times.

## D_bundler_groups — Why three Bundler groups rather than one?

The coding shell needs the workspace, sandbox, task, MCP, skill and sub-agent gems; the computer
shell needs most of those plus `pikuri-os` and `pikuri-thunderbird`; the chat shell needs none of
them — and all three are one Gemfile and one `lib/`. So each bin calls its own `Bundler.setup` —
`(:default)`, `(:default, :code)`, `(:default, :computer)` — and `lib/pikuri_tui.rb` ignores the
`Code` and `Computer` subtrees when those gems are absent, on the gate its own comment explains.
Why not one group for everything: the chat process would pay the load path and the eager-load of
gems it can never call — bubblewrap wiring, MCP, Thunderbird — for the one shell whose whole point
is being lean enough to run against a bare local llama.cpp. The gate is a single constant check,
so a new `Code::*` file needs no loader change; but a *shared* file that requires a `:code` gem
would break the chat process's eager-load, which is why {Shared::FileCommands} is duck-typed on
the registry rather than requiring pikuri.

## D_tui_degrades_not_crashes — Why does a library's exception degrade here when pikuri lets it raise?

pikuri keeps errors loud on the chat path: it is a CLI and can afford to crash. This project is a
long-running TUI that owns the alternate screen buffer, where an uncaught raise inside the event
loop tears the screen down and takes the user's session with it. Two buckets, then. Unexpected
internal state in *this* project raises, with the offending data in the message. An exception from
anything we did not write — pikuri, ruby_llm, Tuile, kramdown, rouge — is caught at the call site,
logged as `error` through that class's `LOG`, and the surrounding code returns to a safe state:
degraded rendering, a dropped event, an abandoned turn. Why not inherit pikuri's posture
unchanged: it makes every upstream hiccup a session loss, and the diagnostic pane already exists
as a place to surface upstream breakage without being destructive. The failure mode to watch is a
silent fallback — a rescue that neither logs nor degrades visibly hides exactly what this split
exists to surface.

## D_log_through_pikuri — Why log through `Pikuri.logger_for` rather than `Tuile.logger`?

Two logging facilities are in reach, and lines are emitted from the first moment of boot — before
any screen exists — as well as from inside the event loop. Each logging class keeps one private
`LOG = Pikuri.logger_for('<tag>')` constant, and `Pikuri.log_io=` rewires every logger already
handed out in one shot, so pointing it at the `LogWindow` once the screen is up moves the whole
stream, pikuri's and ours, with no per-logger rewiring. `Tuile.logger` is reserved for one job:
capturing Tuile's own internal noise into the same window. Why not `Tuile.logger` for our lines:
it defaults to `IO::NULL`, so everything logged before it is wired is dropped outright, and it is
a single untagged logger — the diagnostic pane would lose the per-subsystem tag that makes it
readable. The boot window this leaves open is {Shared::Log::BufferingIO}'s problem, and its rdoc
has it. {Shared::AgentSession} is the one class that takes an injected `logger:` rather than
owning a constant, so its warnings carry the composing shell's tag.

## D_borderless_panes — Why is nothing in the running UI framed?

The shells were built out of framed `Window`s: every pane carried a box and a caption painted into
its top border. On a 24-row terminal the frames cost two rows per pane, and the captions competed
with the transcript for attention. Now the conversation is the *primary* pane and keeps the
terminal's own background, while every secondary surface — status rule, prompt, sidebar — paints
the `:pane_bg` tint {Shared::Tint} derives from it (toward mid-grey rather than toward the theme's
pole; that road was measured and rejected in virtui first, and the rdoc carries the argument).
What was a border is a hairline: a `─` status rule, a `│` sidebar column, a
{Shared::PaneCaptionLabel} where a caption sat. Only modal popups keep frames. Why no labelled
focus chips, as a multi-pane borderless app would need: there are exactly two focus targets, and
an unfocused `TextView` publishes no cursor position, so the caret *vanishes* when focus moves to
the transcript — which says it more plainly, and in fewer rows, than a chip. The primary pane's
background is never painted, so the app stays translucent under a transparent terminal while the
tinted furniture goes solid; the prompt's tint is a spatial anchor, not a focus state, and tying
it to focus would flip the shade as focus moves.

## D_transcript_confirmer — Why ask the confirmation in the transcript rather than in a modal popup?

Writes, `bash` and each sub-agent research task need a human y/n. This is the one surface these
shells open *unbidden*, mid-typing, so it is the one that must not be able to swallow a keystroke
meant for the prompt. {Code::TranscriptConfirmer} appends the question as a block in the
conversation pane and arms its keys only while that pane holds focus: prose goes to the prompt,
decisions go to the transcript, and no amount of typing can answer a question nobody has read. Why
not a modal popup over the app: it answers the stolen-keystroke problem by stealing every
keystroke, and the typed outcomes then need a text field inside the modal — a second place prose
is entered, which is exactly the surface a mis-aimed `y` would land in. Why not a grace window or
a timer before the keys arm: a pause does not prove attention, and the swallowed key is how this
went wrong the first time; focus is a structural answer where a timer is a statistical one. The
price of arming on focus is that dismissal is not decline — tabbing away parks the decision, which
is the obligation the confirmer's rdoc puts on `Ctrl+C` and quit.

## D_visible_not_detach — Why hide a pane with `visible=` rather than tuile's documented remove/add?

The sidebar disappears on a leader key and, independently, whenever the terminal narrows past
`MIN_SIDEBAR_WIDTH`. Tuile documents `Layout::Box#remove` plus `#add(…, at:)` as *the* way to hide
a box child; this project uses `Tuile::Component#visible = false` instead, which keeps the
component's parent, its rect and everything it is running, and fires no lifecycle hook. Why not
the documented road: it fires `on_detached` down the subtree, and {Code::WorkspaceSidebar} owns
the {Code::GitWatcher} poll that keeps the status-rule digest alive *precisely* while the column
is off screen — so remove/add stops the data feed that hiding exists to preserve. It also churns
the tree on every resize across the starve floor. `visible=` carries the re-division with it:
flipping it marks the parent's `relayout`, so {Code::Layout} re-splits the upper region from the
one seam whether the trigger was the leader key, a resize or the flag — and a hidden pane cannot
paint back at the columns it used to hold.

## D_short_tool_lines — Why does pikuri compose the short tool line rather than a renderer here?

The transcript is read *while* the agent works, where `→ bash(command=…)` and a 200-character
observation dump are noise. A call wants to render as `Bash(rm -rf build)` over `Returned 3
lines` — which means someone has to compose those two strings, and it is pikuri:
`ToolCall#display_name` / `#argument` and `ToolResult#summary` arrive on the events, and this side
only styles, caps and defangs them. The raw dump stays one keystroke away. Why not a tui-side
table mapping tool names onto phrasings: the structure a summary counts is the tool's — a renderer
sees only a flattened string — and pikuri-web and pikuri's own CLI would each need the same table,
three copies to drift; pikuri's `decisions.md` → `tool_summary_lines` carries the
summary-is-written-in-code half. A tool that composes no summary therefore renders a bare call
line here, and the fix is in pikuri, not in a fallback table on this side.

## D_density_thunks — Why re-run a per-block thunk on a density toggle rather than clear and replay?

Two transcript-density switches ship: reasoning shown/hidden and tool lines short/verbose. The
case each exists for is *retrospective* — "that answer looks wrong, show me its reasoning" — so a
filter applied as events arrive is useless, since it reaches only the next block. Instead the
conversation pane keeps a render thunk per block and re-runs it in place against the current
flags, on the contract {Shared::ConversationTextView#add_kinded_block} states. Why not `#clear`
plus a replay of the event log: `#clear` drops *every* region, including the one a parked
{Code::TranscriptConfirmer} question lives in, so a toggle would erase a question while the tool
thread is still blocked on its answer — and replay cannot reconstruct a stream that was cancelled
mid-flight. Why no marker where a hidden block was: a hidden block draws *nothing*, because a line
you cannot click earns nothing in a terminal, which has no cheap per-block affordance to offer,
and the caption would cost a row per block. (pikuri-web inverts this on the same argument: a
browser can make that row clickable, which turns filler into the affordance.) Only a block filed
with a kind can be re-rendered, which is what keeps the `edit` / `write` diffs un-hideable. The
accepted cost is at the other end: while reasoning is hidden the listener drops the delta stream
rather than render into a pane nobody sees, so reasoning cancelled mid-stream gets no bookend and
a later reveal shows only what had streamed.

## D_command_precedence — Why do built-in slash commands beat file commands beat skills?

Three sources feed the slash palette: the shell's built-ins, pikuri's on-disk `.md` prompt
templates (`.pikuri/commands` / `.claude/commands`), and one `/<skill-name>` per skill in play —
and a cloned repo can ship any name it likes. Built-ins match first, then file commands, then
skills: the order pikuri's `Command::Registry` states, for the same reason — a checked-in
`.claude/commands/plan.md` must not capture the `/plan` that flips plan mode. Collisions are rare,
so the loser is dropped with one `LOG.warn` and only the winner is listed. Why not a
disambiguating suffix, or listing both: a palette entry the user cannot predict costs more than
the collision it resolves, and collisions are rare enough that the warn is a cheaper remedy than a
name nobody can type from memory. What the loss costs differs per loser and is accepted: a
shadowed *skill* is still reachable by asking for it in plain language, a shadowed *file command*
is genuinely unreachable and the warn is the whole remedy.
