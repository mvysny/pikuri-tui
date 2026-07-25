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

### Decision: `/foo <message>` loads the skill, then drives a turn — no skill parameters

A skill command is a **distinct breed** from the existing action commands
(`/logs`, `/clear`, `/plan`, `/diff`, `/model`): those fire a UI action and echo
an outcome string via `#add_block`, no agent turn. A skill command instead
consumes the *rest of the line* as a prompt and **drives an `AgentSession`
turn** (pikuri's load+message / bare-load modes above).

**No skill-parameter support.** The text after `/foo` is a **follow-up user
message**, not an argument to the skill. `/foo run the migration` = *load the
`foo` skill, then post the user message "run the migration"* — two separate
things that happen to share one Enter, not a parameterized skill invocation.
Decided because:

- It's the only shape pikuri supports: `schedule_load_skill(name)` takes a name
  and renders the whole `SKILL.md` body via `Renderer.format_skill` — there's no
  substitution slot a parameter could fill. Real skill params would need a
  pikuri-core template change, on top of the `EmptyTurnError` dependency.
- Skills are reference content injected as `:system`, not templates; a
  "parameter `xyz`" has no defined insertion point or consumer, whereas a
  follow-up user message has both.
- The two are behaviorally indistinguishable anyway: `run_loop` drains the
  scheduled `:system` injection *before* appending the user message
  (`agent.rb:248`), so the skill always lands first and the message second,
  both before the first completion — a user who thinks "run foo with xyz" gets
  exactly that.

Consequence for the empty-turn split (step 6): `rest` being a *user message*
makes the bare-load case crisp — `/foo` alone carries no user message (the
Anthropic `EmptyTurnError` path); `/foo <text>` always carries one and never
hits it. Keep docs/notices framed as "load, then optionally say something," not
"arguments to the skill."

Consequences:

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
   - **Decided: inline follow-up message only.** Type `/foo run the migration`
     and one Enter; the palette filters on `foo` and hides once a space is
     present. `rest` is the follow-up user message (not a skill parameter — see
     the section heading). The "select the skill from the palette, then type the
     prompt" alternative is **rejected for v1** — it overloads Enter with
     pick-vs-run; revisit only if a concrete need appears.
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

   - **Hint text: the skill's own one-line summary** from `Catalog::Skill`
     (falling back to `"load the <name> skill"` when it has none). That's the
     `SlashCommand#description` shown as the palette autocomplete hint.
   - **Name-collision policy: the action command wins.** The seven built-in
     verbs (`/logs`, `/diff`, `/plan`, `/model`, `/clear`, `/exit`, `/quit`) are
     a fixed reserved set; if a skill shares one of those names, **skip** its
     `/<name>` registration and log a warning through the code shell's `LOG`
     (e.g. `"skill 'plan' shadows a built-in command; not registered as /plan"`).
     Silently shadowing a documented built-in would be a nasty surprise, and the
     collision is rare. The skill stays reachable the normal way — **tell the LLM
     to load it in a plain user message** (the recommended fallback), or via the
     `skill` tool. Rejected alternatives: skill-wins (breaks a built-in),
     `/skill:foo` namespacing (ugly, defeats the mirror-Claude-Code feel).
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
   it'll apply,"* not "load the skill again." **Decided: a small dim
   `render_notice` verb on `Shared::ConversationWindow`** (not red) is the home —
   the message is informational, not an error, so red-lining it via
   `render_turn_error` would contradict the intent. It's a few lines, and step 7
   (`SystemInjected` → dim block) already establishes the dim-block pattern, so
   it adds no real surface.
7. **`Shared::ConversationWindow::Listener`: render `Event::SystemInjected`.** Not
   handled today; add a dim block (mirror pikuri's terminal listener at
   `pikuri-core/lib/pikuri/agent/listener/terminal.rb:92`) so a loaded skill shows
   in the transcript when it lands. Shared across shells; only the code shell
   emits it in practice.

If per-skill callbacks bloat `#submit`, take the `Shared::SlashMenuPopup` rdoc's
service escape hatch (split a non-widget service holding conversation + agent +
skills out of `#submit`).

### Pikuri-core dependency: `EmptyTurnError` — LANDED in `../pikuri` (commit `e727f3d`)

Built and committed in pikuri-core; **still pending release + switching pikuri-tui
off the `../pikuri` path dep** before the bare-load path above works. `run_loop`'s
old uniform `return false` for a blank turn against an all-`:system` conversation
is now a provider-aware split, keyed on the new `Agent::SYSTEM_HOISTING_PROVIDERS`
constant:

- **OpenAI / Gemini (and llama.cpp): let it run.** They represent system content
  *inside* the messages array (OpenAI keeps `:system`; Gemini remaps
  `:system`→`user`), so a system-only request is valid. The short-circuit is
  dropped for them and the turn completes. The LLM may or may not act on a
  system-only skill-load (it's framed as available reference via
  `Renderer.format_skill`'s `<skill>` wrapper, not an imperative, and a user-less
  turn is out-of-distribution); if it doesn't, the user types a message. Accepted.
- **Anthropic *and Bedrock*: raise `Pikuri::Agent::EmptyTurnError`.** Both hoist
  every `:system` block out of the messages array into a separate top-level field
  (Anthropic's `system` param; Bedrock's `system` blocks), so an all-`:system`
  chat sends `messages: []` → a hard 400. The set is
  `SYSTEM_HOISTING_PROVIDERS = %w[anthropic bedrock]` — a *denylist of
  system-hoisting providers*, not just "Anthropic", so a third such provider is a
  one-token add and any non-listed provider defaults to "try it." Raise (not
  `false`) so the shell can surface *why*; fail-loud replaces a silent `false`
  that reproduced the very 400 it meant to prevent. No existing caller consumed
  the `false` return — `thinker` / `synthesizer` / `sub_agent_tool` / the bin
  REPLs all pass a real `user_message` — so this was contract-safe. The error
  carries the offending `provider` slug.

  Bedrock verification (confidence, so a future reader needn't re-derive it):
  the *empty-messages* half is **source-verified** — `ruby_llm`'s
  `bedrock/chat.rb` (its own `Bedrock::Chat`, not inherited from Anthropic)
  does `system_messages, chat_messages = messages.partition { role == :system }`
  then `messages: render_messages(chat_messages)` with no guard, and
  `render_messages([])` returns `[]`, byte-identical in shape to
  `anthropic/chat.rb`. The *→ 400* half rests on AWS's **documented Converse
  API contract** (`messages` required + non-empty, must lead with a `user`
  turn; `system` is a separate optional field) — **not live-tested** (no AWS
  creds to hand). Kept in the set anyway because the false-positive is graceful:
  if Bedrock ever tolerated empty `messages`, the only cost is a bare `/foo`
  load raising `EmptyTurnError` unnecessarily, and the user loads via a typed
  message instead — no corruption, no lost skill. Asymmetric risk (silent 400
  vs. one harmless extra prompt) favors inclusion.

Both pitfalls were handled in the shipped change: (1) the branch keys on
`@chat.model.provider` (the *resolved model*, after `apply_transport!` — not
`transport.provider`, which is `nil` for a default-configured Anthropic
connection and would let the 400 slip through); (2) the error message is
content-neutral (pikuri-core doesn't know the `:system` block is a *skill* vs
memory vs retrieved docs), so the **shell** owns the skill-flavored wording
(step 6).

## Later

- A general command callback that feeds the agent's message history (the skill
  work above is the first concrete instance; generalize only if a second appears).

## Graduation

Once skill commands land, delete this file (nuggets already live in the class
rdocs, `AGENTS.md`, and git history).
