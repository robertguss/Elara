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

LiteralPatch/OpaqueShell runtime retirement and project-plugin diagnosis
integration are subsequent chunks. Historical reconciliation drivers will be
explicitly test-only; they do not expand receipt-backed production write to
edit/bash. TestJobs stays until LAB-8 delivers its replacement.

## Verification and limits

The first-chunk baseline passed 24 tests; post-change inheritance, Threads,
executor, durable-input and effect coverage passed 148 at seed 1086. All seven
executor caller files are byte-identical to baseline after only the
`TestExecutor` to `Executor` substitution. Full-suite and final finite-chaos
regression evidence remain pending and will be recorded as executed in Linear. Original registered
measurements, failed controls, raw roots and branches remain retained. No real
provider calls or human TUI acceptance are implied.
