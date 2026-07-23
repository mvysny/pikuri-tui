# Slash commands — remaining work

The infrastructure landed (`Shared::SlashCommand`, `Shared::SlashMenuPopup`,
`Shared::InputWindow` slash arbitration, per-shell `build_slash_commands`, specs).
Durable docs are in `AGENTS.md` (Layout + dedup list) and the class rdocs. This
file now tracks only what's still pending.

## Blocked: the "slightly distinctive background"

The palette should have a slightly distinctive background across the whole box
(incl. the blank filler rows). There's no whole-component background knob in
Tuile today — filed as:

- **https://github.com/mvysny/tuile/issues/1** (a `List` background-fill color,
  suggesting a general `Component#background_color`).

When it ships:

1. Add a `:menu_bg` custom token to `Shared::AppTheme` (`DARK_CUSTOM` /
   `LIGHT_CUSTOM`) — a subtle tint, light/dark aware.
2. Set it on `Shared::SlashMenuPopup`'s list (the new Tuile setter).
3. Consider a matching tint on the `Window` frame so the whole popup reads as
   one panel.

## Later (out of scope for the infra session)

- More commands + skills. The `SlashCommand` catalog is the seam; skills likely
  arrive via the service escape hatch noted in `Shared::SlashMenuPopup`'s rdoc
  (split a non-widget service holding conversation + agent + skills out of
  `#submit` once execution grows past app-action callbacks).
- A command callback that feeds the agent (today every echo stays out of the
  agent's message history).

## Graduation

Once the background lands, delete this file (its durable note — the `:menu_bg`
token — will live in `Shared::AppTheme`'s rdoc and this repo's git history).
