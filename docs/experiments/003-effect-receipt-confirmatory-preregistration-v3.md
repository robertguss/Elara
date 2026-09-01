# EXP-003: durable-effects confirmatory preregistration v3

> - **Preregistration version:** ER-3/FND-2-v3
> - **Amendment freeze timestamp:** 2026-09-01T06:12:46Z
> - **Exposure boundary:** frozen before any v3 target, comparator, or dogfood
>   fault output
> - **Frozen against Elara:** `b0c0fd4ac46d6d3e361aa923ffdc0b2e42a5ebb9`
> - **Pinned comparator:** Lemon `b9ed0660e0d7fe61f38156f0aeb65e839b4e7f39`
> - **Committed future beacon:** drand mainnet round `6427122`, nominally
>   2026-09-01T06:38:00Z
> - **Machine contract:**
>   [`003-effect-receipt-v3-compatibility.json`](003-effect-receipt-v3-compatibility.json)
> - **Canonical issue:**
>   [ROB-848](https://linear.app/robert-guss/issue/ROB-848/er3-v3-fnd-amend-and-freeze-the-row-compatible-contract)

This artifact is the sole pre-exposure amendment to ER-3/FND-2-v2. V1, v2, their
artifacts, and their issue Results remain immutable. V3 supersedes v2 only for
future confirmatory execution. The runtime-neutral durable-effects hypothesis,
thresholds, Universal scope, comparator pin, and rejection of a BEAM-superiority
claim do not change.

## Why v2 stopped

Pre-exposure qualification found two impossible frozen row assignments:

- `P05-F3` required one job-attributed mutation, but `P05` deliberately applies
  one environmental edit before dispatch and then returns `error_conflict`
  without a job mutation. Environmental activity cannot be relabeled as the
  target job's mutation.
- `P06-F3` required both a first-job indeterminate/error outcome that halts
  continuation and the complete two-job no-fault workspace. Those observations
  cannot coexist.

Qualification also exposed a vocabulary defect: v2 called the F1/F2 barrier
workspace `initial_workspace`, even though declared environmental changes are
applied before adapter dispatch. V2 therefore stopped before executing a target
fault row. ROB-844 through ROB-847 remain Canceled and cannot acquire a gate
outcome.

## Complete exposure ledger

| Evidence category                         | V2 exposure | V3 exposure at freeze |
| ----------------------------------------- | ----------: | --------------------: |
| Internal target fault rows                |           0 |                     0 |
| Internal no-fault benchmark timing rows   |           0 |                     0 |
| Internal `B`, `T`, safety, or gate result |           0 |                     0 |
| Lemon fault rows                          |           0 |                     0 |
| Dogfood task or fault runs                |           0 |                     0 |
| GATE-3 decisions                          |           0 |                     0 |

V2 materialization and no-fault qualification evidence remains development
evidence. It is not v3 confirmatory evidence.

## Normative change log

Every v1/v2 rule remains normative unless changed here.

1. Protocol identity changes to `ER-3/FND-2-v3`; all generated inputs are fresh.
2. `P05` keeps primary F2 and changes secondary F3 to F4.
3. `P06` keeps primary F1 and changes secondary F3 to F2.
4. The materializer must validate all 48 primary/secondary assignments against
   the machine contract before selection. An incompatible assignment blocks
   materialization; it cannot be replaced after selection.
5. Workspace evidence has four distinct identities:
   - `initial_reset_workspace`: exact fixture state before declared changes;
   - `pre_effect_workspace`: state after declared environmental changes but
     before the fault-target callback;
   - `fault_target_postcondition`: state after the target job's defined effect;
   - `complete_task_workspace`: state after all live-controller continuation.
6. F1 and F2 require zero **job-attributed** mutations at their barriers and
   observe `pre_effect_workspace`. Declared environmental mutations are recorded
   separately and cannot satisfy any job-mutation requirement.
7. F3 requires exactly one job-attributed mutation and observes the
   `fault_target_postcondition`. Only a one-step target whose full fault-row
   contract does not require later live-controller continuation may receive F3.
8. F4 occurs after the target terminal and uses the task-defined mutation count;
   no-op and conflict terminals may have zero job mutations.
9. The workspace at a barrier, the fault-target postcondition, and the complete
   task workspace are scored separately. A partial workspace is never silently
   compared with the no-fault final workspace.

The 24-candidate frame, primary assignments, and all other secondary assignments
remain unchanged. The machine contract records all candidates, both assignments,
target and environmental mutation counts, step counts, workspace contracts, and
exact amendments.

## Multi-step `P06` contract

`P06` has a fault-target patch followed by a second job. The target adapter is
not allowed to invent model-loop continuation after controller restart.

- Under primary F1, baseline converges at `pre_effect_workspace`. Receipts may
  recover the first job and converge at `fault_target_postcondition`, but the
  restarted controller does not run the second job. That is a partial task, not
  a complete no-fault workspace.
- Under secondary F2, the live receipts controller receives the first terminal
  and runs continuation once, so receipts converges at
  `complete_task_workspace`. Baseline loses the worker before callback and
  remains at `pre_effect_workspace`.

The materializer must encode these condition-specific expectations. A generic
full-workspace expectation for either row is invalid.

## Committed future beacon

Selection uses the League of Entropy drand default mainnet:

- chain hash:
  `8990e7a9aaed2ffed73dbd7092123d6f289930540d7651336225dc172e51b2ce`;
- genesis time: `1595431050` Unix seconds;
- period: 30 seconds;
- committed round: `6427122`;
- nominal time: `1788244680` Unix seconds, 2026-09-01T06:38:00Z;
- API path: `/<chain-hash>/public/6427122` on official relays.

The schedule is exact:

```text
1595431050 + (6427122 - 1) * 30 = 1788244680
```

ROB-849 must fetch exactly this round at or after nominal time from
`api.drand.sh` and `drand.cloudflare.com`, require identical round, signature,
previous-signature, and randomness values, and verify the signature against
pinned chain information using an official drand client. Early availability,
relay disagreement, verification failure, or unavailability blocks
materialization and never authorizes another round.

Derive the v3 selection seed as:

```text
SHA-256(
  "elara:exp-003:er3:fnd-2:v3\0" ||
  chain_hash || ":" || "6427122" || ":" || randomness_hex || ":" ||
  "b0c0fd4ac46d6d3e361aa923ffdc0b2e42a5ebb9"
)
```

Order keys and generated tokens use the unchanged v2 derivation rules. V3 uses
new versioned paths and must not overwrite v1 or v2 artifacts.

## Execution and invalidation

The only valid order is:

```text
ROB-848 amendment
  -> ROB-849 rematerialization
  -> ROB-850 adapter qualification/freeze
  -> ROB-851 immutable internal execution
  -> ROB-852 dogfood execution or real safety-blocked result
  -> ROB-853 GATE-3
```

ROB-851 is the first unit allowed to produce a v3 target fault output. Any
change after exposure to seed, membership, assignments, workspace semantics,
target or adapter semantics, scorer, threshold, comparator, or dogfood plan
invalidates v3 and requires a new future seed and new issue identities.

## Completion checks

ROB-848 must prove that:

- this commit predates 2026-09-01T06:38:00Z;
- all 24 candidates and 48 assignments validate mechanically;
- restoring `P05` secondary F3 or `P06` secondary F3 fails validation;
- future-round arithmetic and the zero-exposure statement are exact;
- the recorded v1/v2 artifact hashes remain unchanged; and
- formatting, warnings-as-errors compilation, focused tests, and the full test
  suite pass.
