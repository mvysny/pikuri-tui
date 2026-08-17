# Upstream pikuri: slash commands + path-gated skills

What landed upstream, what it breaks here, and what we need to add.
Investigated against `../pikuri` @ `e459865`.

## 0. The blocker (not optional, do this first)

`Skill::Extension.new` now **requires `root:`** — the absolute `Pathname` a
model-supplied touched path is resolved against before it is matched against a
skill's `paths:`.

```
CHANGELOG: **Breaking:** `Skill::Extension.new` now requires `root:` …
           `bin/pikuri-code` passes `project_root`.
```

`lib/code/app.rb:381` still calls `Pikuri::Skill::Extension.new(catalog: @skill_catalog)`.
Result: **37 of 636 specs fail**, all with `ArgumentError: missing keyword: :root`,
all from that one line. Nothing else in the tree is behind upstream.

Fix: `Pikuri::Skill::Extension.new(catalog: @skill_catalog, root: @filesystem.project_root)`.

That one keyword also *arms the gate*, which is what §1 is about.

## 1. Path-gated skills

### What upstream does

A skill whose frontmatter declares `paths:` (a gitignore-dialect glob list) is
**withheld entirely**: not in `<available_skills>`, not loadable by name, and
the catalog does not advertise its own incompleteness. When a `read` / `write` /
`edit` names a matching path, `Skill::PathActivationListener` (registered by
`Skill::Extension` at `before_tool_call`) promotes it — `Activation#activate`
records it, `Extension#announce` injects a `<available_skills>` block through the
interloper and emits `Skill::Promoted(skills:, path:)`. `/clear` re-hides
everything (`on_conversation_reset` → `Activation#reset`).

Three activation flavours: `Activation` (the gate), `Activation::Open` (no
interloper ⇒ no channel for a promotion ⇒ gate off wholesale, with a warn),
`Activation::Sealed` (sub-agents — a gated skill is a name the child was never
told; `SkillTool#for_sub_agent` hands it over).

We wire an `interloper:` (`lib/code/app.rb:352`), so **our gate arms for real.**

### What this breaks here

`Code::App#skill_commands` builds one `/<skill-name>` per `@skill_catalog.list`
entry — the *unfiltered* catalog — and its callback calls
`@skill_ext.schedule_load_skill(name)`, which now **raises `KeyError` for a
gated skill that has not fired**. The callback runs deferred on the event queue,
so this is an uncaught exception on the UI thread, not a graceful refusal.

This is live, not hypothetical: `~/.claude/skills` currently holds five gated
skills — `tuile`, `writing-rdoc`, `writing-javadoc`, `karibu-testing`,
`ideas-folder` — two of which are the ones you'd reach for *in this repo*.

And it isn't just a crash to rescue. `DECISIONS.md` `D-skill-path-activation`,
decision 7, is explicit that the gate binds us:

> The gate is the **default at every surface**, not the model's alone:
> `schedule_load_skill` refuses a pending skill exactly as the tool does, **and
> so must any future picker or typed `/name`**. […] decision 7 closed the
> operator exemption.

So the palette must not merely survive a gated skill — it must not *list* one.

### Proposal

1. **Source the skill commands from the activation, not the catalog.**
   `@skill_ext.activation.names` is the set in play right now; build
   `/<name>` from that. (`Activation#get` is the same gate `schedule_load_skill`
   applies, so the callback can no longer raise.)

2. **The palette catalog becomes dynamic.** `Shared::SlashMenuPopup#commands=`
   already exists as a setter — re-set it when the set changes. Two triggers,
   both agent events, both arriving on the worker thread and needing
   `screen.event_queue.submit`:
   - `Pikuri::Skill::Promoted` → recompute (a skill appears);
   - `Pikuri::Agent::Event::Reset` → recompute (`/clear` re-hides them).

3. **Own it in a listener component**, not in `App`. A
   `Code::SkillCommandListener < Pikuri::Agent::Listener::Base` that holds the
   activation + the popup + the built-in reserved names and re-sets the catalog
   on those two events. Direct sibling of `Code::PlanModeListener`, which is
   already "a listener driving one piece of chrome off one pikuri event" — the
   precedent and the naming are both there. `App` builds it and adds it to the
   `ListenerList`; the rebuild logic lives in one box with one job.

4. **Render the promotion as a line, not as XML.** `Extension#announce` injects
   `Renderer.format_promotion(skills)` — an 8-ish-line `<available_skills>` XML
   block — which drains as `Event::SystemInjected` and our
   `Shared::ConversationWindow::Listener` currently prints *whole*, dim, with a
   `⊕`. Unprompted 8-line XML dumps mid-transcript, several per session once
   the gate is armed. Add a `Skill::Promoted` case arm rendering the one-liner
   it already knows how to make (`Promoted#to_s` → `"skills available:
   writing-rdoc (matched lib/foo.rb)"`) and suppress the paired
   `SystemInjected`.

   Same disease, already shipped: a `/writing-rdoc` load dumps the **entire
   SKILL.md body** into the pane as a dim block. Worth collapsing both — a
   `SystemInjected` whose content is a `<skill …>` or `<available_skills>`
   wrapper renders as one line. (Open question: where does the recognition
   live — a regex in our listener, or do we ask pikuri for a rendered-form
   accessor on the event? Our listener is the cheap answer and the honest
   layering is upstream's.)

5. Nothing to do for `when-to-use:` / `Skill::Trigger` — renderer-side upstream,
   invisible to the shell. Nothing to do for `for_sub_agent`:
   `PathActivationListener` opts itself out and `SkillTool` seals the child.

## 2. Slash commands (`Pikuri::Command`)

### What upstream does

`Command::Registry` scans `.pikuri/commands` then `.claude/commands` under each
search base for `.md` prompt templates. `/name` is the **path** (`commands/frontend/deploy.md`
→ `/frontend:deploy`); a frontmatter `name:` is ignored with a warn. `Renderer.expand`
substitutes `$ARGUMENTS` / `$1`…`$9` (1-based, fence- and code-span-aware) and
appends `ARGUMENTS: <raw>` when the body references neither. The result **is the
human's own user turn** — never a `:system` block.

Never advertised to the model, so it costs zero resident tokens. Two refusals,
raised at `get` as `RefusedError` so typing `/foo` explains itself:
`allowed-tools:` (a narrowing pikuri can't honour) and a `` !`cmd` `` body
directive (a shell command pikuri never runs). Refused commands **stay in
`#list`** so a menu can still show them.

`Command::Extension` registers no tool and renders no prompt — it exists solely
so `Trifecta` sees the command surface's `untrusted` leg. Without it `/trifecta`
under-reports.

Live inventory on this machine: `~/.claude/commands/{grill-me,wh}.md`. No
`.claude/commands` or `.pikuri/commands` in this repo.

### Proposal

1. **Build the registry in the bin, not in `App`** — same seam as
   `skill_catalog`, and for the same concrete reason: `registry.roots` has to
   fold into `Workspace::Filesystem`'s `readable:` (which `bin/pikuri-tui-code`
   assembles pre-screen) so the model can `read` a file a command body points
   at. `bin/pikuri-code` does exactly this. New `command_registry:` constructor
   arg on `Code::App`, documented in the same "what's pre-screen and why"
   paragraph as `skill_catalog:`.

2. **Wire `Command::Extension`** in the agent build block, next to
   `Skill::Extension`. Declaration only — but `/trifecta` is a headline feature
   here and an unwired command surface makes it lie.

3. **Map each command onto a `Shared::SlashCommand`:**

   ```ruby
   Shared::SlashCommand.new("/#{cmd.name}", cmd.description, ->(rest) {
     @session.submit(@command_registry.expand(cmd.name, arguments: rest))
     nil                       # the turn is its own transcript record
   rescue Pikuri::Command::RefusedError => e
     @screen.theme.error(e.message)   # the outcome channel is exactly this
   })
   ```

   The `SlashCommand` outcome-String channel (non-nil ⇒ echoed under the name)
   is already the right shape for a refusal, so a refused command stays listed
   and explains itself on Enter — which is what upstream's "keep it in `#list`"
   is for. Give it a marked hint (`"#{cmd.description} (unavailable)"`) so the
   palette says so before you press Enter.

4. **`argument_hint`** (`"<label> [--since DATE]"`) has nowhere to go today.
   Either fold it into the description string, or add a 4th optional member to
   `Shared::SlashCommand` and a third column to `SlashMenuPopup#row`. Recommend
   the string fold first; the member is easy to add later if the palette starts
   feeling cramped.

5. **Boot log line**, mirroring the skill one in `bin/pikuri-tui-code`:
   `main_log.info("Loaded N command(s): /a, /b (unavailable)")`.

## 3. The collision rule

Three namespaces now compete for one typed `/name`. Upstream's `Registry` rdoc
states the ordering and the reason:

> A host resolving a typed `/name` owes one more rule, since nothing here sees
> the other two namespaces: **host built-in > command > skill**. Match built-ins
> first or a cloned repo shipping `.claude/commands/plan.md` captures a `/plan`
> that flips a safety gate.

Which matches the call already made for this project: **collisions are rare;
warn in the log, show only the winner in the slash menu.**

Implement as one ordered fold in `build_slash_commands`, generalizing the
existing `skill_commands(reserved_names)` reserve pass:

1. built-ins — `/logs`, `/trifecta`, `/diff`, `/plan`, `/model`, `/clear`,
   `/exit`, `/quit`;
2. file commands — skip a name a built-in took, `LOG.warn`;
3. skill commands (in play only) — skip a name either took, `LOG.warn`.

What a loser costs: a shadowed **skill** stays reachable by asking the agent in
plain language (that's the existing note, and it survives); a shadowed **file
command** is genuinely unreachable, and the warn is the whole remedy — which is
the tradeoff accepted here rather than an oversight. Say so in the rdoc so the
next reader doesn't "fix" it.

Note step 3's set is recomputed on promotion (§1.2), so the reserve pass runs
again each time — one more reason it belongs in the listener component rather
than inline in `App`.

## 4. Which shells get what

| | skills | path gate | file commands |
|---|---|---|---|
| `chat` | — | — | **recommend no** |
| `code` | has them | **must fix** | **add** |
| `computer` | — | — | **recommend yes** |

- **code** — both, as above.
- **computer** — commands only. Costs `pikuri-skills` in the `:computer`
  Bundler group; the gem's sole dependency is `pikuri-core`, so it's a load-path
  line and nothing more. pikuri's own `bin/pikuri-assistant` is the precedent
  (`Registry.new(search_bases: [Dir.pwd, Dir.home])`, both bases unvouched
  because a non-containment binary can make no claim). A desktop assistant with
  `/wh` and `/grill-me` is a real win. Its filesystem is full-fs, so
  `registry.roots` needs no `readable:` fold.
- **chat** — recommend leaving it out. "The heavier gems stay off the chat
  process's load path" is a stated scope decision, chat has no project root to
  scan, and `pikuri-skills` in `:default` would be the first crack in it. Cheap
  to reverse if you disagree — it's one `groups:` edit and the same mapping code.

## 5. Adjacent, deliberately not in this idea

**Bundle trust grading** (`Bundle::Base(dir:, trusted:)`) shipped in the same
window and feeds *both* the catalog and the registry — the same `search_bases:`
list. We pass bare paths (`[project_root, Dir.home]`), which means `trusted:
false`, which means every skill and every command grades `untrusted: :hard` in
`/trifecta`. `bin/pikuri-code` asks a third startup question ("are this repo's
sources your own work?") and vouches for `Dir.home` on a property it can check
(`sandbox_enabled || confirm_enabled`).

We already own the persisted-one-time-question machinery (`Code::TrustStore`,
`Code::PrivacyStore`), so this is a natural fit — but it is a third boot prompt
and a separate decision. Its own idea file.

`Trifecta::Contribution#label` needs nothing: `Shared::TrifectaRenderer` renders
what pikuri hands it and never hardcoded `(mcp)`.

## 6. Specs owed

- gated skill absent from the palette; present after a `read` of a matching
  path; absent again after `/clear`;
- `/<gated-skill>` never raises (it isn't listed, and `Activation#get`
  double-gates the callback);
- `Promoted` renders one line, and the paired `SystemInjected` XML doesn't;
- a file command expands and submits as a user turn (`$ARGUMENTS`, and the
  `ARGUMENTS:` tail);
- a refused command lists, and echoes its reason in red instead of running;
- the three-way precedence: built-in wins over a same-named file command wins
  over a same-named skill, each loser warned once.

Anything crossing the worker thread mounts `fake_screen` + `wait_until`
(`spec/support/marshalling_fake_screen.rb`), per the convention.

## 7. Order of work

1. `root:` — unblocks the suite (§0).
2. Gate the skill palette + the promotion listener (§1) — this is a *bug fix*,
   not a feature: without it a gated skill's `/name` raises on the UI thread.
3. Promotion / skill-load transcript collapse (§1.4).
4. File commands in the coding shell (§2 + §3).
5. File commands in the computer shell (§4).

## Open questions

- **The expanded turn is what the pane shows.** `/wh swingai` submits the
  expanded template, so `> …` in the transcript is the whole body, not what was
  typed. Leaning: leave it — the human should see what was actually sent — but
  a long template is a wall. Alternative: echo `/wh swingai` as the user line
  and keep the expansion out of the pane (it stays in the agent's log either
  way).
- **Where does `SystemInjected` collapse belong** — a regex in our listener, or
  ask upstream for a display form on the event?
- **chat**: really no? (§4)
