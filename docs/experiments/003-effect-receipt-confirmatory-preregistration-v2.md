# EXP-003: durable-effects confirmatory preregistration v2

> - **Preregistration version:** ER-3/FND-2-v2
> - **Amendment freeze timestamp:** 2026-09-01T05:13:27Z
> - **Exposure boundary:** frozen before any target, comparator, or dogfood
>   fault output
> - **Frozen against Elara:** `ff15e210f8ba9d62e439f2fe03dc8eb4b02f77c2`
> - **Pinned comparator:** Lemon `b9ed0660e0d7fe61f38156f0aeb65e839b4e7f39`
> - **Committed future beacon:** drand mainnet round `6426976`, nominally
>   2026-09-01T05:25:00Z
> - **Canonical issue:**
>   [ROB-842](https://linear.app/robert-guss/issue/ROB-842/er3-v2-fnd-amend-and-freeze-the-pre-exposure-correction)

This artifact is the sole pre-exposure amendment to
[ER-3/FND-2-v1](003-effect-receipt-confirmatory-preregistration.md). V1 and all
of its artifacts and issue Results remain immutable. V2 supersedes v1 only as
the protocol for future confirmatory execution; it does not rewrite or upgrade
any v1 observation.

The hypothesis remains runtime-neutral durable-effect reconciliation implemented
compatibly with BEAM process ownership. Neither version tests or supports BEAM
superiority.

## Why v2 is required

V1 separated adapter construction from immutable execution, but its internal
construction unit froze an adapter that explicitly returned
`{:error, :fault_execution_forbidden}` for every fault context. The target
runner supported no-fault execution and passive hook observation only. The
neutral runner and scorer could describe a fault schedule, but no checked-in
path could execute one against either internal condition.

[ROB-838](https://linear.app/robert-guss/issue/ROB-838/er3-2b-execute-the-frozen-baseline-versus-receipts-comparison)
therefore terminated before its first target fault run. Adding the missing
adapter inside that immutable execution unit would have violated its explicit
prohibition on code and adapter changes. This is a preregistration/harness
capability defect, not a target safety, recovery, correctness, timing, or value
result.

V1 already requires a complete v2 amendment, a new future drand round, and fresh
inputs to correct a pre-exposure factual error. Zero exposure makes this
amendment permissible; it does not permit reuse of v1 confirmatory inputs.

## Complete exposure and disposition ledger

The counts below were frozen before the committed round's nominal time.

| Evidence category                         | V1 exposure | Disposition                                                                                    |
| ----------------------------------------- | ----------: | ---------------------------------------------------------------------------------------------- |
| Internal target fault rows                |           0 | ROB-838 Canceled: pre-target harness-capability failure                                        |
| Internal no-fault benchmark timing rows   |           0 | Not started                                                                                    |
| Internal `B`, `T`, safety, or gate result |           0 | Not calculated; internal safety remains unknown                                                |
| Lemon fault rows                          |           0 | ROB-839 Done: **Insufficient comparability**                                                   |
| Elara rows paired with Lemon              |           0 | Not started                                                                                    |
| Dogfood task runs                         |           0 | ROB-840 Canceled because neither safety-authorized nor supported by a real safety disqualifier |
| Dogfood fault runs                        |           0 | Not started                                                                                    |
| GATE-3 decisions                          |           0 | ROB-841 Canceled; no Continue, Narrow, Pivot, or Stop decision was made                        |

The v1 corpus, generated values, no-fault adapter fixtures, and dogfood plan
were exposed to adapter construction and validation. Those observations remain
development evidence. They are not v2 confirmatory inputs. The v1 Lemon source
finding may inform the version-aligned v2 attestation, but no v1 report is
silently relabeled v2.

## Normative change log

Every v1 rule remains normative unless this table changes it explicitly.

| Area                          | ER-3/FND-2-v2 rule                                                                                                                                 |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Protocol identity             | Version changes from `ER-3/FND-2-v1` to `ER-3/FND-2-v2`.                                                                                           |
| Randomness                    | Use the new future round and v2 seed derivation below.                                                                                             |
| Confirmatory corpus           | Rematerialize membership, row selection, order, generated literals, fixture commits, workspaces, ground truth, and all digests.                    |
| Adapter-equivalence fixtures  | Regenerate generated identities, values, workspace digests, report version, and checksums.                                                         |
| External evidence             | Produce a version-aligned source/capability attestation before target fault exposure; execute no external row unless the unchanged floor is met.   |
| Dogfood                       | Preserve the frozen 12-task historical frame, controls, assignments, metrics, and thresholds, but derive a new order and versioned plan/checksums. |
| Internal adapter construction | Add a separate pre-exposure qualification/freeze unit that must prove every locked schedule executable for both conditions.                        |
| Immutable internal execution  | A new issue may begin only after qualification is Done and all source, runner, schema, command, configuration, and artifact hashes are frozen.     |
| Downstream issues             | V1 ROB-838, ROB-840, and ROB-841 remain Canceled; v2 uses new issue identities and Results.                                                        |

V2 does **not** change the Universal `write` + `patch` + `shell` GATE-2 scope,
candidate task frame, declarative-write/typed-patch/opaque-shell semantics,
fault types F1–F4, externally aligned schedules, evidence fields, safety
disqualifiers, `B`/`T` formulas, convergence/correctness/timing rules, strict
Narrow order, Pivot contradictions, Stop-first precedence, Lemon pin,
comparability floor, dogfood historical frame, or dogfood thresholds. A newly
discovered impossibility in any of those rules stops v2; it does not authorize
an implicit edit.

## Committed future beacon

Selection uses the League of Entropy drand default mainnet:

- chain hash:
  `8990e7a9aaed2ffed73dbd7092123d6f289930540d7651336225dc172e51b2ce`;
- genesis time: `1595431050` Unix seconds;
- period: 30 seconds;
- committed round: `6426976`;
- nominal round time: `1788240300` Unix seconds, 2026-09-01T05:25:00Z;
- API path: `/<chain-hash>/public/6426976` on official relays.

The round follows the mainnet schedule exactly:

```text
1595431050 + (6426976 - 1) * 30 = 1788240300
```

The amendment freeze timestamp is 693 seconds before that nominal time. ROB-843
must fetch this exact round from `api.drand.sh` and `drand.cloudflare.com`,
require identical round, signature, previous-signature, and randomness values,
and verify the signature against pinned chain information using an official
drand client. It records raw responses, chain information, tool version, and
verification output. Early availability, inconsistent relays, verification
failure, or unavailable relays blocks materialization; none permits a different
round.

Derive the 32-byte v2 selection seed as:

```text
SHA-256(
  "elara:exp-003:er3:fnd-2:v2\0" ||
  chain_hash || ":" || "6426976" || ":" || randomness_hex || ":" ||
  "ff15e210f8ba9d62e439f2fe03dc8eb4b02f77c2"
)
```

Hashes are lowercase hexadecimal SHA-256 values compared lexicographically. For
task or row ID `id`, the order key remains `SHA-256(seed || "\0" || id)`. For
generated field `field` on task `id`, the token remains the first 16 lowercase
hexadecimal characters of `SHA-256(seed || "\0" || id || "\0" || field)`. No
generated value may be chosen manually.

## Fresh-input contract

ROB-843 applies the unchanged v1 candidate frame and Universal selection rules
to the v2 seed. It creates new v2 paths or filenames and must not overwrite v1
artifacts. Its deterministic output includes:

1. the verified beacon record and replay script;
2. the selected task and fault-row order;
3. every generated identifier, literal, path, preimage, postimage, and opaque
   sentinel;
4. fresh initial workspaces, fixture commits, scripted plans, ground-truth
   counters, expected no-fault outcomes, and workspace digests;
5. a v2 manifest containing all schema, target, runner, scorer, adapter,
   schedule, evidence, threshold, and checksum identities;
6. regenerated no-fault adapter-equivalence fixtures;
7. a version-aligned Lemon capability and comparability-floor attestation; and
8. a v2 dogfood plan with the same historical frame and frozen assignments but
   new seed-derived order, version, and checksums.

The v1 floor still requires no-fault equivalence for every included operation
class and at least three equivalent fault rows across two fault types. If
unchanged pinned Lemon source still supplies zero semantically equivalent
recovery rows, the only valid v2 external result remains **Insufficient
comparability**, with zero Lemon or target fault execution and no comparative
claim. A source, comparator, scope, or adapter-semantics change requires a
separate reviewed issue before v2 can continue.

## Internal adapter qualification boundary

ROB-844 is construction and qualification, never confirmatory execution. It may
use exposed development fixtures and new non-confirmatory qualification
fixtures. It must establish that the checked-in adapter and command can:

- run both `baseline` and `receipts` conditions;
- execute every locked F1–F4 schedule and barrier in the fixed repetition order;
- apply declared process loss, restart, reopening, reconciliation, and bounded
  convergence mechanics without adding recovery semantics to either target;
- start every repetition from a fresh exact fixture and isolated storage;
- collect every frozen controller, executor, workspace, historical-execution,
  session, safe-action, convergence, correctness, and timing field;
- reject missing, duplicate, unexpected, or late hooks, dirty resets, leaked
  processes, inconsistent repeats, and incomplete evidence as harness failure;
  and
- preserve no-fault semantic equivalence for every included operation class.

Before ROB-844 is Done, the v2 adapter, target runner, neutral runner, scorer,
report schema, command, target commits, runtime configuration, and all support
files receive immutable hashes. V2 confirmatory fixtures may be validated and
mapped, but no target fault output may be produced. An adapter cannot receive a
qualifying classification by exercising a v2 confirmatory fault row.

## Execution chain and stopping rules

The sole allowed order is:

```text
ROB-842 amendment
  -> ROB-843 rematerialization
  -> ROB-844 adapter qualification/freeze
  -> ROB-845 immutable internal execution
  -> ROB-846 dogfood execution or real safety-blocked result
  -> ROB-847 GATE-3
```

ROB-845 is the first unit permitted to produce v2 target fault output. It may
not change code, adapters, inputs, schedules, schemas, thresholds, or target
semantics. Missing or inconsistent evidence invalidates the run; it never
shrinks a denominator.

ROB-846 may execute real tasks only when ROB-845 supplies a complete internal
report without a safety disqualifier. It may emit safety-blocked non-execution
only when that report names a real nonempty safety disqualifier. Missing or
invalid internal evidence authorizes neither path.

ROB-847 requires complete applicable v2 internal, external-coverage, and dogfood
records. It applies the inherited Stop-first precedence and makes no
partial-evidence decision.

## Exposure, amendment, and invalidation rules

Target fault output, external fault output, and dogfood fault output remain
relevant result exposure. No v2 construction unit may produce one.

After any relevant v2 output, a change to seed, membership, generated values,
operation scope, row schedule, target semantics, adapter semantics, rubric,
denominator, threshold, comparator, eligibility, scorer, report schema, or
dogfood plan invalidates v2. Exposed output remains development/regression
evidence only. A later confirmatory attempt requires another explicit version, a
genuinely future round, fresh materialized inputs, and new issue identities.

Environment loss, impossible fixtures, adapter failure, missing data, and
inconsistent repetitions are retained as invalidating harness evidence. No task
or row may be replaced, excluded, or reclassified because it is slow,
unfavorable, unavailable, or unrecoverable.

## Verification required at completion

ROB-842 records:

```bash
date -u '+%Y-%m-%dT%H:%M:%SZ %s'
git rev-parse HEAD origin/main
git status --short
git diff --check
mix format --check-formatted
mix compile --warnings-as-errors
mix test --seed 0
```

It independently checks the round arithmetic, proves the amendment commit
predates 2026-09-01T05:25:00Z, records this document's SHA-256/blob identity,
pushes the immutable amendment, and verifies exactly one next executable Linear
Todo.
