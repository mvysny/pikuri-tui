# `Shared::` — AGENTS.md

This directory's must-not-break list and class map, loaded beside the root `../../AGENTS.md` when
work touches it. One-line invariants and pointers only; the truth lives in each class's rdoc, the
roads not taken in `../../design/decisions.md`. ≤ 10 KB.

`Shared::` is the toolkit all three shells compose out of — the pieces that carried no
shell-specific divergence (`D_parallel_shells`). Extract into here when a second shell needs a
block; the test is "does it stand alone with a clear contract?", not "is it a widget".

## Invariants

- **Nothing under `Shared::` references `Chat` / `Code` / `Computer`.** A block that needs to know its host takes it as a constructor argument or surfaces a listener the host subscribes to.
- **Nothing under `Shared::` may require a `:code` / `:computer` gem.** The chat process eager-loads this whole directory; `Shared::FileCommands` is duck-typed on pikuri's registry for exactly this reason. See `D_bundler_groups`.
- **`Shared::ConversationTextView#clear` is not a redraw.** It drops every region, a parked confirmer question included; a density toggle re-runs kinded thunks instead. See `D_density_thunks`.
- **Every accent comes from `Shared::AppTheme`**, `theme.hint` first; a component that invents an RGB is the exception and says why in its rdoc. See `D_borderless_panes`.

## Classes

- `app_theme.rb` — `Shared::AppTheme`: the accent tokens; `.install(screen)` before any component is built.
- `tint.rb` — `Shared::Tint`: derives `:pane_bg` / hairline from the terminal's reported background.
- `config.rb` — `Shared::Config`: the layered XDG TOML config, hand-validated; `[[server]]` + `[[llm]]` resolve here.
- `root_layout.rb` — `Shared::RootLayout`: the shell's layout over the status bar; re-installs the theme on a flip.
- `status_bar.rb` — `Shared::StatusBar`: the bottom `^C` / `^K` row, the `^K` half a re-runnable block.
- `status_rule_label.rb` — `Shared::StatusRuleLabel`: the `───` rule and its readout; also an agent listener.
- `pane_caption_label.rb` — `Shared::PaneCaptionLabel`: a borderless pane's caption row plus hairline.
- `passive_text_view.rb` — `Shared::PassiveTextView`: a `TextView` that takes no focus and no Tab stop.
- `conversation_text_view.rb` — `Shared::ConversationTextView`: the transcript; renders the agent stream via a nested `Listener`, owns both density flags and the pending decision.
- `streamed_block.rb` — `Shared::StreamedBlock`: one `TextView::Region` + its streaming buffer, lazily opened.
- `input_pane.rb` — `Shared::InputPane`: the prompt; owns Enter, history, the slash palette, paging, `#capture`.
- `prompt_history.rb` — `Shared::PromptHistory`: this session's submissions plus the unsent draft.
- `agent_session.rb` — `Shared::AgentSession`: the turn lifecycle — worker thread, injection, spinner, `Ctrl+C`.
- `leader_menu.rb` — `Shared::LeaderMenu`: the `Ctrl+K` which-key popup; labels may be callables.
- `ui_toggle_menu.rb` — `Shared::UIToggleMenu`: the leader-`u` submenu flipping the two density toggles.
- `slash_command.rb` — `Shared::SlashCommand`: one command as a value object (name / description / callback).
- `slash_menu_popup.rb` — `Shared::SlashMenuPopup`: the `/name` palette; filters, splits the argument, echoes.
- `file_commands.rb` — `Shared::FileCommands`: pikuri's on-disk `.md` prompt templates as slash commands.
- `pending_decision.rb` — `Shared::PendingDecision`: one human decision awaiting an answer; UI-free, Pikuri-free.
- `trifecta_renderer.rb` — `Shared::TrifectaRenderer`: paints pikuri's lethal-trifecta report for `/trifecta`.
- `request_permits.rb` — `Shared::RequestPermits`: installs each server's request ceiling into pikuri.
- `log/ui.rb` — `Shared::Log::UI`: the log subsystem — window, popup, `#wire!`, error tally, `Ctrl+K`.
- `log/popup.rb` — `Shared::Log::Popup`: the `Popup` around the `LogWindow`; resets the tally on dismiss.
- `log/counting_io.rb` — `Shared::Log::CountingIO`: the sink into the `LogWindow` that counts error lines.
- `log/buffering_io.rb` — `Shared::Log::BufferingIO`: the boot sink; tees to `$stderr`, replays after the swap.
- `model/choice.rb` — `Shared::Model::Choice`: a connection's display name paired with its `ChatTransport`.
- `model/picker.rb` — `Shared::Model::Picker`: the leader-menu model switcher (catalog, pending switch, popup).
- `markdown/renderer.rb` — `Shared::Markdown::Renderer`: Markdown → ANSI, the single entry point.
- `markdown/ansi_converter.rb` — `Shared::Markdown::AnsiConverter`: the kramdown converter doing it; honors `NO_COLOR`.
- `markdown/streaming_buffer.rb` — `Shared::Markdown::StreamingBuffer`: rewrites a region in place from deltas.
- `markdown/passthrough_buffer.rb` — `Shared::Markdown::PassthroughBuffer`: the render-free variant, for display-form streams.
- `markdown/grayscale.rb` — `Shared::Markdown::Grayscale`: repaints ANSI as one muted fg, for reasoning.
