# Slash commands — remaining work

The infrastructure landed (`Shared::SlashCommand`, `Shared::SlashMenuPopup`,
`Shared::InputWindow` slash arbitration, per-shell `build_slash_commands`, specs),
as did the distinctive panel background — the popup is a borderless `Popup`+`List`
(no `Window`) tinted with the `ComboBox` dropdown's `Tuile::Theme#input_bg_color`
via a live `Tuile::Theme.ref` on `bg_color` (durable note in `Shared::SlashMenuPopup`'s
rdoc). Durable docs are in `AGENTS.md` (Layout + dedup list) and the class rdocs.
This file now tracks only what's still pending.

## Later

- More commands + skills. The `SlashCommand` catalog is the seam; skills likely
  arrive via the service escape hatch noted in `Shared::SlashMenuPopup`'s rdoc
  (split a non-widget service holding conversation + agent + skills out of
  `#submit` once execution grows past app-action callbacks).
- A command callback that feeds the agent (today every echo stays out of the
  agent's message history).

## Graduation

Once these land, delete this file (nuggets already live in the class rdocs,
`AGENTS.md`, and git history).
