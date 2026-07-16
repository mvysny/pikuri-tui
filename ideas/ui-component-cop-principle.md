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

## Open question (unresolved — left for a later pass)

The "genuinely *not* a component" exceptions still need sharpening:

- **Pure presenter** — drives someone else's chrome, owns no widget
  (`Shared::StatusFooterUpdater` driving `Window#footer_text`).
- **Pure listener / adapter** bridging into another component's surface
  (`Code::PlanModeListener` flipping a footer badge).
- **The alternative is plainly simpler** — don't manufacture a subclass
  where a two-line helper does.

Two things to resolve here:

1. Are the presenter and the adapter really *one* category ("drives
   chrome/state it owns no widget for")? And is that exception
   **framework-shaped** (the footer is a presenter-not-a-component only
   because Tuile exposes it as `Window#footer_text` chrome, not as an
   addressable widget — in a toolkit where the footer *were* a widget it
   would be a component) rather than universal? If so, that half belongs in
   the **Tuile skill**, and only *"the alternative is plainly simpler"* is
   a universal exception for the global doc.
2. The crisp distinguishing rule: a listener that feeds its **own** view is
   the internal model half (part of the component); a listener that pokes
   **another** component's surface is a standalone adapter. That line
   separates `ConversationTextView::Listener` (nested, belongs to the view)
   from `PlanModeListener` (standalone).

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
  rendering consequence + `event_queue.submit` marshaling**, and (pending
  the open question) the framework-shaped presenter/adapter exception.
- **(c) project docs / rdoc** — mostly already present (AGENTS.md package
  map + `ConversationTextView` rdoc). Leftover = one short pointer in
  AGENTS.md's *Design with components* section to the live exemplars
  (`ConversationWindow`/`TextView` as the big-nested case; the git panes as
  the shared-injected case once they land). Delete both idea files once (a)
  and (b) are in.
