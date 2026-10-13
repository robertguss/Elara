# Linear project: Elara

- **State:** completed
- **Created:** 2026-08-31T01:25:01.036Z
- **Updated:** 2026-09-01T00:32:18.295Z
- **Linear URL:** https://linear.app/robert-guss/project/elara-ff8cc023e770

## Summary

ER-1 stopped at GATE-1: safety passed, frozen row-1 result-count contract failed.

## Description

## Objective

Prove or falsify whether digest-bound durable mutation jobs materially improve the correctness and recoverability of Elara coding work, then activate later horizons only when preregistered evidence justifies them.

## Claim under test

The current sequence tests a **runtime-neutral durable-effects hypothesis implemented compatibly with BEAM process ownership**:

> A mutation committed under a stable job ID and operation digest before dispatch, durably accepted by its executor before mutation, and reconciled after failure can avoid duplicate external mutation and false classification while preserving honest `:indeterminate` outcomes. This does not promise generic exactly-once callback invocation.

This tests whether the protocol fits Elara's pure reducer, supervised process ownership, remote executor, and failure boundaries. It does **not** claim that BEAM is superior to other runtimes. A BEAM-advantage claim requires a separate preregistered comparative experiment.

## Current executable scope

1. **M0 — Foundation audit:** freeze the eight-cut ER-1 contract and baseline; then preregister sampling, metrics, thresholds, eligible narrower scopes, and comparator suitability before target implementation.
2. **M1 — ER-1 synthetic truth:** marker mutation plus deterministic eight-cut crash matrix.
3. **M2 — ER-2 real mutations:** reconcile writes and patches while classifying opaque shell truthfully.
4. **M3 — ER-3 product value:** materialize the locked corpus, review neutral harness/adapters, then run immutable internal, external, and dogfood experiments.

## Exit outcomes and precedence

Safety failure always takes precedence over every other outcome.

* **Continue:** the complete preregistered scope meets every truth, liveness, safety, recovery, no-fault, and product threshold.
* **Narrow:** all safety controls pass and a nonempty preregistered strict scope meets every applicable threshold while the full scope does not.
* **Pivot:** safety and value thresholds pass, but a demonstrated ownership, UX, or persistence contradiction prevents deployment and no preregistered narrower scope resolves it.
* **Stop:** any safety disqualifier occurs, no nonempty preregistered scope passes, material recovery improvement is not established, or explicit performance/dogfood thresholds fail without a pivotable contradiction.

GATE-2 uses domain labels mapped to this vocabulary:

* **Continue — Universal**
* **Narrow — Typed-only**
* **Pivot — Snapshot-dependent**
* **Stop — Stop**

A stopped experiment is a successful research outcome when its evidence is complete.

These definitions govern the final GATE-3 decision. GATE-1 and GATE-2 use their explicitly stated phase-local criteria and mapped labels; a phase-local Continue does not imply that later product thresholds have passed.

## Operating rules

* Linear is the only canonical roadmap and implementation-status source.
* Persist mutation intent before dispatch; durably commit executor acceptance before replying accepted or beginning mutation.
* Never silently retry or fail over an accepted mutation to another executor.
* BEAM/OTP process restart policy is never mutation retry policy.
* Lost or absent causal terminal proof produces `:indeterminate`, not success, error, or guessed completion; surviving intent, acceptance, callback-attempt, external-state, or noncausal postcondition evidence may coexist with that classification.
* Recovery is driven by durable job evidence and preregistered operation evidence, never transcript repair.
* Distinguish executor `completed` from independently observed `postcondition_satisfied`. Exact workspace bytes do not prove causal job completion without exclusive authority or fencing.
* Prototype schemas remain internal until GATE-3 passes.
* Preregistration changes after relevant result exposure invalidate the confirmatory run and require a new version plus fresh held-out execution.
* One implementation issue fits one focused AI-assisted work session or coherent review unit; reviewed harness/adapter construction is separate from immutable experiment execution.
* WIP limit: one implementation issue in progress and one executable Todo maximum.
* An issue is Done only when acceptance criteria and linked Result evidence are complete.

## ER-1 fault contract

[ROB-667](https://linear.app/robert-guss/issue/ROB-667/fnd-1-freeze-the-er-1-contract-and-baseline-current-behavior) freezes these eight semantic cuts:

1. before controller intent commit;
2. after intent commit and before dispatch;
3. after executor receipt and before durable acceptance commit;
4. after acceptance commit and before acceptance reply;
5. after acceptance reply and before callback invocation/external mutation;
6. after external mutation and before executor completion commit;
7. after completion commit and before completion reply;
8. after completion reply and before session-result persistence.

For every row it freezes crash target, delivered/dropped messages, surviving storage, restart order, admissible evidence, expected facts/observations/classification, permitted action, deadline, and convergence bound. Target-only seams are N/A/non-equivalent in the baseline.

## Evidence gates

### ER-1 → ER-2

Continue only when the no-fault exactly-one control, same-ID/same-digest replay control, conflicting-digest rejection control, and all eight preregistered truth/liveness rows pass. Every row must converge within its frozen bound to a truthful knowledge state and safe next action. Convergence to `completed` or `failed` is required only when admissible causal terminal evidence survives. `:indeterminate` is permitted whenever no admissible causal terminal evidence can establish completion or failure, even when intent, acceptance, callback-attempt, external-mutation, or noncausal postcondition evidence survives. Duplicate external mutation, callback reinvocation without declared atomic ID/digest deduplication, or false classification stops the thesis.

### ER-2 → ER-3

Choose semantic scope, not product value:

* Universal only if one operation-independent contract satisfies every row without operation-specific evidence.
* Typed-only only if a nonempty typed operation scope satisfies every truth/liveness row while opaque proof-loss remains honestly indeterminate.
* Snapshot-dependent only when named snapshot evidence would establish `postcondition_satisfied` or an evidence-backed safe next action; it must not establish executor `completed` without authority/fencing.
* Stop on safety violation or when no nonempty typed scope satisfies all preregistered rows.

### ER-3 → consolidation

Confirmatory thresholds are frozen in [ROB-772](https://linear.app/robert-guss/issue/ROB-772/fnd-2-preregister-evidence-thresholds-and-comparator-suitability) before implementation:

* zero safety disqualifiers and 100% no-fault correctness;
* bounded truthful knowledge-state and safe-next-action convergence for 100% of rows, with terminal convergence required wherever admissible causal terminal evidence survives;
* over the locked paired rows, `B - T >= 2` and `(B - T) / B >= 0.50`, where `B` and `T` count the union of ambiguous/manual baseline and target rows once; `B < 2` cannot establish material improvement;
* no-fault timing uses two warmups plus 10 measured repetitions, per-row medians, corpus median target/baseline ratio at most 1.20, and no row ratio above 2.0;
* dogfood has 8–12 planned tasks, at least 8 terminal outcomes, five failure types, two no-fault controls, safe-next-action evidence for every injected failure, at least 80% without unplanned recovery intervention, and no protocol-friction abandonment.

External comparison is secondary. It requires no-fault equivalence for each included operation class and at least three equivalent fault rows across two fault types. Otherwise its valid result is **Insufficient comparability** and it supports no external claim.

## Horizon register — not committed backlog

These are gated research directions, not promised releases. They receive implementation issues only when their activation condition is met.

### H1 — One-node runtime consolidation

Canonical fact/effect journal, restart reconciliation, typed postconditions, activated/passivated shells, and shadow replay.

**Activate only if:** GATE-3 concludes that the durable-effects thesis survives.

**Gate:** one process or VM may die without losing durable job identity or misclassifying accepted mutations.

### H2 — Durable workspace cells

External container/VM cells behind one job protocol, fenced workspace epochs, resumable streams, snapshots, artifacts, and demand-aware placement.

**Activate only if:** H1 passes its one-node durability gate.

**Gate:** work may move between execution bodies while preserving authority, evidence, workspace epoch, and mutation identity.

### H3 — Supervised software-work fabric

Durable missions, project actors, bounded mission graphs, evidence gates, human approvals, and multi-user control rooms.

**Activate only if:** H2 demonstrates a real coordination consumer.

**Gate:** multiple humans and agents coordinate without duplicate ownership, shared-chat ambiguity, or untraceable acceptance.

### H4 — Living-software research

Executable constitutions, evidence leases, production-triggered repair missions, prediction-bearing releases, and counterfactual replay.

**Activate only if:** real projects demonstrate measurable adaptation and accountability value.

## Dependency and status model

Use native Linear blocker relations. Gate-blocked issues remain **Backlog**. The next executable issue is **Todo**. Active work is **In Progress**. Completed work is **Done** only with evidence. Invalidated work is **Canceled** and links to the deciding gate. Gate decisions update statuses and native blockers atomically; a completed gate never implies Continue by itself.

## Primary references

* [Elara repository](<https://github.com/robertguss/elixir-harness>)
* [Pinned planning baseline](<https://github.com/robertguss/elixir-harness/commit/23e603550253c69846795b13cc2f2670f1122e21>)
* [Research and planning thread](<https://ampcode.com/threads/T-01a05474-3112-72bd-ad95-7a57718a24f5>)
* [AWS Builders' Library: Making retries safe with idempotent APIs](<https://aws.amazon.com/builders-library/making-retries-safe-with-idempotent-APIs/>)
* [SQLite transactions](<https://www.sqlite.org/lang_transaction.html>)
* [SQLite atomic commit](<https://www.sqlite.org/atomiccommit.html>)
* [Erlang/OTP supervision principles](<https://www.erlang.org/doc/system/sup_princ.html>)
* [Lemon BEAM coding-agent runtime](<https://github.com/z80dev/lemon>)

## GATE-1 final outcome — 2026-09-01

**Stop.** Safety controls passed, but frozen ER-1 row 1 simultaneously required a session-visible `not_started` classification and a session-owned result count of zero. The shipped matrix truthfully persisted one classification result, so the full scope failed its immutable contract. The sole preregistered Narrow scope retained all eight rows and failed the same requirement; no qualifying ownership Pivot existed.

[ROB-672](<https://linear.app/robert-guss/issue/ROB-672/gate-1-decide-er-1-continue-pivot-narrow-or-stop>) contains the complete precedence audit and evidence. M2/M3 are canceled. This Stop is treated as a successful research/falsification outcome, not evidence that the shipped prototype had a duplicate-mutation safety failure. Any future durable-effects experiment requires a new versioned preregistration and fresh evidence; it may not relabel this confirmatory run.

## Project updates

_No project updates._
