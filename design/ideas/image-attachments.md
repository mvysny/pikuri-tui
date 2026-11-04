# Image attachments — show the model a picture

Goal: let the user hand the agent an image ("what's wrong in this screenshot?") from the TUI,
before a turn and while one runs. The sibling idea is pikuri-web's
`design/ideas/image-attachments.md`.

## State — paused 2026-11-04

**v1 is built**, except the early refusal checks. pikuri is pinned at `05b6d97`, which carries
the attachment API; no `Extension#on_user_message` override exists here, so its new third
argument broke nothing.

| Piece | Where |
|---|---|
| `@path` tokens split out on submit; a bad token refuses the line with an alert and keeps it | `Shared::AttachmentTokens.split`, `InputPane::Area#submit` |
| `attachments:` through both pikuri call sites; mid-turn leftovers re-sent as a fresh turn keep theirs | `Shared::AgentSession#submit` / `#deliver_pending_injections` |
| dim `📎 shot.png (image/png, 48.3 kB)` line per image under the user turn | `Shared::ConversationTextView::Listener#attachment_line` |
| `/image <path>` in all three shells: validates, puts the token first, caret after it | `Shared::AttachmentTokens.token`, `Shared::InputPane#attach` |
| late refusal: pikuri's `UnsupportedAttachmentError` → alert + the line back from history | `AgentSession#on_attachment_refused` → `InputPane#refuse_attachment` |

**Left, in order:**

1. **Early refusal checks** — blocked on `Q_refusal_primitive` below. Three call points: `/image`
   before inserting the token, `Area#submit` before the clear, `AgentSession#queue_mid_turn` before
   `inject_user_message` (today a mid-turn image to a blind model gets pikuri's
   `[shot.png not shown: …]` note instead of an alert).
2. **Try it live** — everything so far is checked by specs only, never against a real vision and a
   real blind model.
3. **v2: `Ctrl+V`** — the clipboard sketch below.
4. **Graduate** this file once v1 ships: decisions to `design/decisions.md`, then delete.

## Open questions

- `Q_refusal_primitive` — pikuri's `Agent#attachment_refusal(attachment)` (MIME family → modality
  → reason, `nil` when unknown) is **private**. Every early check needs exactly it; copying the
  mapping here would drift. Recommended: make it public in pikuri, bump the pin, then build the
  three checks. Whichever way: a pending model switch (`Model::Picker`) is applied only at the
  top of the next `run_loop`, so a pre-check must stand down while one is pending — it would ask
  the old model.

## Input (decided)

- **v1: `@path` tokens and `/image <path>`.** A terminal pastes a dragged file as its path, so
  drag-and-drop comes free — but only when the TUI runs on the machine the file was dragged from;
  over ssh the dropped path names a file on the *local* host, and fails as "No such file".
- **v2: `Ctrl+V` pastes a clipboard image**; text paste stays the terminal's own
  (`Ctrl+Shift+V`), as in Claude Code.

## Staging (decided)

- **The staged attachment is the `@path` token in the input pane** — no chip, no hidden state.
  It's visible, removable by editing, and survives history recall; every way in ends as one.
- **`/image <file>` puts `@<file> ` at the front of the input with the caret behind it** for the
  question. It can't be a staging command proper: a line starting with `/` goes whole to the slash
  menu (`InputPane::Area#submit_command`), so it can't carry the question, and holding the image
  for the next submit would need exactly the hidden state ruled out above. Everything after
  `/image` is the path, so an unquoted one with spaces works; the token is quoted when needed.
- What `/image` adds over typing the token: palette discoverability, and validation before the
  question is typed — exists, ≤ 5 MiB, PNG/JPEG/GIF/WebP (and the model's vision, once
  `Q_refusal_primitive` lands).
- **Our own parser, not a port of pikuri's CLI helper** (`pikuri-core/bin/chat_attachments.rb`):
  the TUI's input surface (`/image`, `Ctrl+V`) is its own. Deliberate differences: each token
  leaves its file's basename in the text, so "compare @a.png with @b.png" still says which image
  is which (the CLI drops the token); sentence punctuation behind a bare token stays text.

### What Tuile already gives (0.17.0)

- **`Ctrl+V` reaches us as a key** — `Tuile::Keys::CTRL_V` (`"\x16"`) through `handle_key?`; no
  Tuile widget binds it. Raw mode turns off the tty's `lnext`, so nothing eats it on the way.
- **A terminal paste never carries an image.** The terminal reads `text/plain` itself and hands
  it over bracketed (mode 2004) as one `Component#handle_paste(text)` (Tuile's bracketed-paste
  decision). With an image on the clipboard `Ctrl+Shift+V` sends nothing useful, so image paste has
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
- The outcomes go to the same "Can't attach" alert, never a crash: no display → "no clipboard
  reachable here (over ssh?) — attach with @path"; no tool → "install wl-clipboard / xclip"; no
  image → "no image on the clipboard".
- **A pasted image becomes an ordinary `@path` token.** Write the bytes to
  `$XDG_RUNTIME_DIR/pikuri-tui/paste-<n>.<ext>` and insert the `@path` at the caret (quoted through
  `Shared::AttachmentTokens.token`). There is no `XDG_*_TEMP`; `XDG_RUNTIME_DIR`
  (`/run/user/<uid>`) is the closest: per-user, `0700`, tmpfs and cleared on logout. When it's
  unset, fall back to a `0700` dir under `Dir.tmpdir`; write the file `0600`. So v2 adds no second
  staging path: the token can be seen and deleted like a typed one, and resubmitting it from
  history works for as long as the file survives. After a logout it fails like any other missing
  path.
- Run the probe off the UI thread with a timeout — `xclip` can block on an unresponsive selection
  owner — and marshal the inserted token back through `event_queue.submit`.
- Privacy holds: the clipboard is read only on an explicit keystroke, and nothing leaves the
  machine that the user didn't attach.
- Where it lives: a small `Shared::` block (say `Shared::ClipboardImage`); the input pane binds the
  key and inserts the `@path` it returns.
- The owner's own setup (Alacritty → ssh → tmux in a VM, no `DISPLAY`, only `xsel`) is exactly the
  "no clipboard reachable" case — `@path` / `/image` are the main way in there.

### Is this a Tuile feature request? Not yet

"Terminal capabilities" can't answer the ssh question: whether *this host's* clipboard is the
user's is a question about the display, which Tuile sees no better than we do. The one thing Tuile
could own is reading the clipboard **through the terminal**, which also works over ssh — and for
images that is narrow: OSC 52 carries text only and most terminals disable reading it; kitty's
clipboard protocol (OSC 5522, MIME types, images included) is the only image-capable one I know of,
tmux needs `allow-passthrough` for it, and Alacritty doesn't speak it. Revisit as a Tuile idea
(probe + `Screen#read_clipboard(mime)`) if a kitty user asks for it.

## Refusal on a blind model (decided)

- **Refuse as early as `agent.modalities` allows, and refuse the whole attempt**, text included —
  never send the text and drop the image. Earliest points: `/image` and (v2) `Ctrl+V` refuse before
  inserting a token, or writing a temp file; a typed `@path` is refused at submit, before
  `run_loop`.
- **One surface for every refusal: `Tuile::Component::ConfirmDialog.alert("Can't attach", …)`** —
  the one-button dialog sized to its message (`InfoDialog` takes half the screen). A missing,
  oversized or non-image file uses it too. No greyed chips — they'd need colour a terminal may not
  render, and there are no chips anyway (see Staging). While `modalities` is still `nil` (the first
  turn's probe hasn't run), `run_loop` raises `UnsupportedAttachmentError` on the worker before
  appending anything; the session marshals it back to the same alert. The user can't tell which
  path refused.
- **Not a breach of `D_transcript_confirmer`.** That rules out a modal for questions that open
  *unbidden* mid-typing. This one answers the user's own Enter / `Ctrl+V` / `/image`, and asks
  nothing — dismissing it decides nothing.
- **The refused line survives.** The submit-time check runs before `Area#submit`'s clear and
  leaves the line in place; on the late path the line comes back from history, unless the user
  has typed something since.
- **Mid-turn there's always an answer:** the turn in flight already probed `modalities`, so
  `inject_user_message` can be pre-checked the same way. pikuri's withhold-with-a-note is only the
  backstop.

## Images a tool returns (decided: no change)

`read` on an image already sends the bytes to the model, and the transcript's generic tool line
already says so (`Read(docs/shot.png)` / `Returned image/png, 27.1 kB`). It gets no `📎` line:
`Event::ToolResult` carries only the text note, so spotting an image would mean parsing pikuri's
summary back out and restyling it — the tui-side remap `D_short_tool_lines` rules out. If a `📎`
line there is ever wanted, the primitive is an `attachments` field on `ToolResult`, pikuri's to
add. The two also mean different things: `📎` under a user turn is "you sent this", a tool line is
"the agent chose to look". Rendering the image itself (sixel / kitty graphics) is a separate idea,
Tuile's to own.
