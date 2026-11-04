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

## Input (decided)

- **v1: `@path` tokens and `/image <path>`.** A terminal pastes a dragged file as its path, so
  drag-and-drop comes free — but only when the TUI runs on the machine the file was dragged from;
  over ssh the dropped path names a file on the *local* host, so it must fail with a clear
  "no such file", not a silent drop.
- **v2: `Ctrl+V` pastes a clipboard image**; text paste stays the terminal's own
  (`Ctrl+Shift+V`), as in Claude Code.

### What Tuile already gives (0.17.0)

- **`Ctrl+V` reaches us as a key** — `Tuile::Keys::CTRL_V` (`"\x16"`) through `handle_key?`; no
  Tuile widget binds it. Raw mode turns off the tty's `lnext`, so nothing eats it on the way.
- **A terminal paste never carries an image.** The terminal reads `text/plain` itself and hands
  it over bracketed (mode 2004) as one `Component#handle_paste(text)` (`D_bracketed_paste` in
  Tuile). With an image on the clipboard `Ctrl+Shift+V` sends nothing useful, so image paste has
  to be *us* reading the clipboard on the `Ctrl+V` key.

### Reaching the clipboard — v2 sketch

- Probe in order, on the keystroke: `WAYLAND_DISPLAY` + `wl-paste` → `wl-paste --list-types`;
  else `DISPLAY` + `xclip` → `xclip -selection clipboard -t TARGETS -o`; pick the first of
  `image/png`, `image/jpeg`, `image/gif`, `image/webp` and read it with `--type` / `-t`. `xsel`
  is text-only — not a fallback.
- **Decide on "is a display reachable", not "are we over ssh".** `SSH_CONNECTION` is the wrong
  signal both ways: `ssh -X` forwards `DISPLAY` and `xclip` then reads the user's real clipboard,
  while a tmux session keeps whatever env it was started with, a stale `DISPLAY` included. So a
  probe that exits non-zero ("Can't open display") counts as no clipboard.
- The outcomes are status-line messages, never a crash: no display → "no clipboard reachable
  here (over ssh?) — attach with @path"; no tool → "install wl-clipboard / xclip"; no image →
  "no image on the clipboard".
- **A pasted image becomes an ordinary `@path` token.** Write the bytes to
  `$XDG_RUNTIME_DIR/pikuri-tui/paste-<n>.<ext>` and insert the `@path` at the caret. There is no
  `XDG_*_TEMP`; `XDG_RUNTIME_DIR` (`/run/user/<uid>`) is the closest: per-user, `0700`, tmpfs and
  cleared on logout. When it's unset, fall back to a `0700` dir under `Dir.tmpdir`; write the file
  `0600`. The result is that v2 adds no second staging path. The token can be seen and deleted in
  the input pane like a typed one, and resubmitting it from history works for as long as the file
  survives. After a logout it fails like any other missing path.
- Run the probe off the UI thread with a timeout — `xclip` can block on an unresponsive selection
  owner — and marshal the inserted token back through `event_queue.submit`.
- Privacy holds: the clipboard is read only on an explicit keystroke, and nothing leaves the
  machine that the user didn't attach.
- Where it lives: a small `Shared::` block (say `Shared::ClipboardImage`); the input pane binds the
  key and inserts the `@path` it returns.

### Is this a Tuile feature request? Not yet

"Terminal capabilities" can't answer the ssh question: whether *this host's* clipboard is the
user's is a question about the display, which Tuile sees no better than we do. The one thing Tuile
could own is reading the clipboard **through the terminal**, which also works over ssh — and for
images that is narrow: OSC 52 carries text only and most terminals disable reading it; kitty's
clipboard protocol (OSC 5522, MIME types, images included) is the only image-capable one I know of,
tmux needs `allow-passthrough` for it, and Alacritty doesn't speak it. Revisit as a Tuile idea
(probe + `Screen#read_clipboard(mime)`) if a kitty user asks for it.

## Open questions

- `Q_staging` — is a staged attachment visible in the input pane before submit (a chip/line you
  can remove), or only in the transcript after?
- `Q_refusal` — on a blind model: grey out / refuse at staging time via `agent.modalities`, or
  let `UnsupportedAttachmentError` surface as a status message? (`modalities` is `nil` until the
  first turn's probe — the first turn can't be pre-checked.)
- `Q_tool_images` — `read` returning an image already works; should the transcript show it the
  same way (the tool's display line already says `Returned image/png, 27.1 kB`)?
