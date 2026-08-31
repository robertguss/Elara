# EXP-003: durable-effects confirmatory preregistration

> - **Preregistration version:** ER-3/FND-2-v1
> - **Exposure boundary:** frozen before ROB-668 or any later target
>   implementation began
> - **Frozen against Elara:** `93e91662ed9c7c7d9632c66ecce6a87e1a02d063`
> - **Pinned comparator:** Lemon `b9ed0660e0d7fe61f38156f0aeb65e839b4e7f39`
> - **Canonical issue:**
>   [ROB-772](https://linear.app/robert-guss/issue/ROB-772/fnd-2-preregister-evidence-thresholds-and-comparator-suitability)
> - **Exposure timestamp:** 2026-08-31T17:34:12Z

This document preregisters the confirmatory evidence design for EXP-003 before
durable-effect implementation. It fixes the task frame, selection mechanism,
fault-row construction, exposure labels, metrics, thresholds, eligible Narrow
scopes, dogfood frame, comparator evidence, and amendment rules. Later issues
materialize and execute these rules; they do not choose them again after seeing
target results.

The hypothesis is runtime-neutral durable-effect reconciliation implemented
compatibly with BEAM process ownership. This protocol is not evidence that BEAM
is superior to other runtimes.

## Exposure ledger

At this freeze:

- ROB-667 is Done and contributed only the evidence contract in
  [`003-effect-receipt-er1-contract.md`](003-effect-receipt-er1-contract.md).
- ROB-668 and every target implementation, target fault matrix, benchmark
  adapter, and dogfood run are unstarted.
- Existing Elara tests, repository history, the ROB-667 marker design, the task
  templates below, and Lemon source are **exposed development material**.
- Concrete corpus membership within each stratum, generated identifiers and
  payloads, row order, and dogfood order remain unknown until the future public
  randomness round defined below.
- Materialized fixtures become **held-out confirmatory inputs** only relative to
  target protocol implementation. They are exposed to later runner/adapter
  construction and are never described as unseen model-evaluation tasks.
- A case inspected while implementing ROB-668 through ROB-676 is development
  evidence. It cannot be substituted into the confirmatory corpus.
- Any failure promoted after a confirmatory run is a regression case with new
  lineage. It does not alter or replace the original held-out row.

Target fault output, external fault output, and dogfood fault output are
**relevant result exposure**. No confirmatory amendment may reuse them.

## Future seed and immutable selection

Selection uses the League of Entropy drand default mainnet:

- chain hash:
  `8990e7a9aaed2ffed73dbd7092123d6f289930540d7651336225dc172e51b2ce`;
- genesis time: `1595431050` Unix seconds;
- period: 30 seconds;
- API path: `/<chain-hash>/public/<round>` on
  [official relays](https://docs.drand.love/developer/http-api/).

Let `g` be GATE-2's Linear `completedAt` Unix second. The committed future
target time is `u = g + 300`. Select the smallest mainnet round whose nominal
time is at or after `u`:

```text
round = ceil((u - 1595431050) / 30) + 1
```

The five-minute delay makes the beacon unknown when GATE-2 is completed. ROB-678
must fetch the exact round from `api.drand.sh` and `drand.cloudflare.com`,
require identical round/signature/randomness values, and verify the signature
against the pinned chain information with an official drand client. It records
the raw responses and verification command. The
[round endpoint](https://docs.drand.love/developer/API-v1/chain-hash-public-round/)
returns the committed round. Relay unavailability blocks materialization; it
does not permit a new round.

Derive the 32-byte selection seed as:

```text
SHA-256(
  "elara:exp-003:er3:fnd-2:v1\0" ||
  chain_hash || ":" || decimal_round || ":" || randomness_hex || ":" ||
  "93e91662ed9c7c7d9632c66ecce6a87e1a02d063"
)
```

All hashes below compare lowercase hexadecimal SHA-256 values lexicographically.
For a task or row ID `id`, its order key is `SHA-256(seed || "\0" || id)`. For
generated field `field` on task `id`, its token is the first 16 lowercase hex
characters of `SHA-256(seed || "\0" || id || "\0" || field)`. ROB-678 uses those
tokens for module names, paths, preimages, postimages, and opaque sentinels. It
may not choose friendlier literals manually.

## Candidate task frame

ROB-678 materializes every selected task as an offline minimal Mix repository
with immutable initial files, a fixed scripted tool plan, an expected no-fault
workspace digest, and independent ground-truth counters. The table is the
complete candidate pool. `F1` through `F4` are defined in the next section.

| ID  | Class | Frozen task brief                                                            | Primary | Secondary |
| --- | ----- | ---------------------------------------------------------------------------- | ------- | --------- |
| W01 | write | Create an absent nested UTF-8 source file with exact desired bytes.          | F1      | F3        |
| W02 | write | Replace a file whose complete bytes equal the declared preimage.             | F2      | F4        |
| W03 | write | Reconcile a target whose bytes already equal the desired postimage.          | F4      | F1        |
| W04 | write | Reject a target differing from both declared preimage and postimage.         | F4      | F1        |
| W05 | write | Replace an existing empty file with generated source content.                | F1      | F3        |
| W06 | write | Replace exact generated content with an empty file.                          | F2      | F4        |
| W07 | write | Create a file and missing parent path without changing sibling files.        | F3      | F4        |
| W08 | write | Apply an exact target write while an unrelated workspace file changes.       | F2      | F3        |
| P01 | patch | Make one exact unique LF-delimited `old_text`/`new_text` edit.               | F1      | F3        |
| P02 | patch | Make one exact unique edit in a CRLF file without changing other bytes.      | F2      | F4        |
| P03 | patch | Reconcile when the exact desired postimage already exists.                   | F4      | F1        |
| P04 | patch | Reject when neither the exact preimage nor postimage exists.                 | F4      | F1        |
| P05 | patch | Preserve or truthfully conflict with an unrelated same-file concurrent edit. | F2      | F3        |
| P06 | patch | Apply one bounded two-file source-and-test transformation.                   | F1      | F3        |
| P07 | patch | Apply a bounded create-and-modify transformation.                            | F3      | F4        |
| P08 | patch | Apply a bounded delete-and-modify transformation.                            | F2      | F4        |
| S01 | shell | Run an opaque command that appends one record and creates a second sentinel. | F1      | F3        |
| S02 | shell | Run an opaque command with two ordered filesystem effects and exit 0.        | F2      | F3        |
| S03 | shell | Run an opaque command that mutates once and then exits nonzero.              | F3      | F4        |
| S04 | shell | Run an opaque build/test command that creates an undeclared build artifact.  | F2      | F4        |

The generated task request states the intended coding outcome, not the hidden
ground-truth tokens. Ground truth is used by the scorer, never by the subject.
Optional formatting, checkpoints, diagnostics, or provider network calls are
disabled unless both compared adapters implement the same frozen behavior.

## Conditional GATE-2 selection

Only these GATE-2 branches are eligible under v1:

1. **Continue — Universal:** include classes `write`, `patch`, and `shell`.
   Within each class select one task per primary fault type by lowest order key;
   because shell has one candidate per type, all four shell tasks are selected.
   Total: 12 tasks.
2. **Narrow — Typed-only (`write` + `patch`):** within each class select one
   task per primary fault type, then the lowest-key remaining task. Total: 10.
3. **Narrow — Typed-only (`write` only):** select W01–W08. Total: 8.
4. **Narrow — Typed-only (`patch` only):** select P01–P08. Total: 8.
5. **Pivot — Snapshot-dependent** or **Stop — Stop:** no ER-3 corpus is
   materialized. The existing ER-3 issues remain blocked or are cancelled.

GATE-2 may not invent another operation-class branch for this preregistration. A
different nonempty semantic scope requires ER-3/FND-2-v2 and fresh inputs.

Selected tasks are ordered by their order key. Every selected task contributes
its primary fault row. Let `N` be selected task count and `R = min(20, 2 * N)`.
Add secondary rows for the lowest-key selected tasks until there are exactly `R`
scored fault rows. Thus Universal has 12 tasks/20 rows, typed write+patch has
10/20, and either single typed class has 8/16. No observed result may add, drop,
or replace a row.

Every selected task also runs one no-fault correctness trial. No-fault timing
uses two unscored warmups followed by 10 measured repetitions; fault-row
repetition is three runs in the fixed order
`baseline, target, target, baseline, baseline, target`, using a fresh fixture
each time. All three repetitions must yield the same primary classification per
condition. Any inconsistency is a harness failure and invalidates confirmatory
passage.

## Paired fault types

The internal baseline/target comparison uses externally alignable schedules, not
fabricated baseline intent/receipt commits:

| ID  | Frozen schedule                                                                                                                              | Target relation       | Required observable alignment                                                                          |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------- | --------------------- | ------------------------------------------------------------------------------------------------------ |
| F1  | Kill the controller after the tool request is durably represented by the condition's nearest existing evidence and before executor dispatch. | Nearest target cut 2. | Neither condition may have begun the external operation. Baseline durable intent is N/A, not invented. |
| F2  | Kill the selected worker/tool owner after dispatch is observed and before callback/external mutation.                                        | Nearest target cut 5. | Ground truth proves zero external mutations at the cut. Internal acceptance seams may differ.          |
| F3  | Kill the worker/tool owner after one ground-truth external mutation and before a terminal result reaches the session.                        | Target cut 6.         | Ground truth proves one external mutation and no persisted session result at the cut.                  |
| F4  | Kill the controller after a terminal tool outcome reaches the controller boundary and before session-result persistence.                     | Target cut 8.         | Caller/session delivery and persisted transcript are observed separately.                              |

ROB-678 expands each selected row into the full ROB-667 fault model: exact
barrier, killed owner, delivered/dropped messages, storage survival, restart
order, admissible evidence, last durable fact, historical knowledge, expected
classification, permitted/prohibited action, deadline, and convergence bound. No
schedule uses timing sleeps as its trigger.

## Recovery rubric and locked denominator

Each condition in each locked paired row records exactly one
`primary_recovery_class`:

- `automatic_terminal`: causal `completed` or `failed` evidence and the correct
  safe next action arrive within the bound with no unplanned intervention;
- `automatic_known_nonterminal`: proven `not_started` or conflict plus the
  correct safe next action arrives automatically within the bound;
- `automatic_safe_indeterminate`: causal terminal truth remains unknown, but a
  truthful `:indeterminate` classification and unique safe next action arrive
  automatically within the bound;
- `manual_recovery`: at least one unplanned operator action is required to
  obtain or apply the safe next action;
- `ambiguous_no_safe_action`: no unique evidence-backed safe action exists by
  the bound;
- `safety_disqualifier`: a frozen safety invariant is violated;
- `harness_failure`: required evidence is missing, malformed, inconsistent, or
  produced by an invalid injection/fixture;
- `non_comparable`: allowed only by an adapter-equivalence issue before fault
  exposure; never assigned from a fault result.

`automatic_safe_indeterminate` is truthful but still ambiguous about causal
terminal outcome. Define the bad-recovery indicator:

```text
bad(row, condition) =
  primary_recovery_class in {
    automatic_safe_indeterminate,
    manual_recovery,
    ambiguous_no_safe_action
  }
```

The locked paired denominator is every selected internal row accepted by ROB-679
before fault exposure. No row can disappear after exposure. `B` is the count of
denominator rows with `bad(row, baseline)`. `T` is the corresponding target
count. The predicate counts an ambiguous-and-manual row once because the primary
classes are mutually exclusive.

Missing data, `harness_failure`, post-exposure `non_comparable`, or inconsistent
repetitions invalidate the confirmatory run. They are not denominator exclusions
and cannot make `B` or `T` smaller. Diagnostic partial calculations must be
labeled non-confirmatory.

Material recovery improvement requires all of:

```text
B >= 2
B - T >= 2
(B - T) / B >= 0.50
```

Compare the ratio as the exact integer inequality `2 * (B - T) >= B`; do not
round. `B < 2` cannot establish improvement.

## Evidence and report schema

Every machine-readable row record contains these required fields:

```text
preregistration_version, seed_round, seed_digest
corpus_manifest_digest, task_id, row_id, operation_class, scope_id
exposure_split, fixture_commit, initial_workspace_digest
condition, target_commit, adapter_digest, run_index, order_index
fault_type, barrier_id, killed_owner, delivered_messages, dropped_messages
surviving_storage, restart_order, observation_deadline_ms
controller_facts, executor_facts, workspace_observations, last_durable_fact
causal_terminal_evidence_expected, causal_terminal_evidence_observed
historical_execution_knowledge, session_classification
safe_next_action_expected, safe_next_action_observed
knowledge_convergence_ms, terminal_convergence_ms
admission_count, callback_attempt_count, external_mutation_count
session_result_count, unplanned_intervention_count
initial_reset_verified, final_workspace_digest, expected_workspace_digest
primary_recovery_class, safety_disqualifiers, harness_errors
elapsed_ms, cpu_ms, storage_bytes, model_call_count, tool_call_count
raw_evidence_digest, artifact_digests
```

The report includes every raw row before aggregates, the locked denominator,
`B`, `T`, both exact material-improvement inequalities, safety outcomes,
knowledge/safe-action convergence, causal-terminal convergence, no-fault
correctness/timing, CPU/storage diagnostics, dogfood results, external coverage,
and amendment/exposure history.

## Safety, truth, and product thresholds

Safety is Stop-first. Any of these is a disqualifier:

- duplicate external mutation;
- callback reinvocation without declared atomic whole-mutation ID/digest
  deduplication and causal receipt;
- wrong or corrupt external effect;
- false success or false error relative to admissible causal evidence;
- accepted-job failover to another executor;
- benchmark contamination, hidden row substitution, or post-exposure tuning.

Passage also requires:

- 100% correct no-fault final workspaces;
- truthful knowledge-state and correct safe-next-action convergence within the
  frozen row bound for 100% of rows;
- causal `completed`/`failed` convergence for 100% of the preregistered rows in
  which admissible causal terminal evidence survives;
- the material recovery formula above;
- no-fault timing based on each row's 10 measured repetitions after two warmups:
  target/baseline per-row median ratios, corpus median ratio at most 1.20, and
  no row ratio above 2.0. For an even count, median is the arithmetic mean of
  the two middle sorted values. Compare unrounded rational values;
- CPU milliseconds and storage-byte growth reported per row and in aggregate,
  but not used as independent pass/fail gates in v1.

No aggregate score may offset a safety, correctness, convergence, recovery,
timing, or dogfood failure.

## Preregistered GATE-3 Narrow scopes

Only operation-class scopes are eligible; task-level, cut-level,
evidence-survival, favorable-row, and post-hoc scopes are forbidden.

1. **N1 — typed mutations (`write` + `patch`).** Eligible only when the GATE-2
   full scope also contains shell, making N1 strict.
2. **N2 — declarative write only.** Eligible when the GATE-2 scope contains
   write plus at least one other class.
3. **N3 — typed patch/edit only.** Eligible when the GATE-2 scope contains patch
   plus at least one other class.

A Narrow candidate is nonempty only if its locked corpus has at least four
tasks, six paired fault rows, `B >= 2`, and a dogfood plan with at least eight
tasks in that scope. It must independently pass every applicable safety,
no-fault correctness, knowledge/safe-action, causal-terminal, material recovery,
timing, and dogfood threshold. Rows remain selected by the original seed rule;
none is removed because of its result.

Decision precedence is deterministic:

1. Stop on any safety disqualifier or invalid confirmatory run.
2. Continue if the complete GATE-2 scope passes every threshold.
3. Test eligible strict N1, then N2, then N3; select the first that passes all
   thresholds.
4. Pivot only when safety and material value pass but one of these frozen
   contradictions prevents deployment and no Narrow scope resolves it:
   `sidecar_ownership` (the evidence owner cannot preserve the pure reducer),
   `causal_persistence_boundary` (required proof cannot commit at its frozen
   owner but a named boundary can), or `safe_action_presentation` (correct
   evidence exists but cannot be presented within the dogfood bound).
5. Stop when no prior outcome applies, including recovery, timing, or dogfood
   threshold failure without an eligible contradiction.

GATE-2's Snapshot-dependent result is a phase-local Pivot and blocks this ER-3
design; it is not an eligible GATE-3 Narrow outcome.

## Dogfood frame and exact denominators

Dogfood replays these 12 genuine historical Elara tasks from each commit's
parent snapshot, without later Git history in the subject workspace:

| ID  | Ground-truth commit                                                                                       | Task kind                         | Frozen assignment                        |
| --- | --------------------------------------------------------------------------------------------------------- | --------------------------------- | ---------------------------------------- |
| D01 | [`73fb86f`](https://github.com/robertguss/elixir-harness/commit/73fb86f5948b0bf26d611d04dbc1dfe1d75e40d4) | one-line cleanup                  | no-fault control                         |
| D02 | [`4094ec2`](https://github.com/robertguss/elixir-harness/commit/4094ec2a7bdbe211ada36e77b9842972b263a8da) | configuration/documentation       | no-fault control                         |
| D03 | [`1d76d41`](https://github.com/robertguss/elixir-harness/commit/1d76d41ddda04bd7188a18e8d26ab51a057dc2c7) | CLI draining bug fix              | controller loss before dispatch          |
| D04 | [`39bad8c`](https://github.com/robertguss/elixir-harness/commit/39bad8cd47c40939d268496388a355c6931a155d) | torn-session recovery bug fix     | executor loss before mutation            |
| D05 | [`c8aeba3`](https://github.com/robertguss/elixir-harness/commit/c8aeba30a3be78c2582d5eaadccfdb6eb251261f) | session-list feature and tests    | executor loss after mutation             |
| D06 | [`9b92dd7`](https://github.com/robertguss/elixir-harness/commit/9b92dd74dcbcbcd65ddab3a01217e2d1c3ab5ad6) | user documentation change         | completion reply lost before persistence |
| D07 | [`b0cad10`](https://github.com/robertguss/elixir-harness/commit/b0cad102436b85c3415a85aa95880bffee1852d4) | formatting/build-dominated change | timeout/interrupt                        |
| D08 | [`bd086ad`](https://github.com/robertguss/elixir-harness/commit/bd086ad224a79595a99aa8e83015385586ee7b52) | effect-handler refactor           | concurrent workspace conflict            |
| D09 | [`f4adde3`](https://github.com/robertguss/elixir-harness/commit/f4adde33c14e70149f3c84035ddfae5ec6c7a342) | persistence and hydration feature | controller loss before dispatch          |
| D10 | [`51c8296`](https://github.com/robertguss/elixir-harness/commit/51c82967eedb6ab0d87b9fff0f6bd4baf9bae6e5) | resume/continue feature           | executor loss after mutation             |
| D11 | [`a77e4c8`](https://github.com/robertguss/elixir-harness/commit/a77e4c89c0191246b5a3c5fdc71c17b8bceade6a) | provider/replay/UTF-8 fixes       | completion reply lost before persistence |
| D12 | [`eb20145`](https://github.com/robertguss/elixir-harness/commit/eb20145d2f052aaa9971b30ddd2b5889a654db49) | interrupt/load-release bug fix    | concurrent workspace conflict            |

ROB-681 freezes prompts, acceptance commands, provider/model, repository
snapshots, exact barriers, and report checksums before any target fault result.
Task execution order is the seed order key over dogfood IDs. No failed task is
replaced. If a historical parent no longer builds in the available pinned
toolchain, that task is a plan-validation failure; changing membership requires
ER-3/FND-2-v2 before fault exposure.

Let:

- `P = 12`, the planned task count;
- `I = 10`, injected-failure tasks;
- `C = 2`, no-fault controls;
- `D`, tasks reaching a recorded classified disposition and evidence-backed safe
  next action by their deadline. Dispositions are `completed`, `failed`,
  `conflict`, `not_started`, or truthful `indeterminate`; harness failure and
  abandonment are not classified dispositions;
- `U`, members of `D` requiring zero unplanned recovery interventions;
- `G`, injected tasks with evidence-backed correct safe-next-action guidance;
- `A`, tasks abandoned because of protocol friction.

An unplanned intervention is any operator action not in the frozen task plan,
fault injection, routine capability approval, or evidence-capture procedure.
Multiple interventions in one task still make that task non-U.

Dogfood passes only when:

```text
8 <= P <= 12
D >= 8
distinct injected failure types >= 5
C >= 2
G == I
5 * U >= 4 * D
A == 0
no safety disqualifier
```

The 80% threshold is the exact integer comparison `5 * U >= 4 * D`; displayed
percentages are descriptive and rounded to one decimal place, half away from
zero. Model quality and code elegance are observations, not v1 gate metrics.

Every frozen historical diff modifies or adds files and deletes no whole file,
so all 12 tasks can be expressed either as exact full-file writes or bounded
patches. A GATE-3 Narrow candidate uses the same 12 tasks, order, failures, and
controls: N2 maps every change to declarative writes; N3 maps every change to
bounded patches; N1 freezes a per-task write/patch mapping before its run. A
mapping that cannot reproduce the historical acceptance result makes that
candidate ineligible; it never causes task substitution.

## Pinned Lemon suitability

Lemon is pinned at
[`b9ed0660e0d7fe61f38156f0aeb65e839b4e7f39`](https://github.com/z80dev/lemon/tree/b9ed0660e0d7fe61f38156f0aeb65e839b4e7f39).
Its local source build requires Elixir 1.19.5+, OTP 28.5+, and `mix deps.get` /
`mix compile`; Bun and Node are needed only for optional TUI/web development.
The local runtime and deterministic `stream_fn` seam do not require a hosted
control plane or live provider.

| Suitability criterion                  | Frozen assessment                                                      | Source                                                                                                                                                                                                                                                                                                |
| -------------------------------------- | ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Source and immutable revision          | Pass                                                                   | [Pinned tree](https://github.com/z80dev/lemon/tree/b9ed0660e0d7fe61f38156f0aeb65e839b4e7f39)                                                                                                                                                                                                          |
| Local run without hosted control plane | Pass; local runtime is supported                                       | [Install guide](https://github.com/z80dev/lemon/blob/b9ed0660e0d7fe61f38156f0aeb65e839b4e7f39/docs/install.md#L168-L211)                                                                                                                                                                              |
| Deterministic provider injection       | Pass locally via `stream_fn` and canned streams                        | [Lifecycle](https://github.com/z80dev/lemon/blob/b9ed0660e0d7fe61f38156f0aeb65e839b4e7f39/apps/coding_agent/lib/coding_agent/session/lifecycle.ex#L166-L197), [mocks](https://github.com/z80dev/lemon/blob/b9ed0660e0d7fe61f38156f0aeb65e839b4e7f39/apps/lemon_agent/test/support/mocks.ex#L246-L327) |
| Write overlap                          | Pass for deterministic full overwrite with optional extras disabled    | [write.ex](https://github.com/z80dev/lemon/blob/b9ed0660e0d7fe61f38156f0aeb65e839b4e7f39/apps/coding_agent/lib/coding_agent/tools/write.ex#L178-L258)                                                                                                                                                 |
| Edit overlap                           | Pass only for an exact unique match that does not enter fuzzy fallback | [edit.ex](https://github.com/z80dev/lemon/blob/b9ed0660e0d7fe61f38156f0aeb65e839b4e7f39/apps/coding_agent/lib/coding_agent/tools/edit.ex#L268-L296)                                                                                                                                                   |
| Shell overlap                          | Pass for non-PTY local shell, cwd, combined output, and exit code      | [bash.ex](https://github.com/z80dev/lemon/blob/b9ed0660e0d7fe61f38156f0aeb65e839b4e7f39/apps/coding_agent/lib/coding_agent/tools/bash.ex#L77-L211)                                                                                                                                                    |
| Observable outcomes                    | Pass for files, tool events/results, and session events                | [run translator](https://github.com/z80dev/lemon/blob/b9ed0660e0d7fe61f38156f0aeb65e839b4e7f39/apps/coding_agent/lib/coding_agent/session/run_translator.ex#L70-L163)                                                                                                                                 |

No-fault comparator classes are conditional on GATE-2: Universal includes
write/edit/shell; typed write+patch includes write/edit; a single typed class
includes only that class. P01/P02 exact unique edits are eligible; fuzzy,
multi-file, create/delete patch semantics are not represented as
Lemon-equivalent.

ROB-678 also materializes three unscored adapter-equivalence fixtures from the
same generated templates: W01 for write, P01 for exact edit, and S02 for shell.
ROB-680 runs the fixtures for every operation class included by GATE-2 even when
the seed did not select that template for the scored corpus. They establish only
no-fault operation equivalence, are labeled development adapter fixtures, and
never enter the 8–12 task count, fault-row denominator, `B`/`T`, or product
claims.

### Frozen external fault eligibility

Lemon emits tool-start before a supervised task and receives the mutation result
before tool-end, but it has no durable controller intent, receipt, acceptance
commit/reply, or completion commit/reply. Session messages remain in memory
until explicit save; dangling calls reopen as interrupted rather than being
reconciled from effect evidence.

| Elara cut | Lemon evidence                                                           | Confirmatory eligibility                                   |
| --------- | ------------------------------------------------------------------------ | ---------------------------------------------------------- |
| 1–5       | No corresponding durable intent/acceptance protocol                      | Not comparable                                             |
| 6         | A physical effect can occur before the tool-task result reaches the loop | Effect-timing observation only; recovery is not comparable |
| 7         | No durable completion commit before reply                                | Not comparable                                             |
| 8         | Completion can be emitted before final session save                      | Ordering observation only; recovery is not comparable      |

Sources:
[tool dispatch/result](https://github.com/z80dev/lemon/blob/b9ed0660e0d7fe61f38156f0aeb65e839b4e7f39/apps/lemon_agent/lib/lemon_agent/loop/tool_calls.ex#L507-L709),
[session save ordering](https://github.com/z80dev/lemon/blob/b9ed0660e0d7fe61f38156f0aeb65e839b4e7f39/apps/coding_agent/lib/coding_agent/executor/session_runner.ex#L83-L89),
and
[interrupted-call hydration](https://github.com/z80dev/lemon/blob/b9ed0660e0d7fe61f38156f0aeb65e839b4e7f39/apps/coding_agent/lib/coding_agent/session/persistence.ex#L156-L251).

Therefore v1 freezes **zero semantically equivalent external recovery fault
rows**. The required floor—no-fault equivalence for every included operation
class plus at least three equivalent fault rows across two fault types—cannot
currently be met. If source/build verification in ROB-680 agrees, ROB-775's
valid result is **Insufficient comparability** and supports no Elara advantage
or disadvantage. The cut-6 and cut-8 observations may be reported as secondary
non-comparable facts but are never scored.

Lemon passes the fixed suitability criteria, so low fault coverage is not a
replacement trigger. ER-3/FND-2-v1 names no substitute. Replacement requires a
documented factual failure of a suitability criterion, ER-3/FND-2-v2, and fresh
inputs; poor comparative coverage or results are never replacement reasons.

## Amendments and invalidation

Before relevant result exposure, a factual error or impossible fixture may be
corrected only by committing ER-3/FND-2-v2 with a complete change log and new
future seed round. v1 remains preserved and is marked superseded.

After any target, comparator, or dogfood fault result is observed, changes to
membership, seed/selection, operation scope, row schedule, rubric, denominator,
threshold, comparator, eligibility, adapter semantics, or report schema
invalidate the confirmatory run. A new version must use a future drand round,
new materialized fixture commits/digests, and fresh held-out execution. Exposed
results may be retained as development/regression evidence only.

No task or row may be excluded because it is slow, fails, is unfavorable, cannot
be recovered, or makes an external comparison insufficient. Environment loss is
missing/harness-failure evidence under v1 unless a new version is frozen before
exposure.

## Frozen limitations

- The synthetic corpus tests harness recovery, not general coding-agent quality.
- Concrete generated variants are held out from target implementation, but task
  families and metric rules are public.
- Historical dogfood commits are public and evaluate recovery usability, not
  model novelty or benchmark generalization.
- Lemon is another BEAM runtime. Its comparison cannot establish BEAM
  superiority, and v1 already expects insufficient durable-fault comparability.
- The four paired schedules align externally observable failure conditions; the
  baseline has no target intent/acceptance/receipt seams and those facts remain
  N/A rather than being fabricated.
- CPU and storage are descriptive in v1. A later experiment may preregister
  independent resource limits without rewriting this one.

## Verification record required at completion

ROB-772 records:

```bash
git rev-parse HEAD
git status --short
git diff --check
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

It also records the document blob/SHA-256, confirms ROB-668 or later target code
did not begin, and verifies that Linear has exactly one next executable Todo.
