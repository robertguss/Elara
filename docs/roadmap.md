# Elara roadmap

> **Canonical roadmap and status source**<br> **Updated:** 2026-09-02<br>
> **Owner:** solo development with AI collaborators

This file replaces Linear as Elara's planning and status system. Historical
Linear projects and issues are preserved in
[`roadmap-history.md`](roadmap-history.md); their links are provenance only and
are not required to determine current work.

Repository experiment documents remain immutable evidence. This roadmap may link
to them, but it must never rewrite an exposed experiment to improve its outcome.

## Working rules

- Use at most one `IN PROGRESS` item. Normally one next executable item is
  either `IN PROGRESS` or `TODO`; all successors remain `BLOCKED`. When the next
  item has an explicit external time gate, zero items may be executable and that
  item remains `BLOCKED` until the gate opens.
- An item becomes `DONE` only after its Result contains the pushed commit,
  checks, deviations, and remaining uncertainty.
- A failed confirmatory attempt is preserved and never repaired, resumed,
  retried, pooled, or relabeled under the same exposed evidence boundary.
- Build and mechanically validate commands, adapters, materializers, scorers,
  and output paths before committing future randomness.
- Safety and experimental validity precede favorable results.
- Workspace bytes may prove a current postcondition, not causal job completion.
- No current experiment supports a BEAM-superiority claim. EXP-003 tests a
  runtime-neutral durable-effects protocol implemented compatibly with BEAM
  ownership boundaries.
- Commit and push each completed item before starting its successor.

Statuses are `TODO`, `IN PROGRESS`, `BLOCKED`, `DONE`, `CANCELED`, and
`INVALID`.

## Current state

Elara already has supervised session actors, a pure session reducer, persisted
histories, detachable clients, capability-routed workers, deterministic replay,
runtime observability, declarative write and literal-patch reconciliation, and
truthful opaque-shell indeterminacy.

The durable-effects evidence chain currently says:

1. **ER-1 v3: Continue.** Stable job identity, durable intent, executor
   acceptance/completion receipts, and restart reconciliation passed the fresh
   synthetic matrix after two invalid earlier attempts.
2. **ER-2: Continue — Universal.** Write, literal patch, and opaque shell share
   one truthful protocol, with operation-specific evidence and no generic shell
   exactly-once claim.
3. **ER-3: No decision.** Seven confirmatory versions found harness/protocol
   defects before complete valid evidence. V7 exposed its committed beacon, then
   stopped at the first materializer source guard before selection or output.
   Its evidence is immutable in
   [`003-effect-receipt-v7-materialization-failure.md`](experiments/003-effect-receipt-v7-materialization-failure.md).

V8 now has an explicit pre-beacon-tested materializer and a pushed confirmatory
protocol. Its next step is time-gated: fetch the committed drand round exactly
once at or after 2026-09-02T12:00:00Z, never before.

## Execution queue

| ID       | Status  | Item                                                 | Depends on                |
| -------- | ------- | ---------------------------------------------------- | ------------------------- |
| ER3-V8-1 | DONE    | Build and freeze an explicit pre-beacon materializer | V7 immutable failure      |
| ER3-V8-2 | DONE    | Freeze the V8 protocol and future beacon             | ER3-V8-1                  |
| ER3-V8-3 | BLOCKED | Fetch and materialize the fresh V8 corpus            | ER3-V8-2 + committed time |
| ER3-V8-4 | BLOCKED | Run qualification through the frozen command stack   | ER3-V8-3                  |
| ER3-V8-5 | BLOCKED | Execute the sole internal comparison                 | ER3-V8-4                  |
| ER3-V8-6 | BLOCKED | Execute dogfood or record required non-execution     | ER3-V8-5                  |
| ER3-V8-7 | BLOCKED | Apply Gate 3 and record the thesis decision          | ER3-V8-5 + ER3-V8-6       |

## ER3-V8-1 — Build and freeze an explicit pre-beacon materializer

**Status:** DONE

### Outcome

Replace the failed V7 textual-transform wrapper with one explicit V8
materialization path that is fully executable, auditable, and byte-deterministic
before any V8 beacon is selected or fetched.

### Scope

- Preserve every V1–V7 artifact byte-for-byte, including the failed V7 source
  and beacon evidence.
- Implement a production materializer that consumes a versioned protocol and
  verified beacon record as data. Do not generate executable source with
  `String.replace/3` or inherit stale version paths implicitly.
- Fail closed on protocol, source, report, frame, beacon, client, chain,
  candidate, path, schema, count, or output-state mismatch.
- Construct and validate all 17 command-path-eligible candidates before
  sampling. Selection may choose only from that already-constructed frame.
- Validate the complete mapping/provider/target/cardinality/continuation,
  workspace-alias, causal-evidence, F1–F4, external-attestation, and
  dogfood-plan contracts inherited from the pushed V7 protocol.
- Exercise the exact production materialization path twice from absent outputs
  using fixed, explicitly non-confirmatory development entropy; require
  byte-identical manifest, rows, literals, fixtures, external attestation, and
  dogfood plan.
- Drive the development outputs through the exact command, adapter, provider,
  target runner, barriers, classifier, checkpoint, scorer, and replay stack
  intended for V8 qualification and execution. The later protocol must pin this
  already-proven stack rather than creating it after beacon exposure.
- Add fail-closed tests for every stale V7 failure mode, especially snake-case
  paths, generated source identity, missing output parents, existing output, and
  a report hash paired with the wrong source path.
- Produce a pre-beacon qualification report containing source hashes, all 17
  candidate construction proofs, selected development rows, output hashes, and
  zero V8 beacon/held-out exposure.

### Non-goals

No future beacon commitment or fetch; no V8 held-out seed, selection, literal,
target fault, timing, comparator, dogfood, B, T, threshold change, target
semantic change, V7 retry, or BEAM-superiority claim.

### Acceptance criteria

- No production materialization behavior depends on source-text substitution.
- Every semantics-bearing input is an explicit path plus expected digest.
- All 17 eligible candidates construct and validate before selection.
- Two clean development materializations are byte-identical.
- The complete intended qualification/execution stack passes against the
  development outputs before any future-beacon commitment.
- Mutation tests show that every wrong version/path/hash/count fails before
  selection or output writes.
- A clean checkout can reproduce the report with one documented command.
- Oracle review finds no post-selection repair seam or hidden dependency on an
  exposed beacon.

### Verification

Focused constructor/materializer/fail-closed tests; two absent-output
development runs; JSON/schema/hash/link/preserved-artifact audits;
`mix format --check-formatted`; `mix compile --warnings-as-errors`; full
`mix test`; clean pushed Git.

### Result

Implemented and pushed in
[`35be301`](https://github.com/robertguss/elixir-harness/commit/35be3015c56a01350bcb08ba6dde464fda3be3bf).

- The explicit materializer constructed all 20 candidates and validated the 17
  eligible candidates before selection. Two clean materializations produced the
  same five-file bundle byte-for-byte.
- The frozen development qualification selected 12 tasks and 20 rows, then ran
  72 fault and 72 no-fault qualifications with 288 checkpoint events. Scoring
  and replay both returned `Pass`, with zero harness errors and zero safety
  disqualifiers.
- The exact materialize, qualify, and replay CLI paths were exercised. Every
  command rematerializes and byte-compares the full bundle; execution is
  confirmatory-only and guarded by an exclusive, fsynced global claim keyed by
  the verified receipt digest. Authorization probes accepted only the correct
  manifest/task/row binding and did not execute held-out faults.
- Evidence:
  [`003-effect-receipt-v8-pre-beacon-qualification.json`](experiments/003-effect-receipt-v8-pre-beacon-qualification.json)
  (`ce31ac3a940fca7e14c1722c4a4a4c3c8e9813cc78fba856d59e3f920bfb309f`),
  development protocol
  (`db67d7e876ceeb0a58ca7f03cb372eda91ccd670400e2b1feb9e73158a061e4a`), and
  development beacon
  (`dd88b7282d1fdb42d29ed1c9624f46a185193b908cd55764d538c1c70e0ac285`).
- Verification passed: exact clean-checkout preflight reproduction,
  `mix format --check-formatted`, `mix compile --warnings-as-errors`, and full
  `mix test` with 429 passing tests. The expected `CrashTool`
  `RuntimeError: boom` recovery log remained non-failing. All V1–V7 evidence
  artifacts stayed byte-identical.
- Independent Oracle review initially found source substitution, caller-bound
  bundle identity, incomplete CLI proof, and execution-claim gaps. The final
  review returned **GO** after explicit construction, pre-beacon shape
  validation, exact CLI coverage, full byte rebinding, and the global one-shot
  claim were added.
- Deviations: none. The implementation validates all 20 candidates rather than
  only the 17 eligible candidates required by acceptance.
- Remaining uncertainty: the development entropy proves command-stack coherence
  only. Selecting and committing a genuinely future drand round, including
  official response/signature verification, belongs to ER3-V8-2; no V8 held-out
  selection or confirmatory evidence has been exposed.

## ER3-V8-2 — Freeze the protocol and future beacon

**Status:** DONE

### Outcome

Freeze a self-contained V8 protocol only after ER3-V8-1 is pushed, pinning every
source in the exact materialization, qualification, execution, and replay stack
plus a drand round whose nominal time is after the protocol commit.

### Contract

Carry forward the conditional 17-candidate estimand, exact bilateral exclusions,
sampling probabilities, F1–F4 schedules, 54 evidence fields, B/T formulas,
Stop-first precedence, strict Narrow scopes, Lemon insufficiency, dogfood rules,
and all causal/postcondition distinctions. Pin the exact V8 materializer and its
pre-beacon qualification report. Also pin the command, adapter, provider, target
runner, one-shot barriers, classifier, checkpoint logic, scorer, replay logic,
schemas, and expected source hashes. Freeze relays, client, chain/public key,
round, domain separator, seed/token derivation, no-substitution/no-retry rules,
and the rule that any post-exposure change requires V9 plus fresh future
randomness.

### Non-goals

No beacon fetch, materialization, target/timing/comparator/dogfood run, B, or T.

### Acceptance and verification

The protocol is machine-readable and self-contained; its future time is after
the pushed protocol commit; all V1–V7 hashes remain stable; independent round,
time, source, probability, schema, JSON, link, format, compile, and full-suite
checks pass without fetching the round.

### Result

Implemented and pushed in
[`d53e2fa`](https://github.com/robertguss/elixir-harness/commit/d53e2fab1da245337a5729f4885386c7b6ce1905).

- The self-contained machine protocol is
  [`003-effect-receipt-v8-protocol.json`](experiments/003-effect-receipt-v8-protocol.json)
  (`3644b5a3c07663fe7be9f67a710689ce5df43eb4eceb306f2a5f76d8eb26949a`). Its
  semantic projection is independently reproduced by the Node and Elixir
  boundaries as
  `03b64a144c6de26adea8a9bf0258a6d47537849e6551e665e4302d27971717db`.
- The protocol commits drand default-mainnet round `6430646`, nominal Unix
  `1788350400` (2026-09-02T12:00:00Z), over two pinned chain-qualified relays.
  The protocol commit was pushed at 2026-09-02T05:58:54Z, before nominal time.
- The pinned verifier checks an integrity-locked `drand-client@1.4.2` runtime
  closure, both exact chain responses, relay equality, and the BLS signature.
  Its account-home one-shot claim is exclusively created and durably synced
  before protocol, dependency, output-argument, or output-state validation.
- Initial materialization requires the exact canonical beacon root and actual
  permanent claim. A separate `verify-copy` mode can revalidate copied bundles
  for internal byte-for-byte rematerialization but cannot authorize initial
  materialization.
- Fixed development entropy requalified the final cryptographic boundary: 20
  candidates, 12 selected tasks, 20 rows, 72 fault runs, 72 no-fault runs, 288
  checkpoints, and `Pass` score/replay. The report is
  [`003-effect-receipt-v8-boundary-qualification.json`](experiments/003-effect-receipt-v8-boundary-qualification.json)
  (`64ba184e231058b875497b9ad21a31372325954aaa59996031d9a42407657327`).
- Verification passed: `npm ci --ignore-scripts`, Node syntax, JSON parsing,
  `mix format --check-formatted`, `mix compile --warnings-as-errors`, focused V8
  tests (27 passed), and full `mix test` (442 passed). The expected `CrashTool`
  `RuntimeError: boom` recovery log remained non-failing.
- Oracle first found caller-controlled claim placement, pre-claim validation,
  incomplete durable ancestry, and alternate/unclaimed initial authority. After
  remediation, its focused invariant trace returned **GO** with no blocking
  bypass.
- Deviations: none. No V8 beacon, selection, held-out literal, target fault or
  timing, comparator, dogfood, `B`, or `T` evidence was fetched or generated.
- Remaining uncertainty: the real dual-relay one-shot acquisition and
  confirmatory materialization have not run. ER3-V8-3 remains blocked until the
  committed nominal time; any acquisition or frozen-identity failure will
  invalidate V8 without retry.

## ER3-V8-3 — Fetch and materialize fresh inputs

**Status:** BLOCKED until its committed future time

### Outcome

Use the already-frozen command exactly once to verify the committed beacon and
materialize the fresh V8 corpus.

### Contract

Before reading the beacon, verify every frozen source/report/protocol hash and a
clean synchronized commit. Fetch only the committed round from both pinned
relays, require field equality and official-client verification, then run the
frozen materializer without editing code. Reproduce outputs twice from absent
paths and require byte identity. Any failure invalidates V8; do not repair or
retry under the exposed beacon.

### Non-goals

No implementation change, alternate round, replacement, target/timing fault run,
comparator run, dogfood run, B, T, or confirmatory execution claim.

### Result

Blocked.

## ER3-V8-4 — Run qualification through the frozen command stack

**Status:** BLOCKED by ER3-V8-3

### Outcome

Run the fresh V8 manifest through the exact command, adapter, provider, target
runner, barriers, classifier, checkpoint, scorer, and replay sources already
frozen by ER3-V8-2. This is run-only qualification: no source, schema, command,
or expected-result change is allowed after beacon exposure.

### Acceptance criteria

Qualification is exactly `valid=true,status=Pass`; every fault/no-fault record,
P06 continuation/cardinality fact, S04 alias/causality fact, source identity,
checkpoint, cleanup, and replay matches. Dirty, interrupted, malformed,
duplicate, drifted, and non-Pass cases fail closed. Any non-Pass result
invalidates V8 and requires V9; it cannot be repaired or retried. At this stage
the V8 beacon, selection, and held-out literals are exposed, while target fault
runs, target timing runs, comparator runs, dogfood runs, B, and T remain zero.

### Result

Blocked.

## ER3-V8-5 — Execute the sole internal comparison

**Status:** BLOCKED by ER3-V8-4

### Outcome

Invoke the immutable V8 baseline-versus-receipts comparison once from absent
state, preserve every raw/checkpoint/report record, and independently replay the
score.

### Contract

No code, input, adapter, schedule, threshold, scorer, target, comparator, or
dogfood change/run. Stop on first failure. Complete evidence reports safety,
B/T, condition-specific causal convergence, correctness, continuation,
target/task cardinality, workspace aliases, timing, CPU, and storage. Missing or
inconsistent evidence is invalid and never retried or scored over a smaller
denominator.

### Result

Blocked.

## ER3-V8-6 — Dogfood or required non-execution

**Status:** BLOCKED by ER3-V8-5

Run the frozen disposable-workspace dogfood plan only when a complete valid
internal report authorizes it. Otherwise run nothing and record exact
non-authorization. Never calculate metrics over an empty denominator or write to
shared workspaces, branches, pull requests, or external systems.

### Result

Blocked.

## ER3-V8-7 — Gate 3 thesis decision

**Status:** BLOCKED by ER3-V8-5 and ER3-V8-6

Apply validity and safety first, then full-scope thresholds, strict predeclared
Narrow scopes, eligible Pivot contradictions, and otherwise Stop. Missing or
invalid internal evidence yields **No decision**, not a thesis Stop. Recompute
every applicable formula independently and separate internal, external, dogfood,
causal-completion, and postcondition evidence. Make no BEAM-superiority claim.

### Result

Blocked.

## Later research horizons

These remain hypotheses, not active work. Gate 3 may reorder, narrow, replace,
or remove them.

1. **Proof Lease:** invalidate evidence causally when assumptions change.
2. **Context Capsule:** make provenance, authority, contamination, and least
   context explicit.
3. **Workspace Cell Contract:** run one mission across local and remote
   executors with observable ownership and fencing.
4. **Constitutional Controller:** observation → contradiction → mission →
   evidence → satisfaction or amendment proposal.
5. **BEAM-specific comparative experiments:** only after defining a distinct,
   falsifiable claim that cannot be inferred from runtime-neutral durable
   receipts alone.
