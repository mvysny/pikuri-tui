# bin → App agent ownership (chat + computer done; code next)

Chat is done and is the **template**. Computer now follows it too. Apply the
same shape to `Code::App` — the last one — next session, then delete this file.

## The pattern (as landed in Chat)

1. `App.new(config:)` — App derives its model list from `config.llms` and
   builds its own agent. The bin only does CLI + config + screen mount.
2. Agent construction lives in a private `App#default_build_agent` that
   references App's own collaborators (conversation listener, footer,
   confirmer, task listener, …) through its ivars — **no parameters.**
3. The build block is an **optional test/override seam, called with no
   arguments**, returning an agent (or stub). No yieldparams.

The big realization: the block's yielded object list was pure vestige from
when the block was the *production* wiring seam in the bin. Once App owns
the build, those objects are App's own ivars — the fix isn't a tidier way
to pass five objects, it's passing **none**.

## code/computer specifics (the partial-win caveat)

Unlike chat, their bins do genuine **pre-screen boot sequencing** that must
stay in the bin (ordering constraints / needs a live terminal):

- project-root discovery + `Dir.chdir` (before workspace/filesystem);
- the interactive **git-trust prompt** (reads/writes the real terminal,
  must run before the alternate screen buffer is up);
- the **bwrap sandbox probe** (raises a backtrace to a normal terminal);
- `--readable`/`--writable` directory validation.

So `Code::App` likely takes `config:` **plus** a few already-built objects
(`filesystem`, `sandbox`, `trusted_repo`, `skill_catalog`, `mcp_registry`)
rather than a bare `config:`. Draw the line at "must happen before the screen
/ needs a live terminal" (bin) vs "pure agent+tool+extension object graph"
(App).

### What actually landed for computer (surprise: NO passed-in objects)

Computer collapsed all the way to `Computer::App.new(config:,
internet_enabled:, profile_dir:)` — chat's shape plus two bin-local flags,
**no** `filesystem`/`sandbox`/`plan_mode`/`tool_formatters` params. Two
findings drove it:

1. **`Tuile::Screen.new` does NOT enter raw mode / the alt buffer** — that's
   `run_event_loop` (`$stdin.raw do event_loop end`, its own `ensure`
   restores). So the "bwrap probe must be pre-screen" constraint was weaker
   than assumed: a raise during `App.new` still hits a cooked terminal. The
   bin just wraps `App.new`/`run` in `begin/ensure Tuile::Screen.close` (which
   also covers `App.new` failures that `#run`'s own `ensure` would miss — so
   `Computer::App#run` no longer closes the screen itself).
2. **Test-safety is about *placement*, not params.** `filesystem`
   (`AllowAll`, cheap, no probe) is built in the ctor; the **sandbox
   (`FullFsNoNet`, the probing one) is built inside `default_build_agent`** —
   the production-only path the test block replaces — so specs never hit the
   bwrap probe. `plan_mode` / `tool_formatters` / `token_log` / `models` all
   became App ivars (they were only params to share objects with the bin's old
   build block; once App owns the build, nothing to share).

Code will differ: its filesystem depends on `skill_catalog.roots`, has the
yolo `AllowAll`-vs-`Filesystem` branch + `--readable/--writable` validation
(warn+exit), and the git-trust prompt genuinely needs the live pre-screen
terminal — so those stay in the bin and get passed in. Parallel copies, not
identical — as intended.

## MUST FIX while there: the `StubAgent` top-level-constant collision

All three App specs declare `class StubAgent` inside their
`RSpec.describe … do` block. In Ruby that defines the **same top-level
constant**, reopened across the three files — so `StubAgent#initialize` is
whatever the last-loaded file defined. It was benign only because all three
had identical `initialize(listener, …)`; the moment chat's signature
diverged, the full suite broke (chat-alone still passed).

Chat's is `ChatStubAgent`; computer's is now `ComputerStubAgent` (and dropped
its `listener` positional to match `ChatStubAgent` — App wires its own
listeners into the real/default agent now). **Code's spec still declares bare
`class StubAgent`** — no collision *today* (it's the only one left using the
name), but rename it to `CodeStubAgent` when refactoring code so the trap
never returns. (This is also why isolated-vs-full-suite runs can disagree:
always run the full `bundle exec rspec` after touching a spec's shared-looking
helper.)

## Relation to testing-with-agent

This removes the **yieldparams** with no upstream dependency. The **block
itself** only survives to dodge building a real (network-touching) agent;
testing-with-agent (see `agent-two-phase-init.md`) removes that last reason
— tests then use the production path with at most a one-object `transport:`
seam, or none at all if the fake is HTTP-level.
