# Clipboard image paste — `Ctrl+V` attaches the clipboard's image

Goal: `Ctrl+V` pastes a clipboard image as an attachment; text paste stays the terminal's own
(`Ctrl+Shift+V`), as in Claude Code. The `@path` / `/image` way in has shipped, and so has the
refusal on a blind model (`D_attachment_token`, `D_attachment_refusal`); this is what's left of
the image-attachments idea. The sibling idea is pikuri-web's `design/ideas/image-attachments.md`.

## What Tuile already gives (0.17.0)

- **`Ctrl+V` reaches us as a key** — `Tuile::Keys::CTRL_V` (`"\x16"`) through `handle_key?`; no
  Tuile widget binds it. Raw mode turns off the tty's `lnext`, so nothing eats it on the way.
- **A terminal paste never carries an image.** The terminal reads `text/plain` itself and hands
  it over bracketed (mode 2004) as one `Component#handle_paste(text)` (Tuile's bracketed-paste
  decision). With an image on the clipboard `Ctrl+Shift+V` sends nothing useful, so image paste has
  to be *us* reading the clipboard on the `Ctrl+V` key.

## Reaching the clipboard — sketch

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
- **Refuse before writing anything** when the model can't see images: ask
  the `App`'s `attachment_refusal` before the temp file, as `/image` does before the token.
- **A pasted image becomes an ordinary `@path` token.** Write the bytes to
  `$XDG_RUNTIME_DIR/pikuri-tui/paste-<n>.<ext>` and insert the `@path` at the caret (quoted through
  `Shared::AttachmentTokens.token`). There is no `XDG_*_TEMP`; `XDG_RUNTIME_DIR`
  (`/run/user/<uid>`) is the closest: per-user, `0700`, tmpfs and cleared on logout. When it's
  unset, fall back to a `0700` dir under `Dir.tmpdir`; write the file `0600`. So this adds no
  second staging path: the token can be seen and deleted like a typed one, and resubmitting it
  from history works for as long as the file survives. After a logout it fails like any other
  missing path.
- Run the probe off the UI thread with a timeout — `xclip` can block on an unresponsive selection
  owner — and marshal the inserted token back through `event_queue.submit`.
- Privacy holds: the clipboard is read only on an explicit keystroke, and nothing leaves the
  machine that the user didn't attach.
- Where it lives: a small `Shared::` block (say `Shared::ClipboardImage`); the input pane binds the
  key and inserts the `@path` it returns.
- The owner's own setup (Alacritty → ssh → tmux in a VM, no `DISPLAY`, only `xsel`) is exactly the
  "no clipboard reachable" case — `@path` / `/image` are the main way in there.

## Is this a Tuile feature request? Not yet

"Terminal capabilities" can't answer the ssh question: whether *this host's* clipboard is the
user's is a question about the display, which Tuile sees no better than we do. The one thing Tuile
could own is reading the clipboard **through the terminal**, which also works over ssh — and for
images that is narrow: OSC 52 carries text only and most terminals disable reading it; kitty's
clipboard protocol (OSC 5522, MIME types, images included) is the only image-capable one I know of,
tmux needs `allow-passthrough` for it, and Alacritty doesn't speak it. Revisit as a Tuile idea
(probe + `Screen#read_clipboard(mime)`) if a kitty user asks for it.
