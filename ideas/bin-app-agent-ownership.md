# bin → App agent ownership (chat done; code/computer next)

Chat is done and is the **template**. Apply the same shape to `Code::App`
and `Computer::App` next session.

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
(`filesystem`, `sandbox`, `plan_mode`, `trusted_repo`, `skill_catalog`,
`mcp_registry`, `tool_formatters`) rather than a bare `config:`. Draw the
line at "must happen before the screen / needs a live terminal" (bin) vs
"pure agent+tool+extension object graph" (App).

## MUST FIX while there: the `StubAgent` top-level-constant collision

All three App specs declare `class StubAgent` inside their
`RSpec.describe … do` block. In Ruby that defines the **same top-level
constant**, reopened across the three files — so `StubAgent#initialize` is
whatever the last-loaded file defined. It was benign only because all three
had identical `initialize(listener, …)`; the moment chat's signature
diverged, the full suite broke (chat-alone still passed).

Chat's is now renamed `ChatStubAgent` as a stopgap. When refactoring
code/computer, give each spec its own isolated stub — `CodeStubAgent` /
`ComputerStubAgent`, or better `stub_const('…', Class.new { … })` — so the
constant is never shared. (This is also why isolated-vs-full-suite runs can
disagree: always run the full `bundle exec rspec` after touching a spec's
shared-looking helper.)

## Relation to testing-with-agent

This removes the **yieldparams** with no upstream dependency. The **block
itself** only survives to dodge building a real (network-touching) agent;
testing-with-agent (see `agent-two-phase-init.md`) removes that last reason
— tests then use the production path with at most a one-object `transport:`
seam, or none at all if the fake is HTTP-level.
