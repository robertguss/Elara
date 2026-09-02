# Elara roadmap history

> **Migration snapshot:** 2026-09-02<br> **Source:** five historical Linear
> projects, 81 issues<br> **Current roadmap:** [`roadmap.md`](roadmap.md)

This archive moves the planning information needed to understand Elara into the
repository. Linear links remain as provenance for the original issue records,
not as a live status dependency. Immutable experiment details live under
[`docs/experiments/`](experiments/README.md), and implementation history is in
Git.

## Project outcomes

| Historical project              | Linear status at migration | Repository disposition                                                                                       |
| ------------------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Elara                           | Completed                  | ER-1 v1 implemented durable identity/receipts but Gate 1 stopped on a contradictory frozen count contract.   |
| Elara ER-1 v2                   | Canceled                   | Corrected contract froze successfully; execution aborted in harness mechanics before gate-eligible evidence. |
| Elara ER-1 v3                   | Completed                  | Fresh complete matrix passed; Gate 1 selected Continue.                                                      |
| Elara ER-2 — Real Mutations     | Completed                  | Write, literal patch, opaque shell, and cross-class matrix passed; Gate 2 selected Continue — Universal.     |
| Elara ER-3 — Confirmatory Value | In Progress                | V1–V7 are closed without a complete confirmatory result; V8 continues under repository IDs in `roadmap.md`.  |

## Evidence chronology

| Phase   | Key pushed commits   | Canonical repository evidence                                                                                                | Outcome                                                                                                               |
| ------- | -------------------- | ---------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| ER-1 v1 | `93e9166`…`a1ee8b3`  | [`003-effect-receipt-er1-contract.md`](experiments/003-effect-receipt-er1-contract.md)                                       | Safety controls and 7/8 rows passed; frozen row-1 accounting contradiction forced Stop.                               |
| ER-1 v2 | `a1f3f09`            | [`003-effect-receipt-er1-v2-contract.md`](experiments/003-effect-receipt-er1-v2-contract.md)                                 | Fresh contract froze; execution invalidated by harness mechanics, no gate outcome.                                    |
| ER-1 v3 | `bcf1daa`            | [`003-effect-receipt-er1-v3-contract.md`](experiments/003-effect-receipt-er1-v3-contract.md)                                 | Complete fresh revalidation passed; Continue.                                                                         |
| ER-2    | `9aa34d3`…`9ff416f`  | [`004-real-mutations-er2-contract.md`](experiments/004-real-mutations-er2-contract.md)                                       | Universal semantics selected across write, patch, and truthful opaque shell.                                          |
| ER-3 v1 | `020d68c`…`ff15e21`  | [`003-effect-receipt-confirmatory-preregistration.md`](experiments/003-effect-receipt-confirmatory-preregistration.md)       | Frozen adapter could not execute fault contexts; no target fault exposure.                                            |
| ER-3 v2 | `51966ee`, `b0c0fd4` | [`003-effect-receipt-confirmatory-preregistration-v2.md`](experiments/003-effect-receipt-confirmatory-preregistration-v2.md) | Two frozen task/fault assignments were semantically impossible.                                                       |
| ER-3 v3 | `9650322`…`1d57c7e`  | [`003-effect-receipt-confirmatory-preregistration-v3.md`](experiments/003-effect-receipt-confirmatory-preregistration-v3.md) | Inputs and adapter qualified, but no frozen top-level execution command existed.                                      |
| ER-3 v4 | `40fd254`…`bc1444a`  | [`003-effect-receipt-v4-qualification-failure.md`](experiments/003-effect-receipt-v4-qualification-failure.md)               | Qualification exposed row-level versus condition-specific causal applicability error.                                 |
| ER-3 v5 | `3c7a26a`, `00eb27a` | [`003-effect-receipt-v5-materialization-failure.md`](experiments/003-effect-receipt-v5-materialization-failure.md)           | Exposed seed selected P02, the sole candidate without a constructor; stopped before corpus output.                    |
| ER-3 v6 | `ed9a2db`…`dcc5089`  | [`003-effect-receipt-v6-execution-failure.md`](experiments/003-effect-receipt-v6-execution-failure.md)                       | After 18 held-out runs, selected two-step P06 failed the frozen single-step command path.                             |
| ER-3 v7 | `98cf40a`…`f43dd91`  | [`003-effect-receipt-v7-materialization-failure.md`](experiments/003-effect-receipt-v7-materialization-failure.md)           | Exact command-path proof passed; post-beacon materializer stopped on stale V6 preflight path before selection/output. |

## Historical issue inventory

### Elara — original roadmap (21)

| Issue                                                   | Status   | Purpose                                                          |
| ------------------------------------------------------- | -------- | ---------------------------------------------------------------- |
| [ROB-667](https://linear.app/robert-guss/issue/ROB-667) | Done     | Freeze ER-1 contract and baseline.                               |
| [ROB-772](https://linear.app/robert-guss/issue/ROB-772) | Done     | Preregister evidence, thresholds, and comparator suitability.    |
| [ROB-668](https://linear.app/robert-guss/issue/ROB-668) | Done     | Persist stable job identity, digest, and controller intent.      |
| [ROB-669](https://linear.app/robert-guss/issue/ROB-669) | Done     | Implement durable test-executor ledger.                          |
| [ROB-670](https://linear.app/robert-guss/issue/ROB-670) | Done     | Connect marker acceptance and reconciliation.                    |
| [ROB-671](https://linear.app/robert-guss/issue/ROB-671) | Done     | Execute eight-cut deterministic crash matrix.                    |
| [ROB-672](https://linear.app/robert-guss/issue/ROB-672) | Done     | Apply ER-1 Gate 1; Stop on frozen-contract inconsistency.        |
| [ROB-673](https://linear.app/robert-guss/issue/ROB-673) | Canceled | Original ER-2 write issue, superseded by dedicated ER-2 project. |
| [ROB-674](https://linear.app/robert-guss/issue/ROB-674) | Canceled | Original ER-2 patch issue, superseded.                           |
| [ROB-675](https://linear.app/robert-guss/issue/ROB-675) | Canceled | Original ER-2 shell issue, superseded.                           |
| [ROB-676](https://linear.app/robert-guss/issue/ROB-676) | Canceled | Original ER-2 matrix, superseded.                                |
| [ROB-677](https://linear.app/robert-guss/issue/ROB-677) | Canceled | Original Gate 2, superseded.                                     |
| [ROB-678](https://linear.app/robert-guss/issue/ROB-678) | Canceled | Original corpus materialization, superseded.                     |
| [ROB-773](https://linear.app/robert-guss/issue/ROB-773) | Canceled | Original neutral runner/scorer, superseded.                      |
| [ROB-679](https://linear.app/robert-guss/issue/ROB-679) | Canceled | Original internal adapter proof, superseded.                     |
| [ROB-774](https://linear.app/robert-guss/issue/ROB-774) | Canceled | Original internal execution, superseded.                         |
| [ROB-680](https://linear.app/robert-guss/issue/ROB-680) | Canceled | Original external adapter proof, superseded.                     |
| [ROB-775](https://linear.app/robert-guss/issue/ROB-775) | Canceled | Original external execution, superseded.                         |
| [ROB-681](https://linear.app/robert-guss/issue/ROB-681) | Canceled | Original dogfood freeze, superseded.                             |
| [ROB-776](https://linear.app/robert-guss/issue/ROB-776) | Canceled | Original dogfood execution, superseded.                          |
| [ROB-682](https://linear.app/robert-guss/issue/ROB-682) | Canceled | Original Gate 3, superseded.                                     |

### ER-1 v2 and v3 (6)

| Issue                                                   | Status   | Purpose/result                                         |
| ------------------------------------------------------- | -------- | ------------------------------------------------------ |
| [ROB-820](https://linear.app/robert-guss/issue/ROB-820) | Done     | Freeze corrected v2 contract, manifest, and harness.   |
| [ROB-821](https://linear.app/robert-guss/issue/ROB-821) | Canceled | V2 matrix invalidated by harness mechanics.            |
| [ROB-822](https://linear.app/robert-guss/issue/ROB-822) | Canceled | No gate-eligible v2 evidence.                          |
| [ROB-823](https://linear.app/robert-guss/issue/ROB-823) | Done     | Repair harness mechanics and freeze fresh v3 evidence. |
| [ROB-824](https://linear.app/robert-guss/issue/ROB-824) | Done     | Execute complete frozen v3 matrix.                     |
| [ROB-825](https://linear.app/robert-guss/issue/ROB-825) | Done     | Gate 1 v3 selected Continue.                           |

### ER-2 real mutations (7)

| Issue                                                   | Status   | Purpose/result                             |
| ------------------------------------------------------- | -------- | ------------------------------------------ |
| [ROB-826](https://linear.app/robert-guss/issue/ROB-826) | Canceled | Duplicate foundation issue.                |
| [ROB-827](https://linear.app/robert-guss/issue/ROB-827) | Done     | Freeze real-mutation contracts and matrix. |
| [ROB-828](https://linear.app/robert-guss/issue/ROB-828) | Done     | Reconcile declarative writes.              |
| [ROB-829](https://linear.app/robert-guss/issue/ROB-829) | Done     | Classify opaque shell truthfully.          |
| [ROB-830](https://linear.app/robert-guss/issue/ROB-830) | Done     | Reconcile typed literal patches.           |
| [ROB-831](https://linear.app/robert-guss/issue/ROB-831) | Done     | Execute cross-class failure matrix.        |
| [ROB-832](https://linear.app/robert-guss/issue/ROB-832) | Done     | Gate 2 selected Continue — Universal.      |

### ER-3 confirmatory value (47)

| Issue                                                   | Status   | Purpose/result                                                                      |
| ------------------------------------------------------- | -------- | ----------------------------------------------------------------------------------- |
| [ROB-833](https://linear.app/robert-guss/issue/ROB-833) | Done     | Materialize the frozen Universal corpus.                                            |
| [ROB-834](https://linear.app/robert-guss/issue/ROB-834) | Done     | Implement the neutral benchmark runner and scorer.                                  |
| [ROB-835](https://linear.app/robert-guss/issue/ROB-835) | Done     | Prove baseline/receipt adapter equivalence.                                         |
| [ROB-836](https://linear.app/robert-guss/issue/ROB-836) | Done     | Prove Lemon adapter equivalence and insufficient fault comparability.               |
| [ROB-837](https://linear.app/robert-guss/issue/ROB-837) | Done     | Freeze and validate the dogfood plan.                                               |
| [ROB-838](https://linear.app/robert-guss/issue/ROB-838) | Canceled | Internal execution unauthorized: frozen adapter could not execute fault contexts.   |
| [ROB-839](https://linear.app/robert-guss/issue/ROB-839) | Done     | Record the frozen Lemon non-comparability result.                                   |
| [ROB-840](https://linear.app/robert-guss/issue/ROB-840) | Canceled | Dogfood unauthorized after invalid internal path.                                   |
| [ROB-841](https://linear.app/robert-guss/issue/ROB-841) | Canceled | Gate 3 had no complete valid evidence.                                              |
| [ROB-842](https://linear.app/robert-guss/issue/ROB-842) | Done     | Freeze the V2 pre-exposure correction.                                              |
| [ROB-843](https://linear.app/robert-guss/issue/ROB-843) | Done     | Rematerialize V2 seed-bound inputs.                                                 |
| [ROB-844](https://linear.app/robert-guss/issue/ROB-844) | Canceled | Adapter qualification blocked by incompatible frozen rows.                          |
| [ROB-845](https://linear.app/robert-guss/issue/ROB-845) | Canceled | V2 internal execution unauthorized.                                                 |
| [ROB-846](https://linear.app/robert-guss/issue/ROB-846) | Canceled | V2 dogfood unauthorized.                                                            |
| [ROB-847](https://linear.app/robert-guss/issue/ROB-847) | Canceled | V2 Gate 3 had no decision.                                                          |
| [ROB-848](https://linear.app/robert-guss/issue/ROB-848) | Done     | Correct incompatible rows and freeze V3.                                            |
| [ROB-849](https://linear.app/robert-guss/issue/ROB-849) | Done     | Rematerialize compatible V3 inputs.                                                 |
| [ROB-850](https://linear.app/robert-guss/issue/ROB-850) | Done     | Qualify the V3 internal fault adapter.                                              |
| [ROB-851](https://linear.app/robert-guss/issue/ROB-851) | Canceled | V3 had no frozen top-level execution command.                                       |
| [ROB-852](https://linear.app/robert-guss/issue/ROB-852) | Canceled | V3 dogfood unauthorized.                                                            |
| [ROB-853](https://linear.app/robert-guss/issue/ROB-853) | Canceled | V3 Gate 3 had no decision.                                                          |
| [ROB-854](https://linear.app/robert-guss/issue/ROB-854) | Done     | Freeze the V4 command-complete protocol.                                            |
| [ROB-855](https://linear.app/robert-guss/issue/ROB-855) | Done     | Materialize fresh V4 inputs.                                                        |
| [ROB-856](https://linear.app/robert-guss/issue/ROB-856) | Canceled | Qualification found condition-specific causal-applicability error.                  |
| [ROB-857](https://linear.app/robert-guss/issue/ROB-857) | Canceled | V4 internal execution unauthorized.                                                 |
| [ROB-858](https://linear.app/robert-guss/issue/ROB-858) | Canceled | V4 dogfood unauthorized.                                                            |
| [ROB-859](https://linear.app/robert-guss/issue/ROB-859) | Canceled | V4 Gate 3 had no decision.                                                          |
| [ROB-860](https://linear.app/robert-guss/issue/ROB-860) | Done     | Freeze condition-correct V5 protocol.                                               |
| [ROB-861](https://linear.app/robert-guss/issue/ROB-861) | Canceled | V5 seed selected P02, the missing constructor.                                      |
| [ROB-862](https://linear.app/robert-guss/issue/ROB-862) | Canceled | V5 qualification unauthorized.                                                      |
| [ROB-863](https://linear.app/robert-guss/issue/ROB-863) | Canceled | V5 internal execution unauthorized.                                                 |
| [ROB-864](https://linear.app/robert-guss/issue/ROB-864) | Canceled | V5 dogfood unauthorized.                                                            |
| [ROB-865](https://linear.app/robert-guss/issue/ROB-865) | Canceled | V5 Gate 3 had no decision.                                                          |
| [ROB-866](https://linear.app/robert-guss/issue/ROB-866) | Done     | Prove exhaustive candidate construction before V6 seed freeze.                      |
| [ROB-867](https://linear.app/robert-guss/issue/ROB-867) | Done     | Freeze the V6 protocol and future beacon.                                           |
| [ROB-868](https://linear.app/robert-guss/issue/ROB-868) | Done     | Materialize fresh V6 condition-correct inputs.                                      |
| [ROB-869](https://linear.app/robert-guss/issue/ROB-869) | Done     | Correct, qualify, and freeze the V6 command.                                        |
| [ROB-870](https://linear.app/robert-guss/issue/ROB-870) | Canceled | P06 failed the frozen single-step command after 18 held-out records.                |
| [ROB-871](https://linear.app/robert-guss/issue/ROB-871) | Done     | Record protocol-required V6 dogfood non-execution.                                  |
| [ROB-872](https://linear.app/robert-guss/issue/ROB-872) | Canceled | V6 Gate 3 recorded no decision.                                                     |
| [ROB-873](https://linear.app/robert-guss/issue/ROB-873) | Done     | Prove all candidates through the exact V7 command path.                             |
| [ROB-874](https://linear.app/robert-guss/issue/ROB-874) | Done     | Freeze the V7 protocol and future beacon.                                           |
| [ROB-875](https://linear.app/robert-guss/issue/ROB-875) | Canceled | First post-beacon materializer guard retained a stale V6 path; no selection/output. |
| [ROB-876](https://linear.app/robert-guss/issue/ROB-876) | Canceled | V7 qualification unauthorized without a corpus.                                     |
| [ROB-877](https://linear.app/robert-guss/issue/ROB-877) | Canceled | V7 internal execution unauthorized.                                                 |
| [ROB-878](https://linear.app/robert-guss/issue/ROB-878) | Done     | Record protocol-required V7 dogfood non-execution.                                  |
| [ROB-879](https://linear.app/robert-guss/issue/ROB-879) | Canceled | V7 Gate 3 recorded no decision.                                                     |

## Migration policy

- The tables above preserve all 81 issue identities, terminal statuses, phase
  ownership, and outcome needed to reconstruct the plan.
- Detailed contracts and raw results are preserved by the linked repository
  evidence and commits. Historical Linear pages are optional provenance.
- No future status or Result is written to Linear unless explicitly requested.
- New work uses repository IDs such as `ER3-V8-1` and is updated atomically with
  the implementation commit that changes its status.
