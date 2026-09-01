# EXP-003 / ER-1 v2: corrected frozen revalidation contract

> **Status:** Frozen by ROB-820 on commit of this artifact **Contract version:**
> ER-1/FND-V2-1 **Production baseline:**
> `a1ee8b39924de38ee08eb0d222d873d3f4061767` **Predecessor:** ER-1/FND-1-v1,
> concluded **Stop** by ROB-672 **Canonical roadmap:** Linear project “Elara
> ER-1 v2” **Date:** 2026-09-01

This artifact preregisters a fresh, compact revalidation of the ER-1 synthetic
marker experiment. It does not modify or relabel the v1 contract or its Stop.
V1's safety controls passed, but its row 1 simultaneously required a
session-visible `not_started` classification and a session-owned result count of
zero. V2 corrects that count vocabulary before running fresh evidence.

## Claim and implementation freeze

The claim remains runtime-neutral:

> A mutation committed under a stable job ID and operation digest before
> dispatch, durably accepted before mutation, and reconciled from durable
> evidence after failure can prevent duplicate external mutation and false
> terminal classification while preserving honest indeterminacy.

V2 does not claim generic exactly-once callback execution, production executor
discovery, distributed ownership, fencing, real write/patch/shell durability, or
BEAM superiority.

Production behavior is frozen at `a1ee8b39924de38ee08eb0d222d873d3f4061767`.
Foundation work may change only this evidence artifact, its manifest, the
experiment index, and the deterministic matrix harness that reads fresh fixture
arguments. After the freeze commit, no production, harness, contract, or
manifest change is permitted before GATE-1-V2. `Elara.Session.Core` remains
unchanged.

All v1 protocol semantics remain unchanged: stable effect-derived identity,
canonical operation digest, controller intent before dispatch, executor receipt
then atomic acceptance, acceptance reply before callback attempt, durable
attempt increment before invocation, terminal commit before completion reply,
controller observation before session-result persistence, original-owner-only
reconciliation, and no retry after durable attempt count 1.

## Source-qualified measures

Every row and control reports these measures independently:

1. `controller_intent_count`: committed controller jobs for the tool call.
2. `executor_admission_count`: durable ID/digest admissions in the original
   executor ledger.
3. `executor_callback_attempt_count`: durable callback-attempt increments.
4. `external_mutation_count`: independently parsed marker records.
5. `executor_terminal_result_count`: durable executor `completed`/`failed`
   records; `accepted` and session classifications do not increment it.
6. `session_tool_result_count`: transcript `ToolResult` records for the call,
   including truthful `not_started` or `:indeterminate` classifications.

Controller truth, executor truth, historical-execution knowledge, current
postcondition observation, and session classification are separate facts. A
marker or desired postcondition never manufactures executor completion.
Transcript repair is not effect evidence.

## Frozen matrix

All convergence intervals begin immediately before the permitted recovery action
and end when the session reaches the frozen classification. Every bound is
≤1,000 ms. “Counts” are ordered as controller intent / executor admission /
executor callback attempt / external mutation / executor terminal result /
session ToolResult.

| Case                       | Cut and surviving truth                                                                                                                        |                        Final counts | Historical knowledge and postcondition                                                                                                                   | Classification and only permitted action                                                                                              |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------: | -------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Row 1                      | Controller dies at `:before_intent_commit`; no job or executor row exists                                                                      |                         0/0/0/0/0/1 | Definitely not dispatched, admitted, invoked, or mutated; postcondition absent                                                                           | `not_started`; append one truthful ToolResult to close the call; no executor query, reconcile, or automatic retry                     |
| Row 2                      | Controller dies at `:after_intent_commit_before_dispatch`; intent survives; executor is `unknown`                                              |                         1/1/1/1/1/1 | No pre-recovery execution; final causal completion and postcondition                                                                                     | Success; query original owner and same-ID/digest submit once on `unknown`                                                             |
| Row 3                      | Original executor dies at `:after_receipt_before_accept_commit`; transaction rolls back to `unknown`; controller remains live                  |                         1/1/1/1/1/1 | Receipt occurred, but no first admission/invocation/mutation; final causal completion                                                                    | Success; reopen same executor ID/ledger, query, and same-ID/digest submit once                                                        |
| Row 4                      | Executor dies at `:after_accept_commit_before_accept_reply`; ledger is accepted/attempt-0; controller has intent only                          |                         1/1/1/1/1/1 | Exactly one admission and no pre-crash invocation/mutation; final causal completion                                                                      | Success; query and continue once on the same owner                                                                                    |
| Row 5                      | Accepted observation survives; executor dies at `:after_accept_reply_before_callback`; ledger is accepted/attempt-0                            |                         1/1/1/1/1/1 | Admitted once and definitely not invoked/mutated before crash; final causal completion                                                                   | Success; continue once on the reopened same owner; no resubmit/failover                                                               |
| Row 6                      | Executor dies at `:after_external_mutation_before_completion_commit`; ledger is accepted/attempt-1 with no terminal row; one marker survives   |                         1/1/1/1/0/1 | Runtime proves admission and attempt; test ground truth/current workspace show one mutation and satisfied postcondition, but causal completion is absent | `:indeterminate`, naming missing `completed_or_failed` and all surviving facts; never continue, submit, retry, reinvoke, or fail over |
| Row 7                      | Executor dies at `:after_completion_commit_before_completion_reply`; original ledger is completed; controller last observed accepted           |                         1/1/1/1/1/1 | Causal historical completion and current postcondition both hold independently                                                                           | Success; query original terminal ledger and persist one result; no callback                                                           |
| Row 8                      | Controller dies at `:after_completion_reply_before_session_result_persist`; terminal controller observation survives; transcript has no result |                         1/1/1/1/1/1 | Causal completion is proven; only session persistence was interrupted                                                                                    | Success; pre-hydration append exactly one result; no submit/callback and no generic `interrupted` repair                              |
| No-fault control           | Full ordered protocol                                                                                                                          |                         1/1/1/1/1/1 | One causal completion and matching postcondition                                                                                                         | Success without reconciliation                                                                                                        |
| Same-digest control        | Pause accepted/attempt-0; replay submit/query; continue once; replay terminal submit/query                                                     |                         1/1/1/1/1/1 | Replays add no admission, attempt, or mutation                                                                                                           | Accepted and terminal evidence remain identical; only one declared continue                                                           |
| Conflicting-digest control | Submit same ID with a digest changed by the fresh fixture variant while accepted/attempt-0                                                     | 1/1/1/1/1/1 final; conflict delta 0 | Conflict adds no admission, attempt, or mutation; original later completes once                                                                          | Reject `digest_conflict`, preserve original evidence, release original once                                                           |

## Fresh immutable fixture manifest

`003-effect-receipt-er1-v2-manifest.json` is part of this contract. It contains
exactly 11 case IDs, opaque tokens, and unique nested operation-argument
variants. Both token and variant participate in the operation digest. Each case
and each run allocates a fresh workspace, controller SQLite database, executor
SQLite database, Flight Recorder identity, and job identity. The marker remains
non-deduplicating and records the token, fixture variant, job ID, and operation
digest.

The frozen seeds are `104729`, `130363`, and `155921`. The stability run is seed
`104729` with `--repeat-until-failure 25`. Fixture membership, values, seeds,
storage policy, and commands may not change after the freeze commit.

These fixtures are fresh confirmatory executions, not unseen model-evaluation
tasks. The protocol and implementation are known; freshness means new committed
inputs, identities, workspaces, and durable stores executed only after freeze.

## Safety and truth invariants

1. No case has more than one executor admission, callback attempt, external
   mutation, executor terminal result, or session ToolResult for its job.
2. Same ID/digest replay never invokes; conflicting digest never admits.
3. Accepted work never executes on a replacement logical executor.
4. Durable attempt count 1 permanently forbids reinvocation for this
   non-deduplicating marker.
5. Success/error requires causal terminal evidence. Missing terminal evidence
   after attempt is `:indeterminate` even when the postcondition is satisfied.
6. Row 1's absent intent under dispatch-after-intent ordering proves
   `not_started`; its one session classification is not an executor terminal
   result.
7. Recovery uses controller/executor/workspace evidence, never transcript
   repair.
8. Every row reaches its truthful knowledge state and safe next action within
   1,000 ms.

## Invalid Experiment boundary and gate

GATE-1-V2 evaluates:

1. **Stop — safety** for any duplicate mutation, reinvocation, false terminal
   classification, conflict admission, accepted-job failover, or no-fault
   failure.
2. **Invalid Experiment** only for a logically contradictory requirement or a
   required unobservable metric demonstrated independently of target results. It
   cannot excuse implementation, safety, truth, liveness, timing, or control
   failure. A new version and fresh fixture evidence are mandatory afterward.
3. **Continue** only if all eight rows and three controls match every frozen
   measure, fact, classification, action, and bound.
4. **Stop — contract miss** if this coherent observable contract exists but the
   implementation misses any requirement.

No Narrow or Pivot result is eligible. Continue creates a separate real-mutation
project; it never reopens v1's canceled roadmap.

## Required post-freeze execution

```text
mix test test/elara/effect/crash_matrix_test.exs --seed 104729
mix test test/elara/effect/crash_matrix_test.exs --seed 130363
mix test test/elara/effect/crash_matrix_test.exs --seed 155921
mix test test/elara/effect/crash_matrix_test.exs --seed 104729 --repeat-until-failure 25
mix test
mix format --check-formatted
mix compile --warnings-as-errors
```

Before the freeze commit, foundation verification is limited to formatting,
production compilation, static syntax parsing of the harness, and direct JSON
manifest audits. No v2 matrix row may execute before freeze.
