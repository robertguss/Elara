# EXP-003 / ER-1 v3: fresh frozen revalidation contract

> **Status:** Frozen by ROB-823 on commit of this artifact **Contract version:**
> ER-1/FND-V3-1 **Production baseline:**
> `a1ee8b39924de38ee08eb0d222d873d3f4061767` **Predecessor exposure:** ER-1 v2
> commit `a1f3f094f956121578b6dedb66a0559c000bfbb1` **Canonical roadmap:**
> Linear project “Elara ER-1 v3” **Date:** 2026-09-01

V1 concluded **Stop** under an internally contradictory row-1 count contract. V2
corrected the contract, but its first run aborted in harness mechanics before
the conflicting-digest target call; it produced no gate outcome. V3 preserves
both records and preregisters a complete revalidation with corrected harness
construction and entirely fresh fixtures.

## Claim and freeze boundary

> A mutation committed under a stable job ID and operation digest before
> dispatch, durably accepted before mutation, and reconciled from durable
> evidence after failure can prevent duplicate external mutation and false
> terminal classification while preserving honest indeterminacy.

This runtime-neutral claim excludes generic exactly-once callbacks, production
executor discovery, distributed fencing, real write/patch/shell durability, and
BEAM superiority.

Production behavior remains frozen at
`a1ee8b39924de38ee08eb0d222d873d3f4061767`. ROB-823 may only correct
conflicting-job construction, select this fresh manifest/temp namespace, add v3
evidence, and update the experiment index. After its freeze commit, no
production, harness, contract, or manifest edit is permitted before GATE-1-V3.
`Elara.Session.Core` remains unchanged.

The protocol order remains: stable effect-derived identity; canonical digest;
controller intent before dispatch; executor receipt then atomic acceptance;
acceptance reply before callback; durable attempt increment before invocation;
terminal commit before reply; controller observation before session-result
persistence; original-owner-only reconciliation; and no retry after attempt 1.

## Six independent measures

Every case reports:

1. `controller_intent_count` — controller jobs committed for the call.
2. `executor_admission_count` — original-ledger ID/digest admissions.
3. `executor_callback_attempt_count` — durable callback-attempt increments.
4. `external_mutation_count` — independently parsed marker records.
5. `executor_terminal_result_count` — durable executor completed/failed rows.
6. `session_tool_result_count` — transcript ToolResults, including knowledge
   classifications such as `not_started` and `:indeterminate`.

Controller truth, executor truth, historical knowledge, current postcondition,
and session classification are separate. A marker never manufactures causal
completion, and transcript repair is not effect evidence.

## Frozen matrix

Counts below are intent/admission/attempt/mutation/executor-terminal/session.
Every convergence interval begins immediately before its permitted recovery
action and ends at the frozen classification, with a bound of ≤1,000 ms.

| Case                                                | Surviving truth and final counts                                                                                                 | Frozen classification and only permitted action                                                       |
| --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Row 1 — before intent commit                        | No job/executor row; definitely not dispatched or invoked; postcondition absent; `0/0/0/0/0/1`                                   | `not_started`; append one truthful session ToolResult; no query, reconcile, or automatic retry        |
| Row 2 — intent before dispatch                      | Intent survives and executor starts unknown; final causal completion/postcondition; `1/1/1/1/1/1`                                | Success; query original owner and same-ID/digest submit once on unknown                               |
| Row 3 — receipt before acceptance commit            | Receipt transaction rolls back to unknown; no pre-recovery admission/invocation/mutation; final causal completion; `1/1/1/1/1/1` | Success; reopen same executor ID/ledger and submit once                                               |
| Row 4 — acceptance commit before reply              | Accepted/attempt-0 survives; no pre-crash invocation/mutation; final causal completion; `1/1/1/1/1/1`                            | Success; query and continue once on same owner                                                        |
| Row 5 — acceptance reply before callback            | Accepted observation and attempt-0 survive; no pre-crash invocation/mutation; final causal completion; `1/1/1/1/1/1`             | Success; continue once on reopened same owner; no resubmit/failover                                   |
| Row 6 — mutation before completion commit           | Accepted/attempt-1, one marker, no terminal row; postcondition satisfied but causal completion absent; `1/1/1/1/0/1`             | `:indeterminate` naming missing terminal proof; never continue, submit, retry, reinvoke, or fail over |
| Row 7 — completion commit before reply              | Original ledger terminal; causal completion and postcondition independently hold; `1/1/1/1/1/1`                                  | Success; query terminal ledger and persist one result; no callback                                    |
| Row 8 — completion reply before session persistence | Terminal controller observation survives; only transcript persistence interrupted; `1/1/1/1/1/1`                                 | Success; pre-hydration append one result; no submit/callback or generic repair                        |
| No-fault control                                    | Full ordered protocol and causal completion; `1/1/1/1/1/1`                                                                       | Success without reconciliation                                                                        |
| Same-digest control                                 | Accepted and terminal replays add no admission, attempt, or mutation; `1/1/1/1/1/1`                                              | Evidence remains identical; exactly one declared continue                                             |
| Conflicting-digest control                          | Same effect-derived ID, digest changed by a nested canonical fixture argument; conflict delta 0; original final `1/1/1/1/1/1`    | Reject `digest_conflict`, preserve evidence, then release original exactly once                       |

## Fresh immutable manifest

`003-effect-receipt-er1-v3-manifest.json` contains 11 case IDs, tokens, and
nested variants never used by v2. Token and variant both enter canonical
operation arguments. Every case/run allocates a fresh workspace, controller
SQLite database, executor SQLite database, Flight Recorder identity, and job
identity. The marker is non-deduplicating and records token, variant, job ID,
and digest.

Seeds are `196613`, `262147`, and `327673`; stability uses seed `196613` with
`--repeat-until-failure 25`. Membership, values, seeds, stores, and commands are
immutable after freeze.

Before freeze, a standalone constructor smoke check may instantiate two
in-memory `Elara.Effect.Job` structs with one effect ID and different nested
arguments. It must prove same job ID/different operation digest without starting
a session, executor, ledger, marker, or matrix case. This validates mechanics
but supplies no target result.

## Invariants and outcomes

1. No case exceeds one admission, callback attempt, mutation, executor terminal
   result, or session ToolResult.
2. Same-ID/digest replay never invokes; a conflicting digest never admits.
3. Accepted work never executes on a replacement logical executor.
4. Attempt 1 permanently forbids reinvocation for this marker.
5. Success/error requires causal terminal proof; attempt without terminal proof
   is indeterminate even if the postcondition is satisfied.
6. Row 1's one session classification is not an executor terminal result.
7. Recovery uses controller/executor/workspace evidence, never transcript
   repair.
8. Every case converges within 1,000 ms.

GATE-1-V3 applies, in order: **Stop — safety** for a safety/control failure;
**Invalid Experiment** only for an independently proven contradiction or
required unobservable metric; **Continue** only when all 11 cases meet every
frozen requirement; otherwise **Stop — contract miss** for an eligible target
miss. A harness exception before target observation aborts the execution and is
not a gate outcome. Narrow and Pivot are ineligible.

## Required post-freeze execution

```text
mix test test/elara/effect/crash_matrix_test.exs --seed 196613
mix test test/elara/effect/crash_matrix_test.exs --seed 262147
mix test test/elara/effect/crash_matrix_test.exs --seed 327673
mix test test/elara/effect/crash_matrix_test.exs --seed 196613 --repeat-until-failure 25
mix test
mix format --check-formatted
mix compile --warnings-as-errors
```

No v3 matrix row may execute before the freeze commit.
