# Catch up with pikuri master (the path-dep migration)

Status: **open, and the suite is red until it lands.** The `Gemfile` now points
every `pikuri-*` gem at `../pikuri/<gem>` (for the `[[server]]` /
`max_concurrent_requests` co-development — see
[`server-definitions-in-config.md`](server-definitions-in-config.md)), and
master has moved well past the released `0.1.0` gems: **133 of 869 examples
fail**, none of them for a reason this repo caused.

This file is the migration, not a bug list. Three upstream changes landed since
the gems were cut, and one of them is a feature this repo has been waiting for.

One caveat that comes with a path dep: this repo now tracks a *working tree*,
not a release. `../pikuri` currently carries uncommitted work of its own
(`D_probe_when_unknown`, the `/props` skip fix this schema wanted), so a
`rake check` here can move for reasons that are not in this repo's history.

Sequencing note: nothing here is *blocked* on the schema work and vice versa,
but the path dep serves both, and `rake check` cannot report on the schema work
while these 133 stand. Do this first.

## 1. `Control::StepLimit` is gone — 92 failures

Upstream `52a29c5` ("Remove the step limit and the step-exhaustion
synthesizer") deleted the class *and* `Agent#initialize`'s `step_limit:`
keyword. Three call sites, each passing a number picked per shell:

- `lib/chat/app.rb:273` — `max: 20`
- `lib/computer/app.rb:376` — `max: 40`
- `lib/code/app.rb:425` — `max: 250`

The fix is deletion, not replacement: the turn executor is unbounded upstream
now (`D_no_step_limit`), so those three numbers have no successor knob. Check
whether any of them is *mentioned* in the class rdoc or AGENTS.md before
deleting — an argument for "the coding shell gets 250 because …" is now a
statement about a parameter that does not exist.

## 2. `Event::FallbackNotice` is gone — 7 failures

It was the step-exhaustion synthesizer's notice, removed with it.

- `lib/shared/conversation_text_view.rb:748` — a `in
  Pikuri::Agent::Event::FallbackNotice(reason:)` arm in the listener's
  pattern-match. Delete the arm.
- `spec/shared/conversation_text_view_spec.rb:389` — its spec. Delete.

Nothing replaces it. Worth one look at how the arm rendered (a dim notice?) to
confirm no other event was routed through the same helper.

## 3. Tool summary lines shipped — 32 failures, and the interesting one

Upstream `b001adc` / `ff70515`, decided as `D_tool_summary_lines`. Both events
gained display fields, so this is not a keyword-shuffle: it is the deletion
AGENTS.md promised when it called the short tool line "a tui-side stand-in".

**The design for this half is already written** —
[`tool-lines-from-pikuri-summaries.md`](tool-lines-from-pikuri-summaries.md),
which names the four stand-in helpers that delete, the two pixels that change,
and the decision not to lose. It was parked on "waiting on pikuri"; it is
buildable in this checkout now. Read it rather than re-deriving; only the
failure counts and the field lists live here.

## Then: sweep the spec fixtures

Most of the 133 are fixture constructors, not logic — `spec/support` builders
and inline `Event::ToolCall.new(name:, arguments:)` calls that now need the two
display strings (`spec/shared/conversation_text_view_spec.rb:123` and `:127`
are the two hot spots, feeding most of the 22 + 10). Two `App` specs fail
downstream of #1 rather than on their own (`turn_app` is `nil` because
construction raised): `spec/chat/app_spec.rb:29` and `spec/code/app_spec.rb:581`.

Check `Pikuri::Testing`'s helpers before hand-rolling fixtures — `ff70515`
("`Tool#execute` always returns a `Result`") suggests the test seam moved too.

## Open questions

**`Q_release_or_path`.** This repo cannot ship on path deps (CI can't build
them — see the `Gemfile` comment and commit `948fc32`, which un-pinned tuile
for exactly that reason). So either upstream cuts `0.2.0` gems before this
lands on `main`, or this migration sits on a branch until it does. Cheapest
honest answer: land the migration while on the path dep, keep it local, and
revert the `Gemfile` in the same commit that bumps to the released `~> 0.2`.

**`Q_one_commit_or_three`.** The three items are independent in the code but
not in the suite — until all three land, `rake check` cannot go green, so there
is no intermediate commit that builds *and* passes. Commit hygiene ranks below
that: one coherent "absorb pikuri master" commit, or three with the first two
knowingly red. Leaning one commit, with the three changes named in the message.
