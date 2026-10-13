# Linear project: Elara ER-1 v3

- **State:** completed
- **Created:** 2026-09-01T00:55:33.586Z
- **Updated:** 2026-09-01T01:05:02.912Z
- **Linear URL:** https://linear.app/robert-guss/project/elara-er-1-v3-0131fc88a1b6

## Summary

Continue — complete ER-1 v3 evidence passed; advance to real mutations.

## Description

## Objective

Produce the first complete gate-eligible revalidation of ER-1 from a corrected harness and entirely fresh fixture exposure, without changing the shipped production protocol.

## Why v3 exists

ER-1 v1 concluded Stop because its frozen row-1 count contract was contradictory. ER-1 v2 corrected that contract, but its first execution aborted in harness mechanics before the conflicting-digest target call. V2 produced no gate outcome. V3 preserves both records and starts from scratch with a separately frozen contract, manifest, seeds, and fixtures.

## Evidence discipline

* Production baseline remains `a1ee8b39924de38ee08eb0d222d873d3f4061767`; no `lib/` change is permitted.
* Foundation may repair only the conflicting-job harness construction, point the harness at a v3 manifest, add immutable v3 evidence artifacts, and update the experiment index.
* Before freeze, validate the constructor path with a no-session/no-executor/no-marker smoke command in addition to formatting, production compile, syntax, manifest, and production-diff audits. Do not execute a matrix row.
* After freeze, no production, harness, contract, or manifest edit is permitted before the gate. Any required edit aborts this version and requires another fresh version.
* Linear is the sole roadmap/status source. Repository documents are immutable evidence only. Preserve `Elara.Session.Core` unchanged.

## Gate outcomes

1. **Stop — safety** on duplicate mutation, callback reinvocation, false terminal classification, digest-conflict admission, accepted-job failover, or no-fault failure.
2. **Invalid Experiment** only for an independently demonstrated logical contradiction or required unobservable metric; never for harness or target failure.
3. **Continue** only if all eight rows and three controls match every frozen count, truth, classification, action, and bound.
4. **Stop — contract miss** only when an eligible target execution observes a coherent requirement miss.

A pre-target harness exception is an aborted execution, not a gate outcome. No Narrow or Pivot is eligible. Continue creates a separate real-mutations project; it does not reopen prior canceled work.

## WIP

One issue In Progress and at most one Todo: foundation → complete execution → gate.

## Final decision

**Continue.** The complete immutable v3 execution and gate rerun passed all eight rows and three controls with no safety, truth, liveness, timing, or observability failure. The claim advances only to a separate real-mutation experiment; no product-value or BEAM-superiority conclusion is drawn.

## Project updates

_No project updates._
