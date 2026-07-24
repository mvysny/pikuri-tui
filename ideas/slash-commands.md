# Slash commands — remaining work

The infrastructure landed (`Shared::SlashCommand`, `Shared::SlashMenuPopup`,
`Shared::InputWindow` slash arbitration, per-shell `build_slash_commands`, specs),
as did the distinctive panel background — the popup is a borderless `Popup`+`List`
(no `Window`) tinted with the `ComboBox` dropdown's `Tuile::Theme#input_bg_color`
via a live `Tuile::Theme.ref` on `bg_color` (durable note in `Shared::SlashMenuPopup`'s
rdoc). Durable docs are in `AGENTS.md` (Layout + dedup list) and the class rdocs.
This file now tracks only what's still pending.

## Landed: leader-menu commands in every shell

Each shell's `build_slash_commands` now mirrors its `Ctrl+K` leader menu by
name: `/logs`, `/clear`, `/exit`/`/quit` everywhere; `/plan` (code + computer);
`/diff` (code only); `/model` (all, only when >1 connection, like the menu's
`m`). Callbacks stay lazy and delegate to the same handlers the leader menu
uses. Durable in each `App#build_slash_commands` rdoc + specs.

## Unblocked: skill commands (Pikuri shipped the load API — different shape)

Goal: one `/<skill-name>` command per `@skill_catalog.list` entry (code shell —
it's the only one with a skill catalog) that loads that skill on the user's own
initiative, mirroring Claude Code's two behaviours:

- `/foo run the migration` → load the `foo` skill, then run a turn on "run the
  migration" (pikuri's **load + message** mode).
- `/foo` alone → load the `foo` skill, then a **bare-load** turn (`run_loop(nil)`):
  the agent reacts to the skill by itself, sometimes starting on it ("you loaded
  writing-rdoc, I'll start coding"). Provider-split — see the pikuri-core
  dependency below: on OpenAI/Gemini the bare turn runs (the LLM may or may not
  act on system-only content; if it doesn't, the user just types a message); on
  Anthropic a conversation *cannot* start with only system content, so pikuri
  raises and the shell shows a notice (the skill is still loaded).

### What Pikuri actually shipped (0.0.7)

Not `Agent#load_skill` as sketched below — the API landed on the **extension**
and is **interloper-based, enqueue-only**:

    Pikuri::Skill::Extension#schedule_load_skill(name) → Catalog::Skill

(`pikuri-skills/lib/pikuri/skill/extension.rb:106`). It looks `name` up in the
catalog, renders the body with `Pikuri::Skill::Renderer.format_skill(skill)`
(the same formatter `SkillTool#execute` uses), and **enqueues** it on the
agent's `Interloper` as a `:system` block via `inject_system_message`. It only
*enqueues* — nothing lands until the host runs the loop and it drains (at turn
start, or the next `after_tool_result` boundary if a turn is already running,
exactly like a mid-loop user injection). The interloper is `Mutex`-guarded, so
the call is non-blocking and safe from the UI thread whether or not a turn is
in flight — **no `@turn_in_progress` guard needed**, unlike `clear_conversation`.

- `bind(ctx)` captures the agent's interloper, so the agent MUST be built with
  `interloper:` (`Code::App` already does — `app.rb:351`). Missing interloper →
  `RuntimeError`.
- Name miss → `KeyError` (not the `Skill::NotFound` guessed below).
- Drain emits the **generic** `Pikuri::Agent::Event::SystemInjected(content:)`
  (not a bespoke `SkillLoaded`) through the `ListenerList`
  (`pikuri-core/lib/pikuri/agent.rb:644`); pikuri's terminal listener renders it
  dim.
- **`run_loop` is built for this flow.** At turn start it drains scheduled
  injections *before* appending the user message (`agent.rb:248`, with a comment
  naming "a UI-loaded skill"), so `schedule_load_skill('foo')` then
  `run_loop(user_message: text)` lands the skill first, the message second, both
  before the first completion. The all-`:system` bare-load edge case (blank
  `user_message`, no user/assistant message yet) needs a small pikuri-core change
  — see the dependency section below.
- **Provider divergence** (documented, deliberate): `:system` injected mid-loop
  is a positional one-shot on llama.cpp/OpenAI-family, but on Anthropic every
  `:system` is hoisted into the top-level system param, so a host-loaded skill is
  **sticky** for the rest of the conversation. `clear_conversation` still wipes it.

How this maps to the design points sketched pre-ship: (1) `:system` injection ✓,
via the interloper's `inject_system_message` rather than the memory path.
(3) shared formatter ✓, as `Renderer.format_skill`. (4) event emitted ✓, but the
generic `SystemInjected`, not a skill-specific event. (2)/(5) moot — the catalog
+ interloper live on the *extension*, and enqueue-only + `Mutex` guarding removes
the outside-a-turn/dedup concerns entirely.

### Decision: `/foo [args]` loads, then drives a turn

A skill command is a **distinct breed** from the existing action commands
(`/logs`, `/clear`, `/plan`, `/diff`, `/model`): those fire a UI action and echo
an outcome string via `#add_block`, no agent turn. A skill command instead
consumes the *rest of the line* as a prompt and **drives an `AgentSession`
turn** (pikuri's load+message / bare-load modes above). Consequences:

1. **`Shared::SlashCommand` callback gains a remainder argument.** From no-arg to
   one `String` arg — the text after the command name, `""` when none. Action
   commands accept-and-ignore it (`->(_rest) { … }`). Touches every
   `build_slash_commands`.
2. **Slash arbitration splits `/name rest`.** The palette (`Shared::SlashMenuPopup`
   / `Shared::InputWindow`) currently filters the whole post-`/` buffer as a
   command-name prefix; it must filter on the **first token only**, and on Enter
   parse `buffer[1..].split(/\s+/, 2)` → `name` + `rest`, calling
   `command.callback.call(rest)`. Unknown first token → the existing red "Command
   not found".
   - Open question: how the argument is entered. Minimal (recommended to start):
     **inline only** — type `/foo run the migration` and one Enter; the palette
     filters on `foo`, hides once a space is present. Later refinement: select the
     skill from the palette, then type the prompt (but that overloads Enter with
     pick-vs-run — defer).
3. **`Code::App`: keep the extension reference.** The build block does
   `c.add_extension Pikuri::Skill::Extension.new(catalog: @skill_catalog)`
   (`app.rb:378`) and drops the instance. Assign it (`@skill_ext = …`) so the
   callbacks can reach `schedule_load_skill`.
4. **`Code::App#build_slash_commands`: one `/<name>` per `@skill_catalog.list`**
   (skip if `@skill_catalog.empty?`). Callback:

   ```ruby
   ->(rest) do
     @skill_ext.schedule_load_skill(name)   # enqueue :system FIRST (ordering matters)
     @session.submit(rest)                  # rest present -> load+message; blank -> bare turn
     nil                                    # no palette echo; the turn + SystemInjected render it
   end
   ```

   `schedule` before `submit` is what makes the skill land ahead of the message
   (both ride the same interloper). Cases fall out of the existing
   `AgentSession#submit`: present+idle → turn draining skill first; present+busy →
   `inject_user_message` after the skill (mid-loop); blank+idle → bare
   `run_loop(nil)`; blank+busy → **must be a no-op** (the skill already rides the
   running turn) — see step 5.
5. **`Shared::AgentSession#submit`: harden blank-while-busy to a no-op.** Today
   `submit` is only ever called with non-empty text, so `queue_mid_turn(nil)` →
   `inject_user_message(nil)` → `ArgumentError` is untested territory. Guard it so
   a blank submit during a turn does nothing (idle blank already flows through to
   a bare `run_loop(nil)`). No `load_skill` delegator or turn guard needed on
   `AgentSession` — the two-line orchestration lives in the callback.
6. **`Shared::AgentSession#start_turn`: rescue the new `EmptyTurnError` (see
   below).** Add a narrow `rescue Pikuri::Agent::EmptyTurnError` *before* the
   generic `rescue StandardError` (so it's neither logged as an error nor
   red-lined), marshaling a gentle notice into the conversation pane rather than
   `render_turn_error`. `@turn_in_progress` still clears in the existing `ensure`.
   Because the skill has already loaded by the time it raises (`agent.rb:248`
   drains before the guard), the notice says *"skill loaded — send a message and
   it'll apply,"* not "load the skill again." A small `render_notice` verb on
   `Shared::ConversationWindow` (dim, not red) is the clean home; reuse
   `render_turn_error` only as a v1 shortcut.
7. **`Shared::ConversationWindow::Listener`: render `Event::SystemInjected`.** Not
   handled today; add a dim block (mirror pikuri's terminal listener at
   `pikuri-core/lib/pikuri/agent/listener/terminal.rb:92`) so a loaded skill shows
   in the transcript when it lands. Shared across shells; only the code shell
   emits it in practice.

If per-skill callbacks bloat `#submit`, take the `Shared::SlashMenuPopup` rdoc's
service escape hatch (split a non-widget service holding conversation + agent +
skills out of `#submit`).

### Pikuri-core dependency: `EmptyTurnError` for the all-`:system` bare-load

The one piece that lives in pikuri-core (`../pikuri`), to build there and release
before the bare-load path above works. Today `run_loop` short-circuits a blank
turn against an all-`:system` conversation with a silent `return false`
(`agent.rb:254`), guarding uniformly across providers. Replace that with a
provider-aware split — decided across this thread:

- **OpenAI / Gemini: let it run.** They represent system content *inside* the
  messages array (OpenAI keeps `:system`; Gemini remaps `:system`→`user`), so a
  system-only request is valid. Drop the short-circuit for them and complete the
  turn. The LLM may or may not act on a system-only skill-load (it's framed as
  available reference via `Renderer.format_skill`'s `<skill>` wrapper, not an
  imperative, and a user-less turn is out-of-distribution); if it doesn't, the
  user types a message. Accepted.
- **Anthropic: raise `Pikuri::Agent::EmptyTurnError`.** Anthropic hoists every
  `:system` into the top-level `system` param (`anthropic/chat.rb:18,68`), so an
  all-`:system` chat sends `messages: []` → a hard 400. It genuinely can't run.
  Raise instead of returning false so the shell can surface *why* (fail-loud; a
  silent `false` is easy to ignore and reproduces the original mystery). No
  existing caller consumes the `false` return — `thinker` / `synthesizer` /
  `sub_agent_tool` / the bin REPLs all pass a real `user_message` — so this is
  contract-safe.

Two things to get right in the pikuri-core change:

1. **Detect the provider from the resolved model, not the transport.**
   `transport.provider` is only non-nil when a per-connection override is set; a
   default-configured Anthropic connection has `transport.provider == nil` while
   the backend is still Anthropic. Key the branch on `@chat.model.provider` (after
   `apply_transport!` at the top of `run_loop`, so a mid-conversation switch is
   reflected), or the 400 slips through.
2. **Keep the error content-neutral.** pikuri-core doesn't know the injected
   system block is a *skill* (could be memory context or retrieved docs), so its
   message stays general — e.g. *"Anthropic can't complete a turn whose
   conversation holds only system content (no user or assistant message); add a
   user message."* The **shell** owns the skill-flavored wording (step 6), since
   only it knows a skill was just loaded.

## Later

- A general command callback that feeds the agent's message history (the skill
  work above is the first concrete instance; generalize only if a second appears).

## Graduation

Once skill commands land, delete this file (nuggets already live in the class
rdocs, `AGENTS.md`, and git history).
