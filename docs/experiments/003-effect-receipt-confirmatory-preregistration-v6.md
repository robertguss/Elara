# EXP-003: durable-effects confirmatory preregistration v6

> - **Preregistration version:** ER-3/FND-2-v6
> - **Exposure boundary:** frozen before any V6 beacon fetch, selection, target,
>   comparator, dogfood, timing, `B`, or `T` output
> - **Frozen against Elara:** `ed9a2dbbdd2ba9ab743a9dc95d1f0ba08663891c`
> - **Pinned baseline target:** `23e603550253c69846795b13cc2f2670f1122e21`
> - **Pinned receipts target:** `9ff416f2c22327c5ef38edcd52a9e89108fbc726`
> - **Pinned comparator:** Lemon `b9ed0660e0d7fe61f38156f0aeb65e839b4e7f39`
> - **Committed future beacon:** drand mainnet round `6429026`, nominally
>   2026-09-01T22:30:00Z
> - **Machine contract:**
>   [`003-effect-receipt-v6-compatibility.json`](003-effect-receipt-v6-compatibility.json)
> - **Pre-seed proof:**
>   [`003-effect-receipt-v6-preflight.json`](003-effect-receipt-v6-preflight.json)
> - **Canonical issue:**
>   [ROB-867](https://linear.app/robert-guss/issue/ROB-867/er3-v6-fnd-freeze-the-fresh-protocol-and-future-beacon)

V6 is the only protocol authorized for a future EXP-003 confirmatory attempt.
V1–V5 and all their evidence remain immutable. The hypothesis is runtime-neutral
durable-effect reconciliation implemented compatibly with BEAM process
ownership. This experiment does not test or support BEAM superiority.

## Why V5 stopped and why V6 is valid

V5 fetched and verified its committed beacon, which selected P02 first. Its
frozen materializer then failed before writing any corpus output because it had
constructors for only 19 of the 20 preregistered candidates. Adding P02 after
seeing its selection would have been selection-conditioned, so V5 stopped
without retry. It produced zero held-out target, timing, comparator, dogfood,
`B`, or `T` output.

ROB-866 repaired the ordering rather than the observed selection. Before this
future V6 beacon was chosen, it added deterministic P02 construction and ran a
seed-independent preflight over every candidate and both fault assignments. The
canonical report proves 20/20 byte construction and 40/40 executable semantic
validation, including P02's unique exact CRLF edit and unchanged surrounding
bytes. Its identities are:

| Artifact             | SHA-256                                                            |
| -------------------- | ------------------------------------------------------------------ |
| preflight report     | `8f69b8d15b2c7bb3ee782c87b778b0b32e536be1a548c207e7cd7664dd8b0216` |
| preflight source     | `48f36d9047138546e962ad636f18c8d936b0aa9cea8402ddff18ccdf6bb35121` |
| frozen parent commit | `ed9a2dbbdd2ba9ab743a9dc95d1f0ba08663891c`                         |

The preflight used a non-beacon domain, performed no sampling or selection, and
generated no held-out V6 literals. ROB-868 must rerun this exact preflight and
verify both hashes before reading the committed beacon.

## Frozen corpus and schedules

The complete frame remains P01–P08, S01–S04, and W01–W08 with the exact briefs,
classes, primary/secondary assignments, mutation counts, continuation rules,
workspace overrides, and condition-specific causal-terminal maps in the machine
contract. There is no candidate addition, removal, assignment correction,
threshold change, or scope change from V5.

Universal selection is frozen:

1. order every candidate by `SHA-256(seed || NUL || candidate_id)`;
2. select the lowest-key write and patch candidate for each primary F1–F4;
3. include S01–S04; and
4. sort the resulting 12 tasks by order key.

Every selected task contributes its primary row. The eight lowest-key selected
tasks also contribute their secondary row, producing exactly 20 scored rows. No
result may add, remove, substitute, or reorder a task or row.

The fault schedules remain:

- **F1:** controller loss after admitted durable request evidence and before
  executor dispatch; zero job mutation; pre-effect workspace;
- **F2:** executor loss after acceptance and before callback/mutation; zero job
  mutation; pre-effect workspace;
- **F3:** executor loss after exactly one target mutation and before terminal
  delivery; target-postcondition workspace; and
- **F4:** controller loss after terminal delivery and before session
  persistence; task-defined mutation count; complete-task workspace.

F1–F3 expect no surviving causal terminal proof in either condition. F4 expects
none for baseline and an atomic job-ID/digest-bound causal receipt for receipts.
Baseline-only durable seams remain N/A; they are never fabricated.

Each fault row runs in fixed order
`baseline, receipts, receipts, baseline, baseline, receipts`, yielding three
repetitions per condition from fresh fixtures. No-fault timing uses two warmups
and 10 measured repetitions per task and condition. Any missing, inconsistent,
late, duplicate, dirty, or malformed evidence invalidates the run; it never
shrinks a denominator or authorizes a replacement.

## Frozen scoring and gate rules

`primary_recovery_class` remains one of automatic terminal, automatic known
nonterminal, automatic safe indeterminate, manual recovery, ambiguous no safe
action, safety disqualifier, harness failure, or pre-exposure non-comparable.
Define `bad` as automatic safe indeterminate, manual recovery, or ambiguous no
safe action. `B` and `T` are bad-row counts for baseline and receipts over all
20 locked internal rows.

Material improvement requires all three exact tests:

```text
B >= 2
B - T >= 2
2 * (B - T) >= B
```

Passage additionally requires zero safety disqualifiers, 100% correct no-fault
workspaces, correct bounded knowledge/safe-action convergence for every row,
causal terminal convergence for every applicable row, corpus median target /
baseline timing ratio at most 1.20, and no row ratio above 2.0. CPU and storage
remain descriptive. Safety is Stop-first; duplicate or corrupt mutation, false
terminal claims, unsafe executor failover, unprotected callback retry, hidden
substitution, and post-exposure tuning are disqualifiers.

Only strict operation-class Narrow scopes remain eligible, in order: N1
write+patch, N2 write, N3 patch. A candidate needs at least four tasks, six
rows, `B >= 2`, at least eight mapped dogfood tasks, and independent passage of
every applicable threshold. Otherwise the deterministic GATE-3 order is Stop on
invalidity/safety, Continue on full passage, first passing Narrow, one of the
three already-frozen Pivots (`sidecar_ownership`, `causal_persistence_boundary`,
`safe_action_presentation`), then Stop.

Dogfood retains the 12 historical D01–D12 tasks, seed-derived order, 10 injected
failures, two controls, at least five failure types, and exact gates:

```text
D >= 8
G == I
5 * U >= 4 * D
A == 0
no safety disqualifier
```

The Lemon pin and suitability finding are unchanged. No-fault equivalence is
required for every included class, while external recovery evidence requires at
least three equivalent rows across two fault types. The frozen source supplies
zero semantically equivalent durable-recovery rows, so the expected valid
external result remains **Insufficient comparability**, with no external fault
execution and no comparative claim.

## Command and qualification boundary

The sole authorized entrypoint remains
`priv/benchmark/run_internal_confirmatory.exs` with exact modes:

```text
qualify <v6-manifest> <state-root> <workspace-root> <output.json>
execute <v6-manifest> <qualification.json> <state-root> <workspace-root> <output.json>
replay <v6-manifest> <execution.json> <score-output.json>
```

ROB-869 may make only the preregistered factual command corrections inherited
from V5: select causal-terminal expectation by run condition, encode every
diagnostic as canonical JSON, and authorize execution only for an exact
`valid=true`, `status=Pass` replay. The same orchestration path must qualify and
execute. Qualification uses development fixtures and must complete the full
fault and timing shape before source/report hashes freeze. It produces no V6
confirmatory result.

ROB-870 is the first issue allowed to execute V6 held-out target fault or timing
runs. It starts only from absent state/workspace/checkpoint/output paths,
atomically checkpoints started/completed events, preserves raw records before
aggregates, stops on first inconsistency, never resumes an unmatched start, and
independently replays canonical scoring byte-for-byte.

## Committed future beacon and seed

Selection uses League of Entropy drand default mainnet:

- chain hash:
  `8990e7a9aaed2ffed73dbd7092123d6f289930540d7651336225dc172e51b2ce`;
- genesis Unix time: `1595431050`;
- period: 30 seconds;
- committed round: `6429026`;
- nominal Unix time: `1788301800`, 2026-09-01T22:30:00Z; and
- path: `/<chain-hash>/public/6429026` on `api.drand.sh` and
  `drand.cloudflare.com`.

The schedule is exact:

```text
1595431050 + (6429026 - 1) * 30 = 1788301800
```

ROB-868 must not fetch before nominal time. At or after it, ROB-868 fetches only
this round from both relays, requires equal round/signature/previous-signature/
randomness, and verifies both against the pinned chain and public key with
`drand-client@1.4.2`. Early availability, disagreement, unavailability, or
verification failure stops V6 and never permits another round or a retry.

Derive the V6 seed exactly as:

```text
SHA-256(
  "elara:exp-003:er3:fnd-2:v6\0" ||
  chain_hash || ":" || "6429026" || ":" || randomness_hex || ":" ||
  "ed9a2dbbdd2ba9ab743a9dc95d1f0ba08663891c"
)
```

Generated tokens remain the first 16 lowercase hex characters of
`SHA-256(seed || NUL || id || NUL || field)`. V5's round, seed, selected order,
and generated values are forbidden. V6 writes only fresh versioned paths.

## Order, exposure, and invalidation

The only valid issue order is:

```text
ROB-866 pre-seed exhaustive preflight
  -> ROB-867 amendment and future beacon
  -> ROB-868 fresh materialization
  -> ROB-869 command qualification and freeze
  -> ROB-870 immutable internal execution
  -> ROB-871 dogfood execution or required non-execution
  -> ROB-872 GATE-3
```

At this freeze every V6 exposure count is zero. Any post-freeze factual change
before result exposure still requires a new version and genuinely future round.
After any target, timing, comparator, or dogfood result, changing seed,
membership, literals, assignments, workspaces, causal semantics, target,
adapter, command, schema, schedule, scorer, denominator, threshold, comparator,
or dogfood plan invalidates V6. Exposed evidence remains development/regression
evidence only; it cannot be retried, pooled, repaired, or relabeled.
