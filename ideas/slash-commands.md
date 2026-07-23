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

## Blocked: skill commands (waiting on Pikuri `Agent#load_skill`)

Goal: one `/<skill-name>` command per `@skill_catalog.list` entry (code shell —
it's the only one with a skill catalog) that force-loads that skill into the
agent's context, no LLM round-trip (Claude Code doesn't route loading through
the model, and it wastes a turn).

Investigation (2026-07-23): Pikuri has **no host-side context-append API** today.
`Pikuri::Agent` exposes only `run_loop(user_message:)` + `clear_conversation`;
`Interloper#inject_user_message` is mid-turn only. Skills load solely via the
`skill` tool the LLM calls (`Pikuri::Skill::SkillTool` returns the `<skill …>`
body block). Enumerating skills is easy — `Pikuri::Skill::Catalog#list` /
`#get(name)` → `Skill(name, description, location, body)`.

Agreed fix lives in **Pikuri** (Martin to build): a new
`Pikuri::Agent#load_skill(name) → Skill` (raise `Skill::NotFound` / nil if
absent). Design points settled:

1. **Inject as a `:system` message, not `user`.** A lone injected `user` message
   followed by the user's real next turn = two consecutive `user` messages →
   Anthropic role-alternation error. Reuse the memory extension's existing
   mid-conversation `:system` injection path (pikuri-core `agent.rb` `run_loop`
   → `dispatch_ext_on_user_message` lands `<memory-context>` as `:system`); it
   persists across turns until `clear_conversation` and needs no synthetic
   tool-call/assistant scaffolding.
2. **Give the agent the catalog.** Today it rides only in `SkillTool`'s `execute`
   closure; `Skill::Extension#configure` should also hand it to the agent so
   `load_skill` resolves names (clear error when the skills extension isn't wired).
3. **Share the `<skill …>` formatter** between `SkillTool#execute` and
   `load_skill` (extract to e.g. `Skill#to_prompt_block`) so injected bytes match
   whether the LLM or the user loads it.
4. **Emit an event** (`Event::SkillLoaded` or similar) through the `ListenerList`
   so the conversation renders the load immediately.
5. Minor: callable only outside a turn (guard like `clear_conversation`); dedup a
   double-load by name; `clear_conversation` drops loaded skills (wipes history).

pikuri-tui side once it ships (tiny):
- `Shared::AgentSession#load_skill(name)` — thin delegator guarding
  `@turn_in_progress` (mirrors `clear_conversation`).
- `Code::App#build_slash_commands` — one `/<name>` per `@skill_catalog.list`,
  callback `-> { @session.load_skill(name); nil }`; the emitted event renders it.
- If per-skill callbacks bloat `#submit`, take the `Shared::SlashMenuPopup` rdoc's
  service escape hatch (split a non-widget service holding conversation + agent +
  skills out of `#submit`).

## Later

- A general command callback that feeds the agent's message history (the skill
  work above is the first concrete instance; generalize only if a second appears).

## Graduation

Once skill commands land, delete this file (nuggets already live in the class
rdocs, `AGENTS.md`, and git history).
