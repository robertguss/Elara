# 006 — Selective retirement

- **Question:** Can legacy runtime surfaces be retired while retaining durable
  input/effect recovery and the finite LAB-5 fault contracts?
- **Hypothesis:** Production executor migration and surface retirement leave
  those assertions green without changing their causal/no-retry rules.
- **Queue item:** LAB-6 / ROB-1086 · **Date:** 2026-10-06
- **Baseline:** main `fa482cdf37ff12481dc7b2433d8979ff67919c31`; LAB-5's
  registered 1200-row corpus at `15e000c` remains unchanged and separate.

## Method and deliberate removals

Retire in reviewed delivery chunks; current status and exact review/merge
revisions are in Linear. Raw checks go under
`lab/results/rob-1086-retirement-20261006/`.

Coordinator/Engine, its supervisor and public `start_coordinator/2` are removed
under ROB-1095's owner decision. Four Coordinator-specific tests (384 lines)
are deliberately removed: candidate isolation/death plus judge selection;
concurrency/token/time/early-selection budgets; map/reduce plus selected-turn
history seeding; and coding isolation/startup/interrupt/worktree cleanup.
Removed contracts also include compact batch results, worker-health/progress
and aggregate budget reporting, sibling kill and coordinator-owned teardown.
Threads preserves its own durable child lifecycle; it does not replace automatic
judging, reduction or aggregate batch budgets. The separate project-guidance and
configured-skill inheritance test moves to the public Threads path with the
original prompt assertions retained.

All seven TestExecutor caller files move to production `Effect.Executor`, with
recovery, ledger and fault assertions unchanged. The 43-line delegating wrapper
is removed. This chunk removes 997 production lines: Coordinator 239, Engine
704, wrapper 43, API 10 and supervisor entry 1. Net diff is reported at review,
separately from runtime removal.

LiteralPatch/OpaqueShell retire from the production application in the second
chunk: 579/622 lines move to `test/support/fixtures/` under
`Elara.TestFixtures`. Only namespace/module documentation change in the drivers;
only alias namespaces change in their two test files. All other bytes and
assertions remain identical. This removes 1201 runtime lines by relocation,
not 1201 total code lines. Test helper loading adds four lines. The fixtures
exercise the production Sidecar/Executor/AtomicFile/Exec and preserve every
historical crash/no-retry/causality contract; they are not production receipt-backed
edit/bash. Focused effect/executor/input verification passed 113 (seed 1086).
Project plugin version 4 owns evidence/diagnosis tool definitions; they are
absent without it. Session uses invocation-bound evidence/provider messages with
no project-tool name rules. The historical `checkEvidence` persistence DTO and
validation remain compatible. `cancel_on_interrupt` is a validated boolean,
default false; explicit read-only tools kill their worker and release the lease
without committing returned plugin state. Ordinary plugin calls still drain.
TestJobs stays until LAB-8 delivers its replacement.

## Verification and limits

The first-chunk baseline passed 24 tests; post-change inheritance, Threads,
executor, durable-input and effect coverage passed 148 at seed 1086. All seven
executor caller files are byte-identical to baseline after only the
`TestExecutor` to `Executor` substitution. Full-suite and final finite-chaos
regression evidence remain pending and will be recorded as executed in Linear.
The three new roster/absence/renamed-tool controls failed on the old runtime.
Diagnosis/check/plugin focused coverage passed 33 after migration. Adding boolean
validation and reload protocol coverage exposed a stale v3 PTY expectation; it
is updated to v4 without changing any rendered-behavior assertion. Disabling
explicit cancellation independently failed the original worker-DOWN assertion;
registered owned-worker teardown passed, and source bytes were restored exactly.
Read/write/context/provider-result calls from an unrelated caller are rejected;
existing persistence, usage, late-result, worker-crash and diagnosis PTY checks
remain acceptance authority. Retain every failed log beside final evidence. Original registered
measurements, failed controls, raw roots and branches remain retained. No real
provider calls or human TUI acceptance are implied.
