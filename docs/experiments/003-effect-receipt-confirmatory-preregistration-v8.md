# EXP-003: durable-effects confirmatory preregistration v8

> - **Preregistration version:** ER-3/FND-2-v8
> - **Exposure boundary:** frozen after explicit development qualification and
>   before any V8 beacon fetch, held-out selection/literal, target fault/timing,
>   comparator, dogfood, `B`, or `T` output
> - **Frozen against pushed Elara:** `f4503a92a9f400ee8cb39960d53c939d2df7b932`
> - **Pinned targets:** baseline `23e603550253c69846795b13cc2f2670f1122e21`;
>   receipts `9ff416f2c22327c5ef38edcd52a9e89108fbc726`
> - **Committed future beacon:** drand default-mainnet round `6430646`,
>   nominally 2026-09-02T12:00:00Z
> - **Machine contract:**
>   [`003-effect-receipt-v8-protocol.json`](003-effect-receipt-v8-protocol.json)
>   (`3644b5a3c07663fe7be9f67a710689ce5df43eb4eceb306f2a5f76d8eb26949a`)
> - **Pre-beacon qualification:**
>   [`003-effect-receipt-v8-pre-beacon-qualification.json`](003-effect-receipt-v8-pre-beacon-qualification.json)
> - **Cryptographic-boundary requalification:**
>   [`003-effect-receipt-v8-boundary-qualification.json`](003-effect-receipt-v8-boundary-qualification.json)
> - **Canonical status:** [`../roadmap.md`](../roadmap.md)

V8 is a fresh protocol. V1–V7 and their failures remain immutable. V8 tests a
runtime-neutral durable-effects protocol implemented compatibly with BEAM
ownership; it does not test or support BEAM superiority.

## Why V7 stopped and what V8 changes

V7 fetched and verified its committed beacon, but its materializer stopped at
the first source-identity guard before deriving a seed, selecting candidates,
generating held-out literals, or writing outputs. The wrapper had accidentally
retained V6's preflight path. Changing it after seeing the beacon would have
violated the frozen source boundary, so V7 was preserved and never retried.

ER3-V8-1 replaced the textual-transform wrapper with an explicit materializer.
Before this future beacon was selected, fixed non-confirmatory development
entropy proved:

- explicit construction and structural validation of all 20 candidates before
  sampling, including all 17 eligible candidates;
- two byte-identical five-file materializations;
- exact materialize, qualify, and replay CLI paths;
- 72 fault and 72 no-fault qualification runs, 288 checkpoints, and identical
  `Pass` score/replay results;
- complete bundle rematerialization and byte rebinding on every command;
- task/row/digest authorization rejection without held-out execution; and
- an exclusive fsynced global execution claim keyed by receipt digest.

The pushed implementation is
[`35be301`](https://github.com/robertguss/elixir-harness/commit/35be3015c56a01350bcb08ba6dde464fda3be3bf).
The report SHA-256 is
`ce31ac3a940fca7e14c1722c4a4a4c3c8e9813cc78fba856d59e3f920bfb309f`. Its final
independent Oracle review returned **GO**. Development output is stack-coherence
evidence only and contributes no V8 result.

## Frozen frame, sampling, and evidence

Eligibility `E=1` means both pinned conditions passed the frozen no-fault
outcome, workspace, provider-consumption, identity, and cardinality contract
without an adapter semantic shim. The conditional frame is exactly:

```text
P01 P02 P04 P06 P07 P08
S01 S02 S03 S04
W01 W02 W03 W05 W06 W07 W08
```

P03, P05, and W04 remain bilaterally excluded for their frozen idempotent or
conflict-semantic mismatch. V8 makes no inference to those candidates or to the
original 20-candidate population.

Candidate order keys are lowercase `SHA-256(seed || NUL || candidate_id)`.
Within write and patch, select the lowest key in each primary F1–F4 stratum;
include S01–S04; then sort all 12 by key. Every task contributes its primary row
and the eight lowest-key tasks also contribute secondary rows, yielding exactly
20 locked rows. Exact conditional task and secondary-row probabilities are
frozen per candidate in the machine contract and sum to 12 and eight
respectively. There is no skip-and-redraw, substitution, denominator reduction,
or favorable-row selection.

All 54 evidence fields are mandatory. Records distinguish controller and
executor facts, workspace aliases, historical execution knowledge, causal
terminal evidence, safe next action, target/task cardinality, callback attempts,
external mutation count, interventions, timing, CPU, storage, and raw artifact
digests. Workspace bytes can establish a current postcondition but never causal
job completion.

## Frozen fault, provider, and scoring contract

- **F1:** controller loss after admission and before dispatch; zero mutation;
  pre-effect workspace.
- **F2:** executor loss after acceptance and before callback; zero mutation;
  pre-effect workspace.
- **F3:** executor loss after one target mutation and before terminal delivery;
  target-postcondition workspace.
- **F4:** controller loss after terminal delivery and before controller
  persistence; task-defined mutation count and task-specific complete/partial
  workspace.

F1–F3 expect no surviving causal terminal proof. F4 expects none for baseline
and requires an atomic job-ID/digest-bound receipt for receipts. Baseline
receipt seams remain N/A rather than fabricated.

Every plan step maps bijectively to one provider tool call and exactly one
one-shot fault target. P06's continuation and task/target cardinality branches,
S04's alias/causality distinction, halt text, workspace aliases, and
condition-specific convergence are frozen verbatim in the machine contract.
Fault condition order is
`baseline, receipts, receipts, baseline, baseline, receipts`, with three
repetitions per condition from fresh fixtures. Timing uses two warmups and ten
measured runs per task and condition.

`B` and `T` count bad baseline and receipts rows over all 20 locked rows, where
bad is automatic safe indeterminate, manual recovery, or ambiguous no safe
action. Material improvement requires all of:

```text
B >= 2
B - T >= 2
2 * (B - T) >= B
```

Passage also requires zero safety disqualifiers, 100% correct no-fault
workspaces, complete bounded knowledge/safe-action convergence, causal terminal
convergence where required, median receipts/baseline timing ratio at most 1.20,
and no per-task ratio above 2.0. Safety is Stop-first. Narrow scopes are tried
in fixed order write+patch, write, patch and must independently satisfy all
frozen minimums and thresholds. The only eligible Pivots remain
`sidecar_ownership`, `causal_persistence_boundary`, and
`safe_action_presentation`.

Lemon remains pinned at `b9ed0660e0d7fe61f38156f0aeb65e839b4e7f39`. It supplies
zero equivalent recovery rows, below the three-row/two-fault-type floor, so
external fault execution remains forbidden and the expected valid outcome is
**Insufficient comparability**. Dogfood remains D01–D12 in seed-derived order,
with ten injected tasks, two controls, at least five failure types, no
replacement, and exact `D`, `G`, `I`, `U`, and `A` thresholds frozen in the
machine contract.

## Frozen command and source boundary

The only commands are:

```text
node priv/benchmark/exp003-v8-beacon/fetch-and-verify.cjs \
  fetch <protocol.json> <protocol-sha256>

node priv/benchmark/exp003-v8-beacon/fetch-and-verify.cjs \
  verify <protocol.json> <protocol-sha256> \
  <beacon-bundle-root> <verification-sha256>

node priv/benchmark/exp003-v8-beacon/fetch-and-verify.cjs \
  verify-copy <protocol.json> <protocol-sha256> \
  <copied-beacon-bundle-root> <verification-sha256>

mix run priv/benchmark/materialize_exp003_v8.exs -- \
  <protocol> <protocol-sha256> <beacon-bundle-root> \
  <verification-sha256> <absent-output-root>

mix run priv/benchmark/run_exp003_v8.exs -- qualify \
  <protocol> <protocol-sha256> <receipt> <receipt-sha256> \
  <state-root> <workspace-root> <output.json>

mix run priv/benchmark/run_exp003_v8.exs -- execute \
  <protocol> <protocol-sha256> <receipt> <receipt-sha256> \
  <qualification.json> <state-root> <workspace-root> <output.json>

mix run priv/benchmark/run_exp003_v8.exs -- replay \
  <protocol> <protocol-sha256> <receipt> <receipt-sha256> \
  <report.json> <score-output.json>
```

The protocol pins every materializer, command, adapter, provider, target runner,
barrier, classifier, checkpoint, scorer, replay, schema, target commit, semantic
input, verifier, package-lock, and loaded-runtime-closure identity. Every
command rematerializes and byte-compares the complete bundle. Qualification must
replay as exactly `valid=true,status=Pass`; execute is confirmatory-only and
globally one-shot. Any mismatch or unmatched checkpoint stops the attempt
without retry, resume, repair, replacement, or denominator reduction.

## Future beacon, verification, and seed

V8 commits League of Entropy drand default mainnet:

- chain hash `8990e7a9aaed2ffed73dbd7092123d6f289930540d7651336225dc172e51b2ce`;
- public key
  `868f005eb8e6e4ca0a47c8a77ceaa5309a47978a7c71bc5cce96366b5d7a569937c529eeda66c7293784a9402801af31`;
- `pedersen-bls-chained`, genesis `1595431050`, period 30 seconds;
- round `6430646`, nominal Unix time `1788350400`, 2026-09-02T12:00:00Z; and
- exact path
  `/8990e7a9aaed2ffed73dbd7092123d6f289930540d7651336225dc172e51b2ce/public/6430646`
  on `api.drand.sh` and `drand.cloudflare.com`.

The arithmetic is exact:

```text
1595431050 + (6430646 - 1) * 30 = 1788350400
```

The frozen verifier uses only Node built-ins until it has checked its source,
package, lock, and deterministic runtime-closure manifest. It then loads the
single bundled `drand-client@1.4.2` CJS file by absolute path after checking its
hash, size, package identity, and built-in-only require closure. `NODE_OPTIONS`
and `NODE_PATH` are rejected. A fresh `npm ci --ignore-scripts` must reproduce
that closure.

For acquisition, the verifier creates independent client/chain instances for
both relays, uses `fetchBeacon` with verification enabled, pins both `chainHash`
and `publicKey`, and validates the exact public key, chain/group hashes, scheme,
genesis, period, and beacon ID returned by `/info`. Relay paths include the
chain hash. Redirects and origin/path changes are rejected. Both responses must
have equal round, randomness, signature, and previous signature.

The verifier first rejects `NODE_OPTIONS`/`NODE_PATH` as a runtime trust
precondition, then applies its compiled nominal-time check. Before reading the
protocol, runtime closure, extra output arguments, or output state, it
exclusively creates the permanent global claim
`~/.elara/benchmark/exp003/v8/beacon-fetch.claim.json`. The leading `~` is the
OS account home from `os.userInfo()`, never caller-controlled `HOME`; every
newly created ancestor, the claim, and their parent directories are fsynced. The
claim is never removed on success or failure, the output root is fixed at
`test/fixtures/benchmark/exp003-v8-beacon`, and no alternate output argument is
accepted. Files and directories are fsynced around atomic rename. A failed or
concurrent call therefore consumes the sole attempt and cannot retry under a
cleaner dependency state or another root.

The semantic protocol projection has commitment
`03b64a144c6de26adea8a9bf0258a6d47537849e6551e665e4302d27971717db`, compiled
into both the verifier and Elixir materializer. The materializer accepts the
complete four-file canonical bundle, not a caller-digested `verified.json`, and
requires its actual permanent claim to bind the protocol digest and claim digest
before initial materialization. `verify-copy` is a separate internal
rematerialization path: it rechecks the full copied bundle and signature but can
never authorize initial materialization. Forged randomness, an alternate or
unclaimed initial bundle, a modified protocol with a matching caller digest, a
changed loaded client file, a preloaded Node environment, or any relay/receipt
mismatch fail closed. Fixed development entropy was rerun through the changed
boundary: 20 candidates, 12 tasks, 20 rows, 72 fault runs, 72 no-fault runs, 288
checkpoints, and `Pass` score/replay.

The client's signature path is documented in the tagged upstream
[`fetchBeacon`](https://github.com/drand/drand-client/blob/v1.4.2/lib/index.ts#L69-L81)
and
[`verifyBeacon`](https://github.com/drand/drand-client/blob/v1.4.2/lib/beacon-verification.ts#L22-L40)
sources; the pinned default-mainnet constants are in
[`defaults.ts`](https://github.com/drand/drand-client/blob/v1.4.2/lib/defaults.ts#L5-L17).

ER3-V8-3 must not invoke the verifier before nominal time. At or after that time
it invokes the fetch command exactly once; that command owns the canonical
absent output path. Early availability, relay disagreement, unavailability,
verification failure, dirty output, or any source/protocol mismatch invalidates
V8 and never authorizes an alternate round or retry.

Seed derivation is exactly:

```text
SHA-256(
  "elara:exp-003:er3:fnd-2:v8\0" ||
  chain_hash || ":" || "6430646" || ":" || randomness_hex || ":" ||
  "f4503a92a9f400ee8cb39960d53c939d2df7b932"
)
```

Generated tokens are the first 16 lowercase hex characters of
`SHA-256(seed || NUL || id || NUL || field)`. No predecessor round, seed,
selection, literal, or output can authorize V8.

## Order, exposure, and invalidation

The only valid order is ER3-V8-1 explicit pre-beacon qualification → ER3-V8-2
protocol/future-beacon freeze → ER3-V8-3 one-shot fetch/materialization →
ER3-V8-4 immutable qualification → ER3-V8-5 sole internal execution → ER3-V8-6
dogfood/non-execution → ER3-V8-7 Gate 3.

At this freeze, only the future round is committed. It has not been fetched.
Selection, held-out literals, target faults/timing, comparator faults, dogfood,
`B`, and `T` remain zero. Any factual change after this freeze requires V9 and
genuinely future randomness. Exposed evidence is never retried, pooled,
repaired, resumed, or relabeled.

## Frozen limitations

- The estimand is conditional on 17 command-path-eligible candidates.
- Synthetic tasks test harness recovery, not general coding-agent quality.
- Workspace postconditions do not prove causal completion.
- External recovery comparability is insufficient.
- CPU and storage are descriptive.
- This is not a BEAM-superiority experiment.
