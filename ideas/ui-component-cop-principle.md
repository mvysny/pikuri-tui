# Idea: UI-component-shaped COP — the architectural principle

Extracted from `ui-component-shaped-cop.md`, which now holds only the
concrete pikuri-tui component shapes (scorecard, the task-pane and git-pane
refactors). This file is the durable, framework-general design idea — the
thing to be backported into (a) the global CLAUDE.md, (b) a new Tuile skill,
and (c) short pointers in this project's docs.

Scratch space, not documentation — not held to the repo's doc rules.

## The principle

When a UI framework is in play, make **"can this be a single UI
component?"** the default target for any new UI-facing piece: subclass the
framework's widget (`TextView`, `TextArea`, `Window`, …), bolt the behavior
/ business logic onto it, and compose those components into bigger ones — a
`Window` frames a `TextView` frames a `TextArea`, each a self-sufficient
box. The unit of composition *is* the unit of the framework.

## Reconciliation with "composition over inheritance"

Composition over inheritance stays **sharp and undiluted** — it remains the
default everywhere. UI is the one honest, widely-accepted **carve-out**:
component-oriented UI frameworks (Swing, Vaadin, Android, Tuile) are
*designed* to be extended by subclassing their widgets — that is their
sanctioned mechanism for building your own components (you extend
`JPanel` / `Composite` / `View` / `TextView`). So the rule reads:

> Compose your own abstractions. Inherit **within the component-building
> chain** — from the framework's widget bases, or from your own abstract
> component bases built on them — to produce a concrete, self-sufficient
> component. That's how a component UI framework expects you to plug in.

Do **not** dress this up as "composition with the framework." It *is*
inheritance; calling it composition dilutes the term we most want kept
sharp. Name it for what it is — the accepted UI-framework exception to
composition-over-inheritance — and the two rules stop fighting.

The chain extends **one rung past the framework**: an in-project *abstract
component base* is a legitimate ancestor, not just the framework's own
classes. In a CRUD app, an `AbstractMasterDetail` (built on the framework's
layout widget) that a `PersonMasterDetail` extends — configuring the person
editors and the fetch — yields a singular, named, standalone component.
Done simply and cleanly, that **subclass-to-configure** shape often *beats*
a generic `MasterDetail<Person>` assembled by a factory: the concrete class
is its own cohesive box with a name, whereas the generic "component" exists
only as a parameterized construction smeared across the factory call site.

So the carve-out is **not** "only framework bases." The sharp line is
*inherit to **be** a component* — specialize a widget, or an abstract
component base, into a concrete component — as opposed to inheriting to
share arbitrary utility code, which composition-over-inheritance still
governs. Reuse of the component base itself is the ordinary UI-inheritance
pattern one level up; reuse of non-component logic is not.

**Boundary — the carve-out *permits* an abstract base, it doesn't *mandate*
one.** The base earns its place only by the same COP test as any component:
is it a genuine, cohesive, reusable abstraction? `AbstractMasterDetail` —
yes. When the commonality across the concretes is shallow, *divergent
scaffolding* rather than a cohesive component — this project's three `App`s —
the test fails and you **still duplicate** (AGENTS.md's "deliberate parallel
copies"). So the carve-out never licenses folding the three shells into an
`AbstractApp`: that's inheriting-to-*share* shallow wiring, which
composition-over-inheritance still governs. No conflict with the
don't-share-a-base rule — same test, opposite verdict because the would-be
base isn't a real component.

## The model/view boundary — a conceptual aid, not a mandatory class split

The widget owns the **view**; data arrives through a **model** that is
agnostic to its source (JDBC, a file, a computed result — Swing's `JTable`
doesn't care). This model/view line is an **architectural aid for
reasoning**, not a rule that the model must be a separate class. In
practice the model half is frequently mixed into the view at class level —
an inner data-provider class, or even a lambda fetching from a service
passed in via the ctor.

Where the model code lives is plain **good-coding-practice sizing**, not
the seam itself:

- **Model code big enough to warrant a class → give it a class** (nested
  inside the view, or standalone).
- **Model code small (e.g. a single fetch from a service) → a tiny lambda
  / inner adapter** right inside the component.

One hard constraint layered on top: **a shared source (1:many — one source
feeding several components) must be injected** as a ctor arg, because a
shared object can't live inside any one component. A dedicated 1:1 source
leaves the sizing question free.

So a background worker (a poll thread, an event stream) is **not "an
exception to being a component"** — it's the **model half**, and the view
half is still a UI component. The spectrum:

- Big, dedicated model → **nested class.** `ConversationTextView` + its
  nested `Listener` (the agent event stream is 1:1; the adapter is big
  enough to warrant a class).
- Small, dedicated model → **lambda / inner adapter.** A view fed by
  `-> { service.fetch }` over a service passed in.
- Shared model → **injected plain service.** `GitWatcher` feeding a summary
  pane *and* a diff pane: 1:many, so injected; the two views are components
  fed from it.

## The render-verb vocabulary is the actual seam

The reusability payoff isn't the subclassing — it's the **small vocabulary
of render verbs** the view exposes (`items=`, `add_block`, …). The model /
adapter speaks *only* those verbs; it never reaches into the widget's
internals. That verb surface **is** the model/view contract — it's why the
view is testable and reusable without the real data source (you can drive
it from a spec by calling verbs). When designing a UI component, the verb
vocabulary is the deliverable to think about first, not an afterthought.

## Threading consequence (Tuile-specific — belongs in the skill)

Inverting to *widget-owns-rendering* moves rendering **onto the UI thread**
(Tuile is single-threaded: every UI mutation runs on the event-loop
thread). So a model half that runs off-thread (a poll thread, an agent
worker) must **marshal each render across** via `screen.event_queue.submit
{ … }`. This is a real, weighable cost of the pattern: `GitWatcher`
currently renders on its *poll* thread, so a resize re-renders off-thread
on the next poll; making the view own rendering pushes that work onto the
UI thread. Weigh per case (accept it if rendering is cheap vs. repaint
frequency, or keep the model emitting display-ready strings so the view
stays a thin sink — the model/view split still holds either way).

## The "genuinely *not* a component" exceptions — RESOLVED

Both sub-questions that were open here collapse into **one rule**:

> A piece should be a component **iff the framework exposes an addressable
> widget for its surface *and* the piece owns that widget.**

It fails that test — and so is *not* a component — in exactly two ways:

- **The surface is a parent's chrome/property, not an addressable widget.**
  `Shared::StatusFooterUpdater` drives `Window#footer_text`; Tuile exposes
  the footer as a property, not a widget, so there is no widget to own. This
  is **framework-shaped**: the *same logical surface* would be a component in
  a toolkit that made the footer an addressable widget. → the *list of which
  Tuile surfaces are chrome-not-widget* belongs in the **Tuile skill**.
- **The surface belongs to *another* component.** `Code::PlanModeListener`
  pokes a footer badge it doesn't own — the **own-vs-other line**. A listener
  feeding its *own* view is the internal model half (nested, part of the
  component — `ConversationTextView::Listener`); a listener poking *another's*
  surface is a standalone adapter (`PlanModeListener`).

So **presenter and adapter are one category** for the is-it-a-component test
— "drives a surface it owns no widget for." (Presenter drives the chrome
directly; adapter bridges an event stream onto it — a naming nuance, not two
categories.) Both are non-components for the *same* reason.

**The one universal exception** (framework-agnostic → global doc): even when
a piece *could* be a component, if a two-line helper does the job, don't
manufacture the subclass. Everything else above is framework-shaped and
belongs in the Tuile skill.

## Backport mapping (where each piece lands)

- **(a) global CLAUDE.md** — the framework-agnostic core, kept short (it
  sits next to the existing dense COP note): UI-component as the default
  target when a UI framework is in play; the composition-over-inheritance
  carve-out (§ above); the model/view seam as a conceptual aid with
  size-driven placement (class vs. lambda) and the shared-must-be-injected
  constraint; the render-verb seam.
- **(b) new Tuile skill** — the general shape *plus* Tuile specifics: which
  classes are the extension points (`TextView` / `TextArea` / `Window` /
  `Popup`), the widget-suffix naming convention, `Window`-frames-view
  composition, the nested-`Listener` adapter idiom, the **UI-thread
  rendering consequence + `event_queue.submit` marshaling**, and the
  framework-shaped presenter/adapter exception (now resolved above: the
  "surface is chrome, not an addressable widget" and "surface belongs to
  another component" cases).
- **(c) project docs / rdoc** — mostly already present (AGENTS.md package
  map + `ConversationTextView` rdoc). Leftover = one short pointer in
  AGENTS.md's *Design with components* section to the live exemplars
  (`ConversationWindow`/`TextView` as the big-nested case; the git panes as
  the shared-injected case once they land). Delete both idea files once (a)
  and (b) are in.

The *mechanism* of (a) and (b) — verbatim text vs. a global skill, and how
the skill fires — is the open item worked out next.

## Open item: verbatim global-doc text vs. global skill (the backport mechanism)

Don't frame this as one-or-the-other for the whole principle. Split it by
the two layers the mapping already names — agnostic core (a) vs. framework
mechanics (b) — because they want *different* homes.

### The two mechanisms, stated honestly

- **Verbatim in `~/.claude/CLAUDE.md`** — always loaded, every session,
  every project, in full. Perfectly reliable (no activation step at all).
  Cost: pollutes non-programming contexts and grows an already-large file.
  Acceptable *only for short text.*
- **Global skill (`~/.claude/skills/<name>/SKILL.md`)** — only the one-line
  description sits in context always; the body defers until the skill is
  invoked. No pollution. Cost: needs an activation path, and activation is
  never 100%.

### The reframe: it's not either/or — it's per-layer

The "pollutes non-programming projects" objection is real for a *wall* of
text — but it is **already a sunk cost** for short design guidance. The
global CLAUDE.md *today* carries a big COP block ("my default
architecture"), the entire doc-comment rulebook, git-branch rules, and
library-version rules — all programming-slanted, all always-loaded. A
non-programming project already eats every byte of that. So:

- **Layer (a), the agnostic core** (UI-component-as-default target, the
  composition-over-inheritance carve-out, the model/view sizing aid, the
  render-verb seam) is *short* and is the same *kind* of design philosophy
  as the existing COP block. Append it **verbatim, to that block** — a few
  sentences. Its marginal pollution over what's already there is
  negligible, and its reliability is total. The either/or's objection
  doesn't bite at this size.
- **Layer (b), the Tuile mechanics** (extension points, widget-suffix
  naming, `event_queue.submit` threading, the framework-shaped
  presenter/adapter exception) is *bulky and framework-specific* — exactly
  what must **not** go verbatim. This is **skill** material.

So the answer to "verbatim or skill?" is **both, split by size and
agnosticism**: the small agnostic nugget rides the always-on COP block; the
bulky framework detail is a deferred skill. That split also *dissolves* the
pollution worry — the only thing always-loaded is the short nugget.

### Activating the skill layer reliably

"Whenever an agent starts coding" has no hard trigger. Ranked:

1. **Project-CLAUDE.md pointer (recommended).** Each programming project
   that wants it adds one line — *"Before writing or refactoring UI
   components, read `~/.claude/skills/ui-component-cop/SKILL.md`."* This is
   the "hopefully activated by project's CLAUDE.md" path, and it's the right
   one because it is **self-scoping**: only UI-bearing projects add the
   pointer, so non-programming projects never pull it and never pay a byte.
   It's an explicit instruction the model sees every session *in that
   project*, so it's about as reliable as CLAUDE.md guidance gets.
   **Precedent already exists** — the global CLAUDE.md's *"Auto-load skills
   by project type"* table uses exactly this shape ("read and follow the
   listed skill file before doing work").
2. **Sharp skill description as a backstop.** A well-written one-line
   description lets the model auto-invoke on UI-component work even where the
   pointer was forgotten. Weaker (model judgment; "starting UI work" is a
   fuzzy trigger), but free and complementary — belt and suspenders with 1.
3. **Global auto-load-table row — rejected.** That table keys on
   *build-file markers* (`gradlew` → gradle skill, `pom.xml` → maven skill)
   for deterministic per-*project-type* loading. A UI-component principle is
   cross-language and keyed on *activity*, not project type — there is no
   marker file that means "this project does component UI." Forcing a row in
   either mis-keys (picks one language's build file) or degenerates into
   option 2.
4. **A settings.json hook — available, usually unnecessary.** A SessionStart
   hook is the *only deterministic* mechanism (fires every session, no model
   judgment). Its downside — fires unconditionally regardless of task — is
   actually harmless for a **UI-native** project (Vaadin app, pikuri-tui),
   where nearly every task is UI work, so "unconditional" is *correct* there.
   But a hook only reliably injects the *pointer text*; the model still has
   to act on it, so it adds no reliability over the always-in-context
   CLAUDE.md pointer unless it injects skill *bodies* directly (which defeats
   deferral). Keep in reserve for a hard guarantee; the pointer is enough.

**Recommendation:** (a)-core **verbatim** into the existing COP block **+**
(b)-mechanics as a **global skill**, activated by a one-line
project-CLAUDE.md pointer (option 1), with a sharp description (option 2) as
backstop. This project's own AGENTS.md becomes the *first* such pointer —
which also discharges backport target (c).

### DECIDED — two skills, not one

Earlier this leaned "one skill, split top/bottom." **Overruled, with a good
reason:** the COP+UI pattern must apply to **Vaadin** projects too, so it
cannot be coupled to Tuile inside one skill. So:

- **`cop` (or `component-oriented-programming`)** — the general COP
  philosophy with a **framework-agnostic UI subsection** (UI-component as
  default target, the composition-over-inheritance carve-out, the model/view
  sizing aid, the render-verb seam). Reusable by Vaadin, Swing, *and* Tuile
  projects. This is the durable, portable asset.
- **`tuile-components`** — Tuile-only mechanics (extension points,
  widget-suffix naming, `event_queue.submit` threading, the framework-shaped
  presenter/adapter exception), linking *back* to the COP skill for the
  general shape.

### Reliability of the project pointer (the condition the whole plan rests on)

Verdict: **reliable enough — two-skills stays on the table.** A
project-CLAUDE.md pointer can name *both* skills in one instruction ("before
UI work, read `cop` and `tuile-components`"); its reliability is the same
bar as the *"Auto-load skills by project type"* table already trusted in the
global CLAUDE.md. Two rules push it to its ceiling:

- **Name both skills explicitly in the pointer.** Do *not* rely on a
  cascade (Tuile skill loads → it tells the model to also load `cop`) —
  that's two hops and the second can miss. One pointer, two named targets,
  one hop.
- **Phrase it unconditionally for UI-native projects** — "when working in
  this project, read X and Y before starting," matching the auto-load
  table's "before doing work," not "*if* this is UI work." The conditional
  adds a judgment call the model can miss, and a Vaadin/pikuri-tui project is
  doing UI work nearly always, so unconditional wastes nothing.

Honest ceiling: as reliable as any CLAUDE.md instruction — not a hard
guarantee (only the settings.json hook is). That residual gap is covered by
the in-skill link below acting as a safety net, not by tightening the pointer
further.

### How the Tuile skill links back to COP+UI (activation ≠ linking)

Key insight: **the project pointer does the activation** (loads both skills),
so the Tuile→COP link is *not* the activation path — it's a safety net (if
only the Tuile skill loaded) plus a statement of the relationship. That
reprioritizes the three options — distinct roles, not redundancy:

- **(a) reference the `cop` skill — YES, the primary link.** Runtime-
  actionable ("if you haven't read `cop`, do so now") and states the
  relationship. Fine to couple to the skill name for personal skills.
- **(c) link to the blogposts — YES, the canonical citation.** Two live
  posts, portable/shareable, the human-readable source of truth; survive off
  this machine (matter if the skills are ever published). Needs a fetch to
  act on — citation, not runtime path:
  - https://mvysny.github.io/component-oriented-programming/ — the COP
    philosophy (self-sufficiency, "many collaborators one responsibility",
    listeners, data-providers-by-size, system-testing). Already linked from
    AGENTS.md's *Design with components*.
  - https://mvysny.github.io/composition-over-inheritance/ — the carve-out,
    published in full: the sharp line, one-rung-past-the-framework, "the base
    must earn its place", the `AbstractApp` counterexample. This *is* the
    Reconciliation section above.
- **(b) assume it's in global CLAUDE.md — NO, not load-bearing.** Global
  CLAUDE.md holds only the *short nugget*, not the full pattern; and it
  couples to personal setup (breaks when shared/blogged). Demoted to: the
  nugget's always-on presence is *why* the Tuile skill can be terse on base
  philosophy — not a link relied upon.

So: **(a) actionable link + (c) canonical citation.** Not "all three" as
equals — (b) is a background assumption, not a reference.

### Still open
- **Does the `cop` skill's UI subsection duplicate the (a)-core now in
  global CLAUDE.md?** Overlap is fine (skill = expanded form of the always-on
  nugget), but keep *authority* in one place: the global nugget states the
  rule tersely; the `cop` skill *teaches* it with examples (master-detail,
  the `JTable` model/view framing). Don't let the skill restate the nugget as
  if it were the source.
- **Skill names.** `cop` vs. `component-oriented-programming` (short slug vs.
  self-describing description-line); `tuile-components` vs.
  `tuile-ui`. Pick when authoring.
- **~~Write the blogpost first?~~ RESOLVED — both posts already exist**
  (URLs above). No TODO placeholder needed; the skills can cite live URLs
  from day one.
- **One nugget missing from the COP post: the render-verb seam.** Verified
  NOT PRESENT in
  https://mvysny.github.io/component-oriented-programming/ — the idea's
  "render-verb vocabulary *is* the actual seam" (§ above) isn't there. It's
  worth adding *to the post*, because it directly softens the testability
  cost the post admits ("the price you pay is testability"): the view half
  stays unit-testable through its verbs even when the model half can't be
  isolated. Draft paragraph handed to the author; a blog-repo edit, not a
  change to this file or the skills. Until it lands, the Tuile/`cop` skills
  should teach the verb seam themselves rather than lean on the post for it.
