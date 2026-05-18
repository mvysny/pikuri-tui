# pikuri-tui

TUI front-ends for [pikuri](https://codeberg.org/mvysny/pikuri), built on
[tuile](https://github.com/mvysny/tuile).

The upstream `pikuri` gem ships `Pikuri::Agent`, `Pikuri::Tool::*`, and
prompts as a library. Its repository also includes `bin/pikuri-chat` and
`bin/pikuri-code`, but those are plain stdin/stdout REPL demos. This
project will reimplement both as Tuile TUI apps (log pane + input field
+ status bar), reusing pikuri's Agent / Tool / Listener interfaces.

## Status

Scaffold only. Just `Gemfile` so far — no `bin/`, no `lib/`, no specs.

## Layout (planned)

- `bin/pikuri-chat` — Tuile TUI chat app.
- `bin/pikuri-code` — Tuile TUI coding agent.
- `lib/pikuri_tui/` — shared TUI shell (Tuile listener, layout, input
  handling) consumed by both bin scripts.

## Dependencies

- `tuile` — terminal UI framework (Ruby 3.4+). Requires single-threaded
  UI mutation; agent work runs on a background thread and marshals
  results back via `screen.event_queue.submit { … }`.
- `pikuri` — pulled in from a local checkout at `../pikuri` for now;
  switch to a published version (or git source) once one is available.

## Running

```
bundle install
# bin scripts not implemented yet
```
