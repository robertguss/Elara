# Linear project: Elara ER-1 v2

- **State:** canceled
- **Created:** 2026-09-01T00:40:19.910Z
- **Updated:** 2026-09-01T00:54:36.605Z
- **Linear URL:** https://linear.app/robert-guss/project/elara-er-1-v2-43f1c3725912

## Summary

Execution invalidated pre-gate by harness mechanics; no v2 experiment outcome.

## Description

## Objective

Revalidate the promising ER-1 durable-effects prototype under a corrected, versioned contract and fresh fixture evidence without rewriting or relabeling the completed v1 Stop.

## Why v2 exists

ER-1 v1 passed every safety control and seven of eight rows, but its frozen row 1 simultaneously required a session-visible `not_started` classification and a session-owned terminal-result count of zero. The shipped implementation truthfully persisted one classification ToolResult. GATE-1 therefore stopped v1 under its immutable rules.

V2 tests a corrected contract. It does not claim v1 passed.

## Corrected row-1 accounting

Row 1 must report each source independently:

* controller intent count: 0;
* executor admission count: 0;
* executor callback-attempt count: 0;
* external mutation count: 0;
* executor terminal-result count: 0;
* session ToolResult count: 1, classified `not_started` with no automatic retry.

No generic `interrupted` repair may supply effect truth.

## Evidence discipline

* The shipped production baseline is commit `a1ee8b39924de38ee08eb0d222d873d3f4061767`.
* Freeze a versioned contract, fully qualified count names, fresh immutable marker manifest, workspace policy, fixture variants, seeds, and harness hash before executing v2 fault rows.
* The harness may be wired to the manifest during foundation work, but no v2 matrix row is executed before that harness is committed.
* After freeze, no production or harness change is allowed before the gate. Any change invalidates the run and requires a new version and fresh fixture evidence.
* Linear is the sole roadmap/status source. Repository documents are immutable evidence artifacts only.
* Preserve `Elara.Session.Core` unchanged.

## Gate outcomes

Evaluate in this order:

1. **Stop — safety:** duplicate mutation, callback reinvocation, false terminal classification, conflicting-digest admission, accepted-job failover, or no-fault failure.
2. **Invalid Experiment:** only an internally contradictory requirement or unobservable required metric, demonstrated independently of favorable/unfavorable target behavior. It cannot excuse any implementation, safety, truth, or liveness failure. A new version and fresh evidence are mandatory.
3. **Continue:** all three controls and all eight corrected rows match every frozen fact/count/classification/action/bound, with causal terminal truth kept separate from postcondition observation.
4. **Stop — contract miss:** a coherent observable contract exists but the implementation misses any required truth/liveness row.

There is no Narrow or Pivot outcome in this compact revalidation. If Continue passes, create a separate real-mutation project for declarative writes, typed patches, and opaque shell; do not reopen v1's canceled issues.

## WIP and status

One issue In Progress and at most one Todo. Foundation → fresh execution → gate. A completed Stop or Invalid outcome is a successful research result when evidence is complete.

## Final project disposition

Canceled pre-gate with **no experiment outcome**. [ROB-820](https://linear.app/robert-guss/issue/ROB-820/er1-v2-1-freeze-corrected-contract-manifest-and-immutable-harness) remains the immutable successful freeze. [ROB-821](https://linear.app/robert-guss/issue/ROB-821/er1-v2-2-execute-the-fresh-frozen-eight-cut-matrix)'s first required run passed 10/11 cases but failed in harness construction before the conflicting-digest target call; subsequent commands were not run and no post-exposure edit was made. [ROB-822](https://linear.app/robert-guss/issue/ROB-822/gate-1-v2-decide-continue-stop-or-invalid-experiment) was therefore unrunnable. This is neither Stop nor the reserved Invalid Experiment outcome. A separately versioned project with corrected harness mechanics and fresh fixtures supersedes this project.

## Project updates

_No project updates._
