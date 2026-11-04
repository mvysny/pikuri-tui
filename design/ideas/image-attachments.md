# Image attachments — show the model a picture

Goal: let the user hand the agent an image ("what's wrong in this screenshot?") from the TUI,
before a turn and while one runs. To be brainstormed and built in its own session; the sibling
idea is pikuri-web's `design/ideas/image-attachments.md`.

## What pikuri already provides (master as of `ddda137`, 2026-11-04)

Bump the pikuri pin to get them (`bundle update pikuri`):

- `Pikuri::Attachment.new(mime:, filename:, bytes:)` — the only attachment type; read the file
  **once** into bytes (never hand ruby_llm a path).
- `agent.run_loop(user_message:, attachments: [...])` — an attachment-only turn is fine.
- `interloper.inject_user_message(text, attachments: [...])` — the same mid-turn.
- `Event::UserTurn#attachments` — what was actually sent (mid-loop, minus any the model can't
  take; their `[shot.png not shown: …]` notes are then in `content`).
- `agent.modalities` (`{vision: false, …}` from llama.cpp's `/props`): a refused attachment makes
  `run_loop` raise `Pikuri::Agent::UnsupportedAttachmentError` **before** anything is appended;
  mid-turn it is withheld with a note instead. Check `modalities` up front to grey out the
  affordance.
- **Breaking:** `Extension#on_user_message(ctx, content, attachments)` grew a third argument —
  check any override here.
- Reference implementation: pikuri's `pikuri-core/bin/chat_attachments.rb` (`@path` tokens,
  `📎 shot.png (image/png, 48.3 kB)` line, PNG/JPEG/GIF/WebP, 5 MiB cap).

## Where it lands here

- `lib/shared/agent_session.rb` — the two call sites: `run_loop(user_message:, transport:)` and
  `interloper.inject_user_message(message)`; both need `attachments:`.
- `lib/shared/input_pane.rb` — where an attachment gets staged.
- `lib/shared/conversation_text_view.rb` — `UserTurn(content:)` renders as `"> #{content}"`;
  a dim `📎` line per attachment.

## Open questions

- `Q_input` — how does an image get in? `@path` tokens (a terminal pastes a dragged file as its
  path, so drag-and-drop is free), a `/image <path>` command, **clipboard paste**
  (`wl-paste --type image/png` on Wayland, `xclip -selection clipboard -t image/png -o` on X11;
  how does Tuile surface a paste, and which key?), or several.
- `Q_staging` — is a staged attachment visible in the input pane before submit (a chip/line you
  can remove), or only in the transcript after?
- `Q_refusal` — on a blind model: grey out / refuse at staging time via `agent.modalities`, or
  let `UnsupportedAttachmentError` surface as a status message? (`modalities` is `nil` until the
  first turn's probe — the first turn can't be pre-checked.)
- `Q_tool_images` — `read` returning an image already works; should the transcript show it the
  same way (the tool's display line already says `Returned image/png, 27.1 kB`)?
