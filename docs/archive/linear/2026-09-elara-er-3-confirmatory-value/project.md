# Linear project: Elara ER-3 — Confirmatory Value

- **State:** completed
- **Created:** 2026-09-01T02:35:23.288Z
- **Updated:** 2026-09-04T16:04:47.206Z
- **Linear URL:** https://linear.app/robert-guss/project/elara-er-3-confirmatory-value-2df31004d5a9

## Summary

Test whether Universal durable-effect reconciliation delivers safe, measurable recovery value.

## Description

# Outcome

Execute the preregistered EXP-003 confirmatory program for the **Continue — Universal** GATE-2 scope: write, literal patch, and opaque shell. Decide whether Elara's runtime-neutral durable-effect protocol provides safe, useful recovery without unacceptable no-fault regressions.

## Canonical sources

* [GATE-2 decision (ROB-832)](<https://linear.app/robert-guss/issue/ROB-832/gate-2-decide-universal-typed-only-snapshot-dependent-or-stop>)
* [FND-2 preregistration (ROB-772)](<https://linear.app/robert-guss/issue/ROB-772/fnd-2-preregister-evidence-thresholds-and-comparator-suitability>)
* [EXP-003 preregistration artifact](<https://github.com/robertguss/elixir-harness/blob/cd7b5fe65cc3fc073c51c86a56b5dc7fcbea9054/docs/experiments/003-effect-receipt-confirmatory-preregistration.md>)
* [Accepted ER-2 implementation](<https://github.com/robertguss/elixir-harness/commit/9ff416f2c22327c5ef38edcd52a9e89108fbc726>)
* [Pinned baseline](<https://github.com/robertguss/elixir-harness/commit/23e603550253c69846795b13cc2f2670f1122e21>)
* [Pinned Lemon comparator](<https://github.com/z80dev/lemon/tree/b9ed0660e0d7fe61f38156f0aeb65e839b4e7f39>)

## Frozen scope and qualifications

Universal means one source-qualified protocol across all three operation classes: causal executor evidence may establish completion; exact declared postimage evidence may refine safe action but cannot manufacture causal completion; absence of admissible evidence remains truthfully indeterminate. Per-class declarations are adapters into that common rule, not independent reconciliation semantics. Opaque shell without a declared postimage adapter remains manual/indeterminate.

ER-2's 5,000 ms shell-timeout row was exercised with a documented test-only 300 ms Sidecar completion-wait override. This qualifies the Universal decision: ER-2 established the state transition and safety rule but did not confirm production enforcement of the unaccelerated 5,000 ms command timeout. ER-3 must preserve this qualification and may not relabel it as production timing evidence.

## Execution discipline

* Linear is the sole roadmap/status source; repository experiment documents are immutable evidence, not roadmaps.
* Use frozen ER-3/FND-2-v1 selection, exposure, amendment, denominator, scoring, comparator, dogfood, and threshold rules exactly.
* Construction/review units are separate from immutable fault-execution/report units.
* No target fault result may be exposed before the corpus, runner/scorer, adapter equivalence, and dogfood plan are frozen at their declared boundaries.
* One implementation issue may be In Progress at a time and at most one next issue may be Todo. All others remain Backlog until unblocked.
* Every issue Result must contain immutable commits/checksums, exact verification, deviations, and remaining uncertainty before Done.
* Any frozen-input amendment after relevant fault exposure invalidates that confirmatory run and requires versioned fresh held-out evidence.
* No issue may claim BEAM superiority; the tested thesis is runtime-neutral and implemented compatibly with BEAM ownership.

## Outcome gates

Safety disqualifiers have Stop precedence. Internal value, no-fault correctness/timing, truthful knowledge-state convergence, causal terminal convergence, external comparability, and dogfood usability are evaluated under [ROB-772](https://linear.app/robert-guss/issue/ROB-772/fnd-2-preregister-evidence-thresholds-and-comparator-suitability)'s frozen formulas. External evidence is secondary; insufficient Lemon comparability neither supports nor blocks the internal Elara result by itself.

## Project updates

_No project updates._
