# EXP-003: durable-effects confirmatory preregistration v7

> - **Preregistration version:** ER-3/FND-2-v7
> - **Exposure boundary:** frozen after exhaustive development command-path
>   qualification and before any V7 beacon fetch, candidate selection, held-out
>   literal, target fault/timing, comparator, dogfood, `B`, or `T` output
> - **Frozen against Elara:** `98cf40a03b68a943f75342ac9704257bbb083885`
> - **Pinned targets:** baseline
>   `23e603550253c69846795b13cc2f2670f1122e21`; receipts
>   `9ff416f2c22327c5ef38edcd52a9e89108fbc726`
> - **Committed future beacon:** drand mainnet round `6429446`, nominally
>   2026-09-02T02:00:00Z
> - **Machine contract:**
>   [`003-effect-receipt-v7-protocol.json`](003-effect-receipt-v7-protocol.json)
> - **Pre-beacon command-path proof:**
>   [`003-effect-receipt-v7-command-path-preflight.json`](003-effect-receipt-v7-command-path-preflight.json)
> - **Canonical issue:**
>   [ROB-874](https://linear.app/robert-guss/issue/ROB-874/er3-v7-fnd-freeze-the-command-path-qualified-protocol-and-future)

V7 is a fresh protocol. V1–V6 and their failures remain immutable. V7 tests a
runtime-neutral durable-effects protocol implemented compatibly with BEAM
ownership; it does not test or support BEAM superiority.

## Why V6 stopped and what V7 changes

V6's sole execution stopped after 18 completed held-out fault runs and one
unmatched start. P06 was the first selected multi-step task, and the frozen
adapter rejected its two tool calls before target execution. The partial V6
evidence is invalid and unscored. It is never retried, resumed, repaired,
pooled, or used to authorize V7.

ROB-873 repaired the development boundary before choosing this beacon. It
constructed all 20 candidates and drove every plan through the exact adapter,
pinned targets, target runner, fault owner, recovery path, and evidence
classifier. Its three byte-identical canonical reports have SHA-256
`c7522da0fd1730b61241898450893b7761d59ea8dab0721cb01d0e4e7eabf435`.
The proof contains 20 bijective mappings, 40 no-fault runs, 68 eligible
primary/secondary fault runs, four P06 continuation probes, and 112 total
command-path runs. All 72 eligible fault runs were valid, bounded, and had one
target-bound barrier/injection with no harness or safety failure.

This development proof exposed no V7 beacon, candidate selection, held-out
literal, target timing/fault result, comparator, dogfood result, `B`, or `T`.

## Frozen conditional frame and estimand

Eligibility `E=1` means both pinned conditions pass the frozen no-fault outcome,
workspace, provider-consumption, identity, and cardinality contract without an
adapter-owned semantic shim. The exact eligible frame is:

```text
P01 P02 P04 P06 P07 P08
S01 S02 S03 S04
W01 W02 W03 W05 W06 W07 W08
```

The estimand is conditional on these 17 candidates. V7 makes no inference to
the original 20-candidate population or excluded idempotent/conflict semantics.
The bilateral exclusions are fixed facts:

- P03 expected `ok` for an already-satisfied patch; both unchanged builtins
  returned `error_conflict` and preserved the correct bytes.
- P05 expected a same-file conflict and no mutation; both returned `ok` and
  mutated.
- W04 expected a write conflict and no mutation; both returned `ok` and
  overwrote.

No V7 result may add, remove, replace, or reinterpret a candidate. A later
failure invalidates V7; it never shrinks a denominator or triggers skip-and-redraw.

## Frozen sampling and inclusion probabilities

Order keys are lowercase `SHA-256(seed || NUL || candidate_id)`. Select the
lowest-key write and patch candidate for each primary F1–F4 stratum, include
S01–S04, and sort the resulting 12 tasks by key. Every selected task contributes
its primary row; the eight lowest-key selected tasks also contribute their
secondary row, yielding exactly 20 locked rows.

Conditional task inclusion probabilities are `1/n` for primary-stratum size
`n`: 1/2 for P01/P06, P02/P08, W01/W05; 1/3 for W02/W06/W08; and 1 for P04,
P07, W03, W07, and S01–S04. The corresponding unconditional secondary-row
probabilities are 8981/21879 for size two, 33464/109395 for size three, and
84223/145860 for size one. They sum to eight; task probabilities sum to 12. The
machine contract freezes every candidate's class, faults, stratum size, and
both probabilities. Rows are not weighted or generalized beyond the conditional
frame.

## Normative command-path contract

Every ordered plan step maps bijectively to one unique call ID and exact
`plan.steps[i].arguments` reference, followed by one final assistant turn.
Malformed, extra, missing, or repeated shapes fail closed. The fault target must
resolve exactly once across plan step, provider turn, one-shot barrier,
controller intent, and executor ledger. Target and task aggregate cardinalities
are separate.

P06 uses target `exp003-p06` and continuation
`exp003-p06-continuation`:

| Branch                               | Calls | Tools | Provider disposition                |
| ------------------------------------ | ----: | ----: | ----------------------------------- |
| no-fault / receipts F2               |     3 |     2 | completed                           |
| baseline F2/F3 or receipts F3        |     2 |     1 | `skipped_non_ok` with frozen halt   |
| F1/F4 controller recovery            |     1 |     1 | continuation and final unconsumed   |

The halt text is exactly `Task halted after non-ok target result.` Continuation
is never re-injected, and recovery never invents a model-loop continuation.
Receipts P06 no-fault and F2 have two distinct task jobs and exactly one target
job; other P06 receipt faults have one task/target job. One-step receipt runs
have one. Baseline has none.

Workspace observations resolve the full alias set `initial_reset_workspace`,
`pre_effect_workspace`, `fault_target_postcondition`, and
`complete_task_workspace`. The expected label must be an admissible alias, but
bytes never prove causation. Target mutation count is callback attempts times
the frozen target-step mutation declaration. S04-F2 receipts may match all four
aliases while its causal receipt, not bytes, proves completion.

P06's converged workspaces are F1 baseline pre-effect / receipts target
postcondition; F2 baseline pre-effect / receipts complete task; F3 target
postcondition in both; and F4 target postcondition in both. F4 is intentionally
partial task workspace after controller recovery.

## Inherited fault, execution, and evidence rules

The F1–F4 external schedules remain unchanged: controller loss after admission
and before dispatch; executor loss after acceptance and before callback;
executor loss after one target mutation and before terminal delivery; and
controller loss after terminal delivery and before session persistence. F1–F3
have no expected surviving causal terminal proof. F4 has none for baseline and
requires an atomic job-ID/digest-bound causal receipt for receipts. Baseline
durable seams remain N/A/non-equivalent and are never fabricated.

Fault order is exactly `baseline, receipts, receipts, baseline, baseline,
receipts`, three repetitions per condition from fresh fixtures. No-fault timing
uses two warmups and ten measured repetitions per task/condition. Any missing,
inconsistent, late, duplicate, dirty, malformed, interrupted, or mismatched
evidence stops and invalidates V7 without retry, resume, replacement, or reduced
denominator.

Canonical records preserve raw evidence before aggregates and separately report
controller/executor facts, workspace aliases, historical knowledge, session
classification, safe action, causal survival, convergence, target/task counts,
mutations, interventions, timing, CPU, storage, and artifact hashes.

## Scoring, safety, and GATE-3

`bad` is automatic safe indeterminate, manual recovery, or ambiguous no safe
action. `B` and `T` count bad baseline and receipts rows over all 20 locked
internal rows. Material improvement requires all three exact tests:

```text
B >= 2
B - T >= 2
2 * (B - T) >= B
```

Passage also requires zero safety disqualifiers, 100% correct no-fault
workspaces, correct bounded knowledge/safe-action convergence for every row,
causal terminal convergence for every applicable row, corpus median
receipts/baseline timing ratio at most 1.20, and no task ratio above 2.0. CPU and
storage are descriptive.

Safety is Stop-first. Duplicate/corrupt mutation, false terminal claims,
accepted-job failover, unprotected callback retry, hidden substitution, or
post-exposure tuning disqualifies the run. Decision precedence is Stop on
invalidity/safety; Continue on complete full-scope passage; first independently
passing strict Narrow scope in order write+patch, write, patch; one of the
already-frozen `sidecar_ownership`, `causal_persistence_boundary`, or
`safe_action_presentation` Pivots; otherwise Stop. Narrow requires at least four
tasks, six rows, `B >= 2`, eight mapped dogfood tasks, and independent passage
of every applicable threshold.

## External and dogfood rules

Lemon remains pinned at `b9ed0660e0d7fe61f38156f0aeb65e839b4e7f39`.
No-fault equivalence is required for every included operation class; recovery
comparison requires three equivalent rows across two fault types. The pinned
runtime supplies zero equivalent durable-recovery rows, so the valid expected
result is **Insufficient comparability**, no external fault execution, and no
comparative claim.

Dogfood retains D01–D12, seed-derived order, 10 injected tasks, two controls,
at least five failure types, frozen prompts/snapshots/acceptance checks, and no
replacement. It passes only with `D >= 8`, `G == I`, `5 * U >= 4 * D`, `A == 0`,
and no safety disqualifier. A mapping failure is invalid evidence, never a task
substitution.

## Future beacon and seed

Selection uses League of Entropy drand default mainnet:

- chain hash
  `8990e7a9aaed2ffed73dbd7092123d6f289930540d7651336225dc172e51b2ce`;
- genesis Unix time `1595431050` and 30-second period;
- round `6429446`;
- nominal Unix time `1788314400`, 2026-09-02T02:00:00Z;
- exact path
  `/8990e7a9aaed2ffed73dbd7092123d6f289930540d7651336225dc172e51b2ce/public/6429446`
  on `api.drand.sh` and `drand.cloudflare.com`.

The arithmetic is exact:

```text
1595431050 + (6429446 - 1) * 30 = 1788314400
```

ROB-875 must not fetch before nominal time. At or after it, fetch only this
round from both relays; require equal round, signature, previous signature, and
randomness; and verify both against the pinned chain/public key with
`drand-client@1.4.2`. Early availability, disagreement, unavailability, or
verification failure stops V7 and never permits another round or retry.

Derive the seed exactly:

```text
SHA-256(
  "elara:exp-003:er3:fnd-2:v7\0" ||
  chain_hash || ":" || "6429446" || ":" || randomness_hex || ":" ||
  "98cf40a03b68a943f75342ac9704257bbb083885"
)
```

Generated tokens are the first 16 lowercase hex characters of
`SHA-256(seed || NUL || id || NUL || field)`. V1–V6 rounds, seeds, orders,
literals, and results cannot authorize V7. All outputs use fresh V7 paths.

## Order, exposure, and invalidation

The only valid order is ROB-873 command-path proof → ROB-874 protocol/beacon →
ROB-875 fresh materialization → ROB-876 command qualification → ROB-877 sole
immutable execution → ROB-878 dogfood/non-execution and ROB-879 GATE-3.

At freeze, the future round is committed but unfetched. Selection, held-out
literals, target faults/timing, external faults, dogfood, `B`, and `T` remain
zero. Any factual pre-result change requires a versioned successor and genuinely
future beacon. After any result, changing seed, frame, literals, assignment,
workspace/causal semantics, target, adapter, command, schema, schedule, scorer,
denominator, threshold, comparator, or dogfood plan invalidates V7 and requires
fresh held-out evidence. Exposed output remains development/regression evidence
only.

## Frozen limitations

- The estimand is conditional on command-path eligibility, not the original 20.
- Synthetic tasks test harness recovery, not general agent quality.
- Baseline seams are externally aligned but not receipt-native.
- Workspace postconditions do not prove causal completion.
- Lemon is also BEAM-based and cannot establish BEAM superiority.
- CPU/storage are descriptive, and external recovery comparability is expected
  to remain insufficient.
