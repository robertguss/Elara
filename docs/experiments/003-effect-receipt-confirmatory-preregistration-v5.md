# EXP-003: durable-effects confirmatory preregistration v5

> - **Preregistration version:** ER-3/FND-2-v5
> - **Exposure boundary:** frozen before any v5 target, comparator, dogfood, or
>   timing output
> - **Frozen against Elara:** `bc1444aacc773b9e7009063e7f40a48f51f0884d`
> - **Pinned baseline target:** `23e603550253c69846795b13cc2f2670f1122e21`
> - **Pinned receipts target:** `9ff416f2c22327c5ef38edcd52a9e89108fbc726`
> - **Pinned comparator:** Lemon `b9ed0660e0d7fe61f38156f0aeb65e839b4e7f39`
> - **Committed future beacon:** drand mainnet round `6428936`, nominally
>   2026-09-01T21:45:00Z
> - **Machine contract:**
>   [`003-effect-receipt-v5-compatibility.json`](003-effect-receipt-v5-compatibility.json)
> - **Canonical issue:**
>   [ROB-860](https://linear.app/robert-guss/issue/ROB-860/er3-v5-fnd-freeze-condition-correct-pre-exposure-protocol)

This artifact is the sole pre-exposure amendment to ER-3/FND-2-v4. V1–v4, their
artifacts, and their issue Results remain immutable. V5 supersedes v4 only for
future confirmatory execution. Every prior rule remains normative unless changed
here.

## Why v4 stopped

V4 first supplied the missing checked-in top-level command and ran its entire
development qualification path. The run completed all 72 development fault
repetitions and all 72 full-shape development no-fault runs, preserving 288
matched started/completed events in the checkpoint. It exposed no held-out fault
row, held-out timing row, comparator fault, dogfood run, `B`, or `T`.

The run found three factual command-model defects:

1. `causal_terminal_evidence_expected_to_survive` was one row-level scalar.
   Baseline F4 correctly converges to manual recovery without causal terminal
   proof, while receipts F4 correctly converges automatically with causal
   terminal proof. One `true` scalar incorrectly applied the receipts contract
   to baseline.
2. Terminal failure diagnostics contained Elixir tuples, which canonical JSON
   cannot encode.
3. Qualification authorization required only `valid=true`; a valid but failing
   development score could have authorized held-out execution.

The frozen v4 amendment forbids patching or retrying an inconsistent command,
and the base protocol requires a fresh future seed even for factual errors found
before exposure. V4 therefore stopped. Its raw checkpoint and failure report
remain development failure evidence and are never v5 qualification evidence.

## Complete exposure ledger

| Evidence category                         | V4 exposure | V5 exposure at freeze |
| ----------------------------------------- | ----------: | --------------------: |
| Development fault runs                    |          72 |                     0 |
| Development full-shape no-fault runs      |          72 |                     0 |
| Internal held-out target fault rows       |           0 |                     0 |
| Internal held-out no-fault timing rows    |           0 |                     0 |
| Internal `B`, `T`, safety, or gate result |           0 |                     0 |
| Lemon fault rows                          |           0 |                     0 |
| Dogfood task or fault runs                |           0 |                     0 |
| GATE-3 decisions                          |           0 |                     0 |

The v4 development score (`valid=true`, `status=Fail`, `B=12`, `T=3`) is a
qualification diagnostic only. It is not v5 evidence and cannot be pooled with
v5.

## Normative change log

1. Protocol identity changes to `ER-3/FND-2-v5`; all generated inputs are fresh.
2. The v4 candidate frame, corrected P05/P06 assignments, fault barriers,
   workspace vocabulary, target commits, comparator pin, Universal scope,
   schedules, metrics, thresholds, Narrow order, stopping rules, and rejection
   of a BEAM-superiority claim are unchanged.
3. Each F1–F4 contract has a condition-specific
   `causal_terminal_evidence_expected_to_survive` map:

   | Fault | Baseline | Receipts |
   | ----- | -------- | -------- |
   | F1    | false    | false    |
   | F2    | false    | false    |
   | F3    | false    | false    |
   | F4    | false    | true     |

4. The materialized row retains the map. Every emitted fault record contains
   only the scalar selected by that run's condition. The scorer validates that
   scalar against the same row map before applying terminal-convergence
   eligibility.
5. Every diagnostic and aggregate in a checkpoint, report, replay, error, or
   score is a canonical JSON value. Tuples, atoms, PIDs, references, and other
   runtime-only terms are forbidden at the report boundary.
6. A qualification authorizes execution only when its replayed score has
   `valid=true` **and** exact `status=Pass`. Any other status fails closed
   before target preparation.
7. V5 uses fresh report/checkpoint protocol identities. The failed v4 checkpoint
   is immutable and cannot be resumed, transformed, or submitted as
   qualification evidence.

No target recovery behavior, task, fault assignment, expected workspace,
expected recovery class, safe action, denominator, score formula, threshold,
timing rule, or gate precedence changes.

## Command-complete execution contract

The one authorized entrypoint remains
`priv/benchmark/run_internal_confirmatory.exs`. ROB-862 must update and freeze
that checked-in command before qualification closes. Its modes are:

```text
mix run priv/benchmark/run_internal_confirmatory.exs -- \
  qualify <v5-manifest> <state-root> <workspace-root> <output.json>

mix run priv/benchmark/run_internal_confirmatory.exs -- \
  execute <v5-manifest> <qualification.json> \
  <state-root> <workspace-root> <output.json>

mix run priv/benchmark/run_internal_confirmatory.exs -- \
  replay <v5-manifest> <execution.json> <score-output.json>
```

The same orchestration function serves `qualify` and `execute`. Qualification
derives only `development_adapter_fixture` rows from the exact v5 manifest and
cannot authorize a held-out row. Execute requires the exact v5 manifest and a
fresh v5 qualification whose frozen source, target, command, configuration,
evidence, runner, adapter, scorer, report, and replay identities match current
bytes and whose replayed score is exactly valid Pass.

The command preserves v4's fixed schedules, target pins, exact-manifest
authorization, fresh fixture reset, absent path preconditions, atomic
started/completed checkpoints, raw-before-aggregate evidence, stop-on-first-
failure policy, and refusal to resume or retry an unmatched started event. A
failure never authorizes a replacement, denominator reduction, synthesized
record, or partial gate decision.

V5 report schema is `elara.exp003.internal-confirmatory-report.v2`; checkpoint
schema is `elara.exp003.internal-confirmatory-checkpoint.v2`. Replay reads the
canonical raw arrays, independently reruns the frozen scorer in a fresh BEAM,
and writes only the canonical JSON score. Its bytes must equal the embedded
score after canonical encoding.

ROB-862 must run the whole command on fresh development fixtures: 72 fault runs,
two no-fault warmups and 10 measured repetitions per fixture/condition, atomic
checkpoint validation, and independent replay. It must prove dirty path,
manifest/hash drift, interruption, missing record, replay mismatch, non-JSON
diagnostic, and valid-but-non-Pass qualification failures close before held-out
execution. Qualification must state zero v5 confirmatory exposure and no `B` or
`T` claim.

## Committed future beacon

Selection uses the League of Entropy drand default mainnet:

- chain hash:
  `8990e7a9aaed2ffed73dbd7092123d6f289930540d7651336225dc172e51b2ce`;
- genesis time: `1595431050` Unix seconds;
- period: 30 seconds;
- committed round: `6428936`;
- nominal time: `1788299100` Unix seconds, 2026-09-01T21:45:00Z;
- API path: `/<chain-hash>/public/6428936` on official relays.

The schedule is exact:

```text
1595431050 + (6428936 - 1) * 30 = 1788299100
```

ROB-861 must fetch exactly this round at or after nominal time from
`api.drand.sh` and `drand.cloudflare.com`, require equal round, signature,
previous-signature, and randomness, and verify both responses against pinned
chain information with the official drand client. Early availability, relay
disagreement, verification failure, or unavailability blocks materialization and
never authorizes another round.

Derive the v5 selection seed as:

```text
SHA-256(
  "elara:exp-003:er3:fnd-2:v5\0" ||
  chain_hash || ":" || "6428936" || ":" || randomness_hex || ":" ||
  "bc1444aacc773b9e7009063e7f40a48f51f0884d"
)
```

Order keys and generated tokens use the unchanged v2–v4 derivation rules. V5
uses new paths and never overwrites prior artifacts. Before selection, the
materializer must mechanically validate all 20 candidates, 40 candidate/fault
assignments, workspace semantics, and the four condition-specific causal maps.

## Preserved v4 failure identities

| Artifact                          | SHA-256                                                            |
| --------------------------------- | ------------------------------------------------------------------ |
| failed checkpoint                 | `e206f46325c420f5c664a0c185b223896e4a745ab598cc7091350769e5878a41` |
| v4 entrypoint module              | `856cf4b16c156c1dbb462186d60d1e472ca0de7041f6506d5e930e6f0ccd4588` |
| v4 entrypoint CLI                 | `f3ff39bb7a0184e7cbe99414bf457b7510fa0b225e22de7e27e5e1cd46d1bea4` |
| v4 adapter                        | `d95ba568b3b03ac15477e65596b3fece7023310ff3694e617ec1f50f3d472183` |
| v4 qualification source           | `0935535262146339b388d2e220c11b2b24b06b436544d03ab752b931d9b3e825` |
| v4 scorer                         | `5eca1f7bfac64dc52d398e1ecf2a1d95b53b1ae36e3165348bb108666ac013a5` |
| v4 derived qualification manifest | `df817f2439071ce4050d18820bb4b5bef7d642a614638f5a44415c9838888d46` |

## Execution chain and invalidation

The only valid order is:

```text
ROB-860 amendment
  -> ROB-861 rematerialization
  -> ROB-862 command correction, qualification, and freeze
  -> ROB-863 immutable internal execution
  -> ROB-864 dogfood execution or protocol-required non-execution
  -> ROB-865 GATE-3
```

ROB-863 is the first unit allowed to produce v5 target fault or no-fault timing
output. Any change after relevant exposure to seed, membership, assignments,
workspace or causal-evidence semantics, target or adapter semantics, entrypoint,
configuration, evidence/report schema, runner, scorer, threshold, comparator, or
dogfood plan invalidates v5 and requires a new future seed and issue chain.

## Completion checks

ROB-860 must prove that its commit predates 2026-09-01T21:45:00Z, round
arithmetic is exact, every preserved v4 artifact remains byte-identical, the v5
graph is acyclic with one active root, exposure is zero, and JSON, format,
warnings-as-errors compilation, the full test suite, clean Git, and pushed
`origin/main` all pass.
