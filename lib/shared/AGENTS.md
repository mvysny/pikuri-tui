# `Shared::` — AGENTS.md

The toolkit all three shells compose out of: the pieces that carried no shell-specific divergence
and were extracted once (`D_parallel_shells`). Extract into here when a second shell needs a block;
the test is "does it stand alone with a clear contract?", not "is it a widget". `ls` is the class
index.

## Invariants

- **Nothing under `Shared::` references `Chat` / `Code` / `Computer`.** A block that needs to know its host takes it as a constructor argument or surfaces a listener the host subscribes to.
- **Nothing under `Shared::` may require a `:code` / `:computer` gem.** The chat process eager-loads this whole directory; `Shared::FileCommands` is duck-typed on pikuri's registry for exactly this reason. See `D_bundler_groups`.
- **`Shared::ConversationTextView#clear` is not a redraw.** It drops every region, a parked confirmer question included; a density toggle re-runs kinded thunks instead. See `D_density_thunks`.
- **Every accent comes from `Shared::AppTheme`**, `theme.hint` first; a component that invents an RGB is the exception and says why in its rdoc. See `D_borderless_panes`.

## Module map

- `log/` — the log subsystem: the window and its popup, the two IO sinks, `#wire!` and the error tally.
- `markdown/` — Markdown → ANSI: the renderer, the kramdown converter, the streaming and passthrough buffers, grayscale.
- `model/` — a connection's display name paired with its transport, and the leader-menu model switcher.

Maintenance: the root `AGENTS.md`'s rules; cap 10 KB.
