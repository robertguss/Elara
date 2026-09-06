# Define acceptance and roadmap entry

Parent: [Live plugin discovery and reload](../map.md)
Type: grilling
Labels: wayfinder:grilling
Status: resolved
Assignee: codex
Blocked by: 02, 03

## Question

Given the chosen workflow and lifecycle contracts, what concrete evidence makes
the experiment ready to implement and later accept, and where should that work
enter the existing roadmap relative to SPLIT-5?

Resolve ordinary regression tests and owner-visible acceptance scenarios for
successful discovery/revision changes and their promised failure behavior.
Identify only baseline defects that block meaningful verification of this slice;
preserve unresolved failures as explicit limitations. State scope exclusions,
the implementation handoff, and any explicit roadmap sequencing decision.

Dedicated evals and benchmarks remain deferred. Replay may check Core decisions
but cannot substitute for checking actual tool outcomes, state migration, or
owner-visible session continuity.

## Answer

The owner's 2026-09-06 “Yes do it” moves the accepted workflow into PLUGIN-1;
return to the existing SPLIT-5 checkpoint afterward. The roadmap owns execution
status and check results. Decisions in tickets 02/03 bound this first slice.

Acceptance uses a session created before plugin installation, real Mix failure
output, a built-in edit, version-1 state migration, successful focused rerun by
the new tool, and another rerun after a broken revision is rejected. Separate
socket/TUI tests cover explicit activation, negotiation, controller ownership,
and snapshot refresh compatibility. Existing lease/migration/replay regressions
remain relevant. A live model's choice of tools is not measured by scripted
acceptance; dedicated evals and benchmarks remain owner-deferred.

Run shared checks and compare failures with the recorded pre-change macOS
baseline. Do not claim an all-green suite or resolve unrelated defects merely
to satisfy this experiment. The manual walkthrough lives in
[Live plugins](../../../docs/plugins.md#focused-test-fix-and-rerun).
