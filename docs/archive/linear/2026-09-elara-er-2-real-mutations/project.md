# Linear project: Elara ER-2 — Real Mutations

- **State:** completed
- **Created:** 2026-09-01T01:03:42.652Z
- **Updated:** 2026-09-01T02:39:26.072Z
- **Linear URL:** https://linear.app/robert-guss/project/elara-er-2-real-mutations-463deb0980ad

## Summary

Test durable reconciliation across declarative writes, typed patches, and opaque shell.

## Description

## Objective

Move the ER-1 protocol from a synthetic marker into real coding mutations and determine exactly which guarantees are shared versus operation-specific.

## Scope

1. Freeze schemas, observations, deterministic failure cuts, and decision rules before implementation.
2. Reconcile declarative file writes with explicit expected-prior and desired-postcondition evidence.
3. Reconcile typed literal patches with preimage/postimage/conflict evidence.
4. Use opaque shell as the negative control: preserve indeterminacy where no durable causal receipt or explicit postcondition survives.
5. Run one frozen cross-class matrix and decide the surviving semantic scope.

## Invariants

* Durable executor completion and independently observed postcondition satisfaction remain distinct.
* Same ID/digest never causes duplicate mutation; same ID/conflicting digest never admits.
* Accepted work never silently fails over to another logical executor.
* Workspace state alone does not prove this job caused it without exclusive job-bound evidence/fencing.
* No command-text heuristic fabricates shell completion.
* Existing write/edit/bash behavior remains available until the gate.
* Linear is the sole roadmap; repository documents are immutable experiment evidence only.

## Gate outcomes

Evaluate Stop first. Otherwise select the first qualifying scope: **Continue — Universal**, **Narrow — Typed-only**, **Pivot — Snapshot-dependent**, or **Stop — Stop**. This project tests semantics, not product value or BEAM superiority.

## WIP

One issue In Progress and at most one Todo. Foundation → write → patch and shell → frozen cross-class matrix → gate.

## Project updates

_No project updates._
