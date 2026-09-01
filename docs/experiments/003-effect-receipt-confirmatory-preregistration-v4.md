# EXP-003: durable-effects confirmatory preregistration v4

> - **Preregistration version:** ER-3/FND-2-v4
> - **Exposure boundary:** frozen before any v4 target, comparator, dogfood, or
>   timing output
> - **Frozen against Elara:** `1d57c7e11d3dbb9b77b3cef5c359c39a787e7327`
> - **Pinned baseline target:** `23e603550253c69846795b13cc2f2670f1122e21`
> - **Pinned receipts target:** `9ff416f2c22327c5ef38edcd52a9e89108fbc726`
> - **Pinned comparator:** Lemon `b9ed0660e0d7fe61f38156f0aeb65e839b4e7f39`
> - **Committed future beacon:** drand mainnet round `6428786`, nominally
>   2026-09-01T20:30:00Z
> - **Machine contract:**
>   [`003-effect-receipt-v4-compatibility.json`](003-effect-receipt-v4-compatibility.json)
> - **Canonical issue:**
>   [ROB-854](https://linear.app/robert-guss/issue/ROB-854/er3-v4-fnd-freeze-a-command-complete-pre-exposure-protocol)

This artifact is the sole pre-exposure amendment to ER-3/FND-2-v3. V1–v3, their
artifacts, and their issue Results remain immutable. V4 supersedes v3 only for
future confirmatory execution. Every v1–v3 rule remains normative unless changed
here.

## Why v3 stopped

V3 corrected the impossible v2 rows and qualified the internal adapter without
exposing a held-out fault row. Its immutable execution still could not begin:
the qualification unit froze only `priv/benchmark/qualify_internal_adapter.exs`,
which executes development fixtures and explicitly emits zero confirmatory
exposure. The repository had frozen runner, adapter, authorization, and scorer
primitives, but no checked-in top-level command defining confirmatory
orchestration, checkpointing, failure handling, raw-record persistence, scoring,
or replay.

An ad hoc `mix run -e` or temporary driver would have introduced a new command
and configuration after qualification closed. V3 therefore stopped with zero
target fault and timing runs. This is a harness-capability failure, not target
safety, recovery, correctness, timing, or value evidence.

## Complete exposure ledger

| Evidence category                         | V3 exposure | V4 exposure at freeze |
| ----------------------------------------- | ----------: | --------------------: |
| Internal target fault rows                |           0 |                     0 |
| Internal no-fault benchmark timing rows   |           0 |                     0 |
| Internal `B`, `T`, safety, or gate result |           0 |                     0 |
| Lemon fault rows                          |           0 |                     0 |
| Dogfood task or fault runs                |           0 |                     0 |
| GATE-3 decisions                          |           0 |                     0 |

V3 materialization and adapter qualification remain development evidence. They
are not v4 confirmatory evidence.

## Normative change log

1. Protocol identity changes to `ER-3/FND-2-v4`; all generated inputs are fresh.
2. The v3 compatibility contract, candidate frame, corrected P05/P06
   assignments, workspace vocabulary, Universal scope, target commits, Lemon
   pin, metrics, thresholds, Narrow order, stopping rules, and rejection of a
   BEAM-superiority claim are unchanged.
3. Qualification must freeze one checked-in top-level entrypoint that is the
   only command authorized for v4 qualification, execution, and replay.
4. Frozen runner/scorer APIs without that entrypoint are insufficient. No ad hoc
   evaluation string, temporary driver, notebook, or manually assembled pipeline
   may produce confirmatory evidence.
5. A missing, drifted, interrupted, or inconsistent entrypoint run is retained
   as invalidating evidence. It never authorizes a row replacement, retry,
   denominator reduction, or partial gate decision.

## Command-complete execution contract

Before ROB-856 may close, the repository must contain and hash exactly one
entrypoint at `priv/benchmark/run_internal_confirmatory.exs`. Its frozen modes
are:

```text
mix run priv/benchmark/run_internal_confirmatory.exs -- \
  qualify <v4-manifest> <state-root> <workspace-root> <output.json>

mix run priv/benchmark/run_internal_confirmatory.exs -- \
  execute <v4-manifest> <qualification.json> \
  <state-root> <workspace-root> <output.json>

mix run priv/benchmark/run_internal_confirmatory.exs -- \
  replay <v4-manifest> <execution.json> <score-output.json>
```

The same orchestration function must serve `qualify` and `execute`.
Qualification uses only derived `development_adapter_fixture` rows and cannot
authorize a v4 held-out row. Execute requires the exact v4 manifest and a
qualification report whose frozen source, target, command, configuration,
evidence, runner, adapter, and scorer identities match current bytes.

The entrypoint must:

- materialize `Runner.fault_schedule/1` and `Runner.no_fault_schedule/1` without
  filtering or reordering;
- execute every fault row in fixed
  `baseline, receipts, receipts, baseline, baseline, receipts` order with three
  repetitions per condition and a fresh fixture per repetition;
- execute two no-fault warmups and 10 measured repetitions per selected task and
  condition in the frozen runner order;
- use only the pinned target commits and the adapter's exact-manifest
  authorization;
- create state, workspace, checkpoint, and output paths only when all are
  absent; refuse dirty or prior paths;
- atomically record a `started` checkpoint before each run and a `completed`
  checkpoint containing validated evidence after it;
- never resume or retry when a checkpoint contains an unmatched `started`
  record; such an interruption is an invalid run;
- stop on the first adapter, hook, evidence, fixture, process, storage,
  deadline, or scoring failure without synthesizing a record;
- write the canonical output only after every record validates and scoring
  completes; and
- preserve raw records before aggregates.

The canonical report schema is `elara.exp003.internal-confirmatory-report.v1`.
It contains protocol/manifest identity, mode, frozen source and configuration
identities, execution and exposure metadata, every fault record, every no-fault
record, the unchanged `elara.exp003.score.v1` result, diagnostics, and
checkpoint digest. JSON is canonicalized by the entrypoint. Replay loads the raw
arrays, reruns the frozen scorer in a fresh BEAM, and writes only the canonical
score; it must match the embedded score byte-for-byte after canonical encoding.

ROB-856 must run the complete command path on development fixtures, including
all development fault repetitions and the full warmup/measured timing shape. It
must prove fail-closed behavior for dirty paths, hash drift, altered manifests,
interrupted checkpoints, missing records, and replay mismatch before freezing
source and report identities. Qualification output is development evidence and
must state zero v4 confirmatory exposure and no `B`/`T` claim.

## Committed future beacon

Selection uses the League of Entropy drand default mainnet:

- chain hash:
  `8990e7a9aaed2ffed73dbd7092123d6f289930540d7651336225dc172e51b2ce`;
- genesis time: `1595431050` Unix seconds;
- period: 30 seconds;
- committed round: `6428786`;
- nominal time: `1788294600` Unix seconds, 2026-09-01T20:30:00Z;
- API path: `/<chain-hash>/public/6428786` on official relays.

The schedule is exact:

```text
1595431050 + (6428786 - 1) * 30 = 1788294600
```

ROB-855 must fetch exactly this round at or after nominal time from
`api.drand.sh` and `drand.cloudflare.com`, require identical round, signature,
previous-signature, and randomness values, and verify the signature against
pinned chain information using the official drand client. Early availability,
relay disagreement, verification failure, or unavailability blocks
materialization and never authorizes another round.

Derive the v4 selection seed as:

```text
SHA-256(
  "elara:exp-003:er3:fnd-2:v4\0" ||
  chain_hash || ":" || "6428786" || ":" || randomness_hex || ":" ||
  "1d57c7e11d3dbb9b77b3cef5c359c39a787e7327"
)
```

Order keys and generated tokens use the unchanged v2/v3 derivation rules. V4
uses new versioned paths and must not overwrite prior artifacts.

## Execution chain and invalidation

The only valid order is:

```text
ROB-854 amendment
  -> ROB-855 rematerialization
  -> ROB-856 command construction, qualification, and freeze
  -> ROB-857 immutable internal execution
  -> ROB-858 dogfood execution or protocol-required non-execution
  -> ROB-859 GATE-3
```

ROB-857 is the first unit allowed to produce v4 target fault or no-fault timing
output. Any change after relevant exposure to seed, membership, assignments,
workspace semantics, target or adapter semantics, entrypoint, command,
configuration, evidence/report schema, runner, scorer, threshold, comparator, or
dogfood plan invalidates v4 and requires a new future seed and issue chain.

## Completion checks

ROB-854 must prove that its commit predates 2026-09-01T20:30:00Z, round
arithmetic is exact, every preserved v3 artifact hash remains unchanged, the v4
issue graph is acyclic with one active root, exposure is zero, and format,
warnings-as-errors compilation, the full test suite, and clean/pushed Git all
pass.
