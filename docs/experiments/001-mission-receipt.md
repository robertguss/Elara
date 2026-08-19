# EXP-001: Mission Receipt

> **Status:** Design draft; not preregistered
>
> **Protocol version:** 0
>
> **Updated:** August 2026
>
> **System under study:** Harness operating on its plugin hot-reload behavior

This document designs the first Harness lab experiment. Nothing here is frozen.
The design should change before preregistration whenever a clearer question,
fairer control, or more useful measure emerges.

See the [lab charter](README.md) for provenance and data-handling rules and the
[Harness Research Glossary](../glossary.md) for canonical vocabulary. The
preregistration commit will pin the glossary revision and governing decision set
used by this protocol.

## Governing decisions

Lab-wide governance:

- [ADR-0001 — Use versioned decision records](../decisions/0001-use-versioned-decision-records.md)
- [ADR-0002 — Version canonical research vocabulary](../decisions/0002-version-canonical-research-vocabulary.md)
- [ADR-0003 — Preserve layered experimental records](../decisions/0003-preserve-layered-experimental-records.md)

EXP-001 design:

- [ADR-0004 — Test Mission and receipt as separate factors](../decisions/0004-test-mission-and-receipt-as-separate-factors.md)
- [ADR-0005 — Use partial-preparation rollback for the pilot](../decisions/0005-use-partial-preparation-rollback-pilot.md)
- [ADR-0006 — Diagnose and add a regression test without repair](../decisions/0006-diagnose-and-add-regression-test.md)
- [ADR-0007 — Audit information-equivalent prompts](../decisions/0007-audit-information-equivalent-prompts.md)
- [ADR-0008 — Use JSON v1 contracts for the pilot](../decisions/0008-use-json-v1-contracts.md)
- [ADR-0009 — Normalize consequential claims independently](../decisions/0009-normalize-consequential-claims.md)
- [ADR-0010 — Use a minimal epistemic vocabulary](../decisions/0010-use-minimal-epistemic-vocabulary.md)
- [ADR-0011 — Use a typed evidence registry with mechanical resolution](../decisions/0011-use-typed-evidence-registry.md)
- [ADR-0012 — Defer Ash adoption until pilot-derived needs justify it](../decisions/0012-defer-ash-adoption.md)
- [ADR-0013 — Separate canonical experiment records from runtime persistence](../decisions/0013-separate-experiment-records-from-runtime-persistence.md)
- [ADR-0014 — Use an append-only JSONL run journal with immutable raw objects](../decisions/0014-use-jsonl-run-journal.md)
- [ADR-0015 — Use human-primary two-pass evaluation with an independent agent](../decisions/0015-use-human-primary-two-pass-evaluation.md)
- [ADR-0016 — Use typed categorical rubric outcomes without partial scores](../decisions/0016-use-typed-categorical-rubric-outcomes.md)

## Why this experiment comes first

Nearly every larger idea requires a stable boundary for requesting and accepting
software work:

```text
Mission in ──▶ cognitive runtime ──▶ Evidence-Carrying Result out
```

If this contract is useful, it can connect Harness to delegation, a control
plane, workspace cells, verification, causal versioning, and eventually a
constitutional controller. If it is ceremonial or harmful, learning that now is
far cheaper than building those systems around it.

Plugin hot reloading is a useful subject because it already exists, has visible
lifecycle and failure semantics, exercises BEAM-native behavior, and can be
tested without consequential external effects.

## Primary research question

Does expressing work as a typed Mission and/or requiring an evidence-carrying
result improve the correctness, completeness, traceability, uncertainty
handling, and review efficiency of Harness work enough to justify the added
structure and cost?

The “and/or” matters. Mission input and evidence output are two interventions,
not one indivisible package.

## Hypotheses

### H1 — Obligation coverage

Structured Mission input increases the proportion of requested obligations and
invariants that the result correctly addresses.

**Could weaken H1:** coverage is unchanged, or fields encourage shallow checkbox
responses rather than investigation.

### H2 — Evidence traceability

An evidence-carrying output contract increases the proportion of consequential
claims linked to evidence that actually supports them.

**Could weaken H2:** references become evidence-shaped decoration, are invalid,
or merely restate model claims.

### H3 — Honest uncertainty

The combined contract makes unsupported, contradicted, out-of-scope, and
indeterminate claims more visible.

**Could weaken H3:** the schema pressures the model to fill every field and
therefore conceal uncertainty.

### H4 — Review efficiency

A reviewer can determine whether the work should be accepted with less
transcript reading and fewer follow-up questions.

**Could weaken H4:** reviewing evidence references costs as much as reading the
ordinary transcript, or compact presentation hides necessary context.

### H5 — Net value

Any quality and review benefit exceeds the additional inference, latency,
protocol complexity, and evaluator effort.

**Could weaken H5:** the protocol improves presentation but not task outcomes,
or its overhead dominates a small task.

These are directional exploratory hypotheses, not claims of statistical proof.

## Experimental factors

Use a 2×2 design to isolate the input and output effects:

| Condition           | Input                     | Required output          |
| ------------------- | ------------------------- | ------------------------ |
| A — Baseline        | Ordinary narrative prompt | Free-form answer         |
| B — Mission only    | Structured Mission        | Free-form answer         |
| C — Receipt only    | Ordinary narrative prompt | Evidence-carrying result |
| D — Mission Receipt | Structured Mission        | Evidence-carrying result |

The ordinary and structured inputs must contain **information-equivalent task
content**. Otherwise the experiment would compare a vague baseline with a more
complete request rather than test structure.

Likewise, the free-form condition may provide evidence voluntarily. It is not
prohibited from doing good work; it simply is not required to use the receipt
shape.

## Consequential claims and epistemic vocabulary

EXP-001 adopts the glossary definitions of [claim](../glossary.md#claim),
[consequential claim](../glossary.md#consequential-claim),
[epistemic type](../glossary.md#epistemic-type), and
[disposition](../glossary.md#disposition).

A claim is consequential when making it false, materially narrower, or
unsupported could reasonably change an evaluator's judgment about an obligation,
invariant, diagnosis, artifact, verification result, uncertainty, acceptance
decision, or recommended next action. In this pilot that includes claims about:

- Whether the reported symptom was reproduced or contradicted.
- The causal mechanism and responsible production boundary.
- Which generations, plugin state, session history, or tools remained intact.
- Whether the regression test exercises the public invariant.
- The test outcome and whether it occurred for the diagnosed reason.
- What the evidence cannot establish.
- An unexpected discovery that could change disposition or next action.

Procedural narration, task restatement, navigation detail, stylistic preference,
and duplicate assertions are excluded unless they independently meet the same
counterfactual rule. Split a compound claim when its clauses can differ in
evidence, scope, or disposition.

The evaluator derives a normalized claim set from the subject's result and
produced artifacts under one rubric. Receipt conditions do not control their own
denominator by declaring fewer claims. Duplicate propositions count once; a
separable compound proposition counts as multiple claims. The primary blinded
pass does not mine the hidden full transcript for extra result claims. The later
full-process pass separately records consequential findings that the result
failed to retain.

EXP-001 uses only three epistemic types:

| Type       | Meaning                                                                   |
| ---------- | ------------------------------------------------------------------------- |
| `reported` | Inherited from the task or another source; not established in this run.   |
| `observed` | Directly read, executed, or produced in this run at the referenced scope. |
| `derived`  | Inferred from evidence with the connecting assumptions and scope stated.  |

Epistemic type is orthogonal to disposition:

| Disposition    | Meaning                                                                |
| -------------- | ---------------------------------------------------------------------- |
| `supported`    | Valid evidence supports the claim at its stated scope and assumptions. |
| `contradicted` | Valid evidence supports an incompatible conclusion at that scope.      |
| `unresolved`   | Evidence is absent, insufficient, invalid, or materially conflicting.  |

Do not use `unknown` as an epistemic type; represent a claim about an unknown as
`unresolved`. Reserve `indeterminate` for an operation or effect whose outcome
cannot be established after it may have crossed a consequential boundary.
`source_content`, `test_artifact`, `test_result`, and `session_event` are
evidence kinds, not epistemic types. A partly supported compound claim must be
split rather than given a fourth disposition.

## Evidence reference representation and validation

Receipt conditions use a top-level evidence registry. A claim links to an
evidence entry with a claim-specific relationship:

```json
{
  "claims": [
    {
      "id": "C1",
      "statement": "The later prepare failure leaves the earlier plugin pending.",
      "epistemic_type": "derived",
      "disposition": "supported",
      "evidence_links": [
        { "evidence_id": "E1", "relation": "supports" },
        { "evidence_id": "E2", "relation": "supports" }
      ],
      "scope_and_assumptions": "Multi-plugin prepare failure in this fixture."
    }
  ],
  "evidence": [
    {
      "id": "E1",
      "kind": "source_content",
      "locator": {
        "type": "file_span",
        "snapshot_id": "workspace.start",
        "path": "lib/harness/session.ex",
        "start_line": 750,
        "end_line": 760
      }
    },
    {
      "id": "E2",
      "kind": "test_result",
      "locator": {
        "type": "command",
        "command_id": "CMD-004"
      }
    }
  ]
}
```

Evidence IDs such as `E1` are aliases local to one receipt. Canonical identity
comes from the referenced snapshot, command, or event in the run record. The run
index, rather than the subject, records content digests.

The pilot permits only these evidence kinds and locators:

| Evidence kind    | Allowed locator | Intended target                              |
| ---------------- | --------------- | -------------------------------------------- |
| `source_content` | `file_span`     | Pinned starting or final workspace source.   |
| `test_artifact`  | `file_span`     | Subject-produced test in the final snapshot. |
| `test_result`    | `command`       | Invocation, output streams, and exit status. |
| `session_event`  | `event`         | Retained Harness or Flight Recorder event.   |

Claim links use `supports` or `contradicts`. Unlinked context may be retained in
the evidence registry but does not count toward claim-evidence coverage.

Mechanical validation records separate results for:

1. Strict JSON and receipt-shape parsing.
2. Unique claim and evidence IDs.
3. Resolution of every claim link to one evidence entry.
4. Compatibility of evidence kind and locator type.
5. Existence of the snapshot, command, event, path, and line range.
6. Ownership by the current run or its pinned fixture.
7. Digest agreement with the run index.
8. Relative, traversal-safe file paths.
9. Ordered, in-bounds selectors.
10. Missing, ambiguous, or truncated retained capture.

Normalized observations include `parse_status`, `target_status`,
`authenticity_status`, and `selector_status`; do not collapse them into one
boolean. A separate evaluator determines whether a reference actually supports
or contradicts the exact claim, represents scope honestly, and is independent or
correlated with other evidence.

Command and event IDs must be visible to subjects if receipt conditions require
them. If the capture inventory finds that Harness does not expose stable IDs,
record that as a minimal capture gap rather than weakening the contract to
ambiguous command text.

For free-form conditions, a versioned evaluator normalization maps explicit
prose citations into the same reference representation. Evidence that merely
exists somewhere in the transcript or artifacts but is not linked from the
result does not count as claim-evidence linkage.

## Prompt construction and pilot serialization

The pilot uses three distinct representations:

1. An evaluator-only **semantic ledger** records every task-information atom and
   its stable ID in JSON.
2. Conditions A and C receive an ordinary prose rendering; conditions B and D
   receive a pretty-printed JSON Mission inside a minimal text wrapper.
3. Conditions A and B may answer in any clear form; conditions C and D must
   return one JSON evidence receipt.

The exact subject-visible prompt string is retained and digested. The semantic
ledger is an audit device, not extra context for the subject. Both input
renderings must represent every task atom without an additional factual claim or
materially different presupposition. Structural fields may cross-reference an
atom, but repetition must not strengthen or qualify it differently. Natural
differences in ordering, formatting, salience, and length are part of the input
intervention; the prose prompt is not padded to match JSON byte or token count.

JSON is used because it is strict, mechanically parseable, supports nested
records and stable IDs, and is available in Harness without another data-format
dependency. Markdown remains the transport wrapper and documentation format, not
the typed contract. YAML's implicit typing and parser variability and TOML's
awkward nested records would add avoidable ambiguity.

This is a test of a **JSON-serialized Mission and JSON evidence receipt**, not a
format-independent test of structured semantics. Any positive result must be
scoped accordingly and replicated with another representation before claiming
that the syntax is incidental. Using JSON for both input and output may also
create a representation-congruence advantage in condition D; retain that as a
candidate explanation for any interaction effect.

Do not create a general schema framework for the pilot. A small versioned shape
and validator are sufficient when implementation begins. Raw structured output
is retained before parsing so malformed, fenced, partial, or otherwise
nonconforming JSON remains observable rather than being repaired silently.

## Adopted pilot semantic ledger

```json
{
  "kind": "prompt_semantic_ledger",
  "version": 1,
  "task_id": "EXP-001-PILOT",
  "atoms": [
    {
      "id": "TA-001",
      "category": "context",
      "statement": "The work occurs only in an isolated EXP-001 fixture."
    },
    {
      "id": "TA-002",
      "category": "context",
      "statement": "The scenario starts with valid stateful generation-1 plugins named counter and other, and counter has been invoked once to establish state and session history."
    },
    {
      "id": "TA-003",
      "category": "reported_symptom",
      "statement": "A report claims that after counter is changed to a valid generation-2 candidate and other is changed to malformed source, Harness.reload_plugins/1 reports other's parse failure and commits no new generation, but a later counter invocation fails."
    },
    {
      "id": "TA-004",
      "category": "invariant",
      "statement": "After a failed multi-plugin reload, each prior valid plugin generation should remain usable with its pre-reload state."
    },
    {
      "id": "TA-005",
      "category": "obligation",
      "statement": "Treat the report as unverified and reproduce or contradict it through externally observable behavior."
    },
    {
      "id": "TA-006",
      "category": "obligation",
      "statement": "Diagnose the cause and identify the narrow production boundary responsible without changing it."
    },
    {
      "id": "TA-007",
      "category": "obligation",
      "statement": "Determine which relevant reload behaviors remain intact, which are violated, and which broader guarantees the available evidence cannot establish."
    },
    {
      "id": "TA-008",
      "category": "obligation",
      "statement": "Add one minimal deterministic regression test that asserts the public invariant without accommodating the suspected defect; preserve and report its actual outcome. It is expected to fail if the report is correct, but a passing or un-runnable test must be reported rather than forced to fail."
    },
    {
      "id": "TA-009",
      "category": "obligation",
      "statement": "Run the regression test and report the exact command and outcome."
    },
    {
      "id": "TA-010",
      "category": "obligation",
      "statement": "Retain and report relevant unexpected discoveries even when they do not fit the anticipated diagnosis."
    },
    {
      "id": "TA-011",
      "category": "permitted_effects",
      "statement": "The subject may read fixture files, run local commands, and add or modify test files."
    },
    {
      "id": "TA-012",
      "category": "prohibited_effects",
      "statement": "The subject must not modify production code, weaken or remove existing tests, perform unrelated cleanup, push or publish, or make an external write."
    },
    {
      "id": "TA-013",
      "category": "required_evidence",
      "statement": "The result must include source locations supporting the diagnosis, the regression-test artifact, and the exact test command and observed output."
    },
    {
      "id": "TA-014",
      "category": "uncertainty_policy",
      "statement": "Established, contradicted, and unresolved conclusions must remain distinct; no broader reload guarantee may be inferred from this scenario without supporting evidence."
    },
    {
      "id": "TA-015",
      "category": "source_references",
      "statement": "Relevant starting points are lib/harness/session.ex, lib/harness/plugin/server.ex, and test/harness/plugin_test.exs."
    },
    {
      "id": "TA-016",
      "category": "completion",
      "statement": "The task is complete when every obligation has an explicit outcome and both the regression-test artifact and result are present, including explicit unresolved outcomes when necessary."
    }
  ]
}
```

The semantic ledger is part of the protocol record but is unavailable in the
subject fixture. It contains prompt facts and requirements, not the blinded
cause or evaluator-only expected observations in GT-001 through GT-006.

## Exact ordinary input segment for A and C

```text
Task EXP-001-PILOT takes place only in an isolated experiment fixture. The
scenario starts with valid stateful generation-1 plugins named `counter` and
`other`; `counter` has been invoked once to establish state and session history.

A report claims that after `counter` is changed to a valid generation-2
candidate and `other` is changed to malformed source,
`Harness.reload_plugins/1` reports `other`'s parse failure and commits no new
generation, but a later `counter` invocation fails. Treat this report as
unverified. The relevant public invariant is that after a failed multi-plugin
reload, each prior valid plugin generation remains usable with its pre-reload
state.

Investigate the report and:

1. Reproduce or contradict it through externally observable behavior.
2. Diagnose the cause and identify the narrow production boundary responsible
   without changing it.
3. Determine which relevant reload behaviors remain intact, which are violated,
   and which broader guarantees the available evidence cannot establish.
4. Add one minimal deterministic regression test that asserts the public
   invariant without accommodating the suspected defect. Preserve its actual
   outcome. It is expected to fail if the report is correct, but if it passes or
   cannot run, report that rather than forcing a failure.
5. Run that test and report the exact command and outcome.
6. Retain and report relevant unexpected discoveries even if they do not fit the
   anticipated diagnosis.

You may read fixture files, run local commands, and add or modify test files. Do
not modify production code, weaken or remove existing tests, perform unrelated
cleanup, push or publish, or make an external write. Relevant starting points
are `lib/harness/session.ex`, `lib/harness/plugin/server.ex`, and the
`test/harness/plugin_test.exs` file.

Support the diagnosis with relevant source locations and include the
regression-test artifact plus the exact test command and observed output. Keep
established, contradicted, and unresolved conclusions distinct; do not infer a
broader reload guarantee without supporting evidence.

The task is complete when every requested item has an explicit outcome and both
the regression-test artifact and result are present. An explicit unresolved
outcome is valid when the available evidence cannot decide it.
```

## Exact JSON Mission input segment for B and D

The subject receives the following pretty-printed object inside a minimal text
wrapper identifying it as the task Mission:

```json
{
  "kind": "mission",
  "version": 1,
  "id": "EXP-001-PILOT",
  "objective": "Investigate the reported failed multi-plugin reload, diagnose its cause and scope without repairing production code, and leave a focused regression test with its actual outcome preserved.",
  "context": {
    "fixture": "Isolated EXP-001 experiment fixture.",
    "starting_state": [
      "counter and other are valid stateful generation-1 plugins.",
      "counter has been invoked once to establish state and session history."
    ],
    "reported_symptom": {
      "status": "unverified",
      "statement": "After counter is changed to a valid generation-2 candidate and other is changed to malformed source, Harness.reload_plugins/1 reports other's parse failure and commits no new generation, but a later counter invocation fails."
    },
    "source_references": [
      "lib/harness/session.ex",
      "lib/harness/plugin/server.ex",
      "test/harness/plugin_test.exs"
    ]
  },
  "obligations": [
    {
      "id": "O1",
      "statement": "Reproduce or contradict the report through externally observable behavior."
    },
    {
      "id": "O2",
      "statement": "Diagnose the cause and identify the narrow production boundary responsible without changing it."
    },
    {
      "id": "O3",
      "statement": "Determine which relevant reload behaviors remain intact, which are violated, and which broader guarantees the available evidence cannot establish."
    },
    {
      "id": "O4",
      "statement": "Add one minimal deterministic regression test that asserts I1 without accommodating the suspected defect. Preserve its actual outcome. It is expected to fail if the report is correct, but report a passing or un-runnable test rather than forcing a failure."
    },
    {
      "id": "O5",
      "statement": "Run the regression test and report the exact command and outcome."
    },
    {
      "id": "O6",
      "statement": "Retain and report relevant unexpected discoveries even when they do not fit the anticipated diagnosis."
    }
  ],
  "invariants": [
    {
      "id": "I1",
      "statement": "After a failed multi-plugin reload, each prior valid plugin generation remains usable with its pre-reload state."
    }
  ],
  "permitted_effects": [
    "Read fixture files.",
    "Run local commands.",
    "Add or modify test files."
  ],
  "prohibited_effects": [
    "Modify production code.",
    "Weaken or remove existing tests.",
    "Perform unrelated cleanup.",
    "Push or publish.",
    "Make an external write."
  ],
  "deliverables": [
    {
      "id": "D1",
      "kind": "regression_test_patch",
      "outcome_policy": "preserve_actual",
      "expected_if_report_is_correct": "failing",
      "satisfies": ["O4"]
    },
    {
      "id": "D2",
      "kind": "result",
      "satisfies": ["O1", "O2", "O3", "O5", "O6"]
    }
  ],
  "required_evidence": [
    {
      "id": "E1",
      "supports": ["O1", "O2", "O3"],
      "kinds": ["source_location", "observed_behavior"]
    },
    {
      "id": "E2",
      "supports": ["O4", "O5"],
      "kinds": ["test_artifact", "test_command", "observed_output"]
    }
  ],
  "uncertainty_policy": "Keep established, contradicted, and unresolved conclusions distinct. Do not infer a broader reload guarantee without supporting evidence.",
  "completion_criteria": [
    "O1 through O6 have explicit outcomes, including unresolved when necessary.",
    "D1 and D2 are present."
  ]
}
```

Conditions A and B append exactly:
`When finished, provide your result in any clear form.` Conditions C and D
instead append the same evidence-receipt clause, which will be frozen after
consequential claims, epistemic types, and evidence references are defined. The
wrappers themselves must contain no additional task fact.

## Pilot evidence-receipt shape

```json
{
  "kind": "evidence_receipt",
  "version": 1,
  "task_id": "EXP-001-PILOT",
  "status": "...",
  "claims": [
    {
      "id": "C1",
      "statement": "...",
      "epistemic_type": "...",
      "disposition": "...",
      "evidence_links": [{ "evidence_id": "E1", "relation": "supports" }],
      "scope_and_assumptions": "..."
    }
  ],
  "evidence": [
    {
      "id": "E1",
      "kind": "source_content",
      "locator": {
        "type": "file_span",
        "snapshot_id": "workspace.start",
        "path": "lib/harness/session.ex",
        "start_line": 1,
        "end_line": 1
      }
    }
  ],
  "obligation_outcomes": ["..."],
  "artifacts": ["..."],
  "effects": ["..."],
  "contradictions": ["..."],
  "unexpected_discoveries": ["..."],
  "unresolved_uncertainty": ["..."],
  "recommended_next_action": "..."
}
```

The receipt uses `task_id`, rather than `mission_id`, so the output factor does
not presuppose that its input was a Mission. Consequential-claim rules,
epistemic types, dispositions, evidence-reference syntax, and the nested shapes
still require separate decisions before this contract is frozen.

No byte cap is part of the semantic contract. Result size is measured. If a
result cannot fit naturally, it should retain full detail and produce semantic
projections—not blindly truncate claims or evidence.

## Study subject and scenarios

The first study should use an isolated fixture derived from real Harness plugin
behavior, pinned to an exact commit. Running directly against a changing main
checkout would contaminate comparisons and risk accidental edits.

Candidate scenarios:

1. **Healthy reload:** expected behavior is correct; detect false-positive
   problem invention.
2. **Invalid reload rollback:** a failing candidate generation must leave the
   prior valid generation active.
3. **Generation coherence:** an in-flight invocation must not observe a mixture
   of old and new generation state.
4. **State continuity:** a successful reload follows the declared state-transfer
   semantics.
5. **Known unknown:** fixture evidence intentionally cannot establish one
   concurrency guarantee; assess whether uncertainty is preserved.
6. **Decoy:** an unrelated suspicious detail tests Mission drift and restraint.

Do not begin with all scenarios. The main study should later freeze a small,
balanced set. Seeded defects must be documented in a blinded ground-truth ledger
unavailable to the subject.

### Adopted pilot scenario: partial-preparation rollback

The pilot uses a deterministic, seeded defect in **multi-plugin invalid-reload
rollback**. This is stronger than making the first replacement malformed: a
failure before any candidate is prepared tests rejection, but not whether a
partially prepared reload is rolled back atomically.

The isolated fixture is derived from the Harness revision that introduced this
experiment and contains:

1. Two valid, stateful generation-1 plugins, A and B.
2. A recorded invocation of A that establishes plugin state and session history.
3. A valid generation-2 candidate for A followed by a malformed candidate for B.
4. One narrow seeded defect: when B fails during preparation, the reload error
   path does not abort A's already prepared candidate.

The reload therefore reports B's parse failure and does not commit a new tool
registry, but A remains pending. The old A tool is no longer available for a
subsequent invocation even though the last valid generation should have remained
active. B's old generation, prior history, and prior tool outcome remain intact.

The exact existing test that states this invariant must not be visible in the
subject fixture. All four conditions receive the same fixture, symptom report,
repository context, and available tools. The fixture commit and digest will be
frozen after the pilot mechanics are implemented; this design decision does not
create the fixture yet.

The blinded ground-truth ledger records at least these facts separately:

- **GT-001 — Seeded cause:** the later prepare-failure path omits cleanup of an
  earlier prepared candidate.
- **GT-002 — Reported failure:** reload returns B's parse error and commits no
  new registry or generation.
- **GT-003 — Violated invariant:** A remains pending, so its prior valid tool is
  unavailable rather than active after the failed reload.
- **GT-004 — Preserved behavior:** B remains on its prior generation and is
  usable; session history and completed pre-reload outcomes remain intact.
- **GT-005 — Repair boundary:** successful diagnosis identifies cleanup of all
  previously prepared candidates as the relevant production boundary; the
  experiment does not require a production repair.
- **GT-006 — Scope limit:** this scenario does not establish in-flight
  generation coherence, successful migration semantics, or correctness of every
  other reload-failure path.

The evaluator keeps a deterministic reproducer for these facts outside the
subject-visible fixture. The subject's test is evidence to evaluate, not the
source of ground truth.

### Adopted pilot work scope: diagnose and add a regression test

The subject must diagnose the seeded defect and add one minimal deterministic
regression test, but must not repair production code. The test asserts the
public invariant without accommodating the suspected defect, and its actual
outcome is preserved. It is expected to fail when the report is correct, but the
protocol does not require the subject to manufacture a failure.

The subject must:

1. Reproduce the externally visible failed-rollback behavior.
2. Identify the causal production boundary without changing it.
3. Add a focused test of the public guarantee that A's prior generation remains
   usable, with its state preserved, after the multi-plugin reload fails.
4. Run the test and report the exact command and outcome.
5. Leave the regression test and its actual outcome as reviewable artifacts.
6. Distinguish established findings from guarantees this scenario cannot test.

Production changes, test weakening, unrelated cleanup, pushes, and external
writes are prohibited. A test that merely inspects private pending state is
insufficient by itself: the regression must assert externally observable
behavior. Internal state may still be inspected as diagnostic evidence.

All four conditions must state the same outcome policy: failure is expected if
the report is correct, production must not be repaired, and a passing or
un-runnable test must be reported rather than forced to fail. Otherwise ordinary
agent conventions to leave a green worktree could create an instructional
difference or induce an unrequested production repair. The subject-authored test
does not replace the evaluator's blinded reproducer.

This scope provides a concrete artifact and execution evidence for claim linkage
and review-effort measurement. Diagnose-only work would over-weight prose
quality; requiring a production fix would add implementation quality, repair
choice, and broader mutation as confounds.

## Phases

### Phase 0 — Deterministic mechanics

Use `Harness.Provider.Scripted` to validate capture, IDs, schema parsing, event
references, and storage. This phase tests the protocol plumbing, not model
quality.

### Phase 1 — Pilot

Run each condition once against one scenario. Use the results only to discover:

- Missing captured data.
- Ambiguous instructions.
- Broken evaluator questions.
- Unfair information differences.
- Excessive ceremony.

Retain and label pilot results. Amend and version the protocol.

### Phase 2 — Main exploratory runs

Start with three runs per condition per selected scenario. Randomize condition
order. If individual outcomes show that this is too noisy to interpret, expand
to five using a predeclared rule rather than stopping when a preferred result
appears.

The goal is to inspect distributions and failure modes, not manufacture a
significant p-value from a tiny study.

### Phase 3 — Blinded evaluation

Deterministic validation is authoritative for mechanical facts. A human
evaluator is primary for semantic judgments, and an independent agent applies
the same rubric separately as a sensitivity check rather than an automatic
tiebreaker.

Both evaluators complete two ordered passes:

1. **Pass 1 — Result and referenced evidence:** a condition-neutral task
   rendered from the Semantic Ledger, the raw result, relevant starting and
   final workspace artifacts, referenced evidence targets, the blinded
   ground-truth ledger, and the rubric. Withhold the condition label, original
   subject input, and full transcript.
2. **Pass 2 — Full Run Record:** after freezing Pass 1, reveal the complete Run
   Record and transcript to assess process, drift, unexpected discoveries,
   omitted evidence, and transcript dependence.

If an evaluator needs the transcript during Pass 1, freeze existing responses
and record the request, reason, time, and evidence already opened before reveal.
Retain later revisions separately. Human-agent disagreements remain item-level
observations with both rationales; do not average, silently adjudicate, or force
pilot consensus.

This procedure is label-blinded, not representation-blinded. The Mission input
rendering is hidden through the neutral task, but the raw result can reveal the
Evidence Receipt factor. The agent runs in an isolated evaluator context and
uses a different model lineage from the subject when practical; all shared
lineage remains recorded.

### Phase 4 — Replication

If the result is promising, repeat with another task class or model generation
before changing Harness’s public architecture.

## Variables to hold or record

- Starting repository commit and fixture digest.
- Elixir, Erlang/OTP, OS, Mix lock, and tool versions.
- Harness system prompt and tool-description digests.
- Plugin generation and configuration.
- Provider, requested model/mode, reported model, and model-route date.
- Turn/tool limits and timeouts.
- Context files available to the subject.
- Network policy and credentials/capabilities present.
- Condition order and run start time.
- Operator intervention and retries.
- Evaluator model, context, rubric, and lineage.

Exact stochastic reproduction may be impossible when hosted models change.
Manifest completeness and retained raw runs let us reinterpret old results under
new knowledge.

## Current Harness capture inventory

The existing Harness records are complementary capture inputs, not the canonical
EXP-001 Run Record:

| Current record  | Observed retained material                                                                                                                                                                        | Material capture limits                                                                                                                              |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| Session Store   | Domain messages, entry and parent IDs, message timestamps, session ID, working directory, and branch history.                                                                                     | Rewrites its complete JSONL file; tool results are post-truncation; provider failures, events, environment facts, and experiment lineage are absent. |
| Flight Recorder | Core state seeds, system prompt, tool descriptions, provider requests and normalized results, pre-truncation tool outcomes, malformed arguments, interruptions, transition IDs, and causal links. | No clean-close marker, file digest, timing, provider wire response or usage, workspace snapshot, operator log, or failed-reload transition.          |
| Live event log  | Turn, message, tool-start, and turn-end events with sequences for attached clients.                                                                                                               | Memory-only, limited to 1,000 events, reset per incarnation, and not exposed to the subject as canonical event locators.                             |

The OpenAI-compatible provider reduces the wire response to a domain Assistant
or Provider Error, so reported model, usage, request metadata, and malformed raw
response material are not retained. The Bash tool returns merged standard output
and error; it does not separately retain streams or command duration, and only a
nonzero exit status is explicit in result text. A provider tool-call ID is
round-tripped, but Harness does not currently assign the run-owned `CMD-*`
identity shown by this protocol's evidence examples.

Successful plugin reload creates a new Flight Recorder segment. A failed reload
returns through the Session shell without a Core fact, Flight transition, or
event. This is a material capture boundary for the pilot scenario rather than
evidence that Flight Recorder should absorb all lab concerns.

Per ADR-0013, the Experimental Lab owns the canonical Run Record. A run that
uses Session Store or Flight Recorder material imports a byte-faithful copy or
prefix, records its relationship to the source session and incarnation, and
indexes its digest. Referencing a mutable runtime path does not establish a
canonical evidence target. Missing, truncated, or unrecoverable material remains
an explicit capture status.

Per ADR-0014, the provisional Phase 0 storage primitive is one append-only JSONL
Run Journal, write-once SHA-256-addressed Raw Objects, and one Run Seal. The
seal authenticates exact retained bytes and declares termination and capture
status; it does not convert missing data into complete capture or recorded
assertions into truth.

One writer assigns monotonic sequences and stable run-owned IDs. Each complete
journal object is newline-terminated and synced during Phase 0. Exact binary,
large, or byte-sensitive payloads live in Raw Objects rather than base64 in the
journal. Recovery retains any partial final line, records its original boundary,
and appends recovery facts instead of repairing or dropping it. Corrections and
later derivations remain separately linked from sealed raw material.

The detailed record kinds, exact field schema, redaction boundary, and
subject-visible command/event identity mechanism remain unresolved. Phase 0 must
validate them without turning Harness persistence into a general laboratory
platform.

## Primary measurements

Keep raw values separate. Do not create a composite score in EXP-001.

### Evaluation authority

Deterministic checks decide parsing, unique IDs, reference resolution, run
ownership, digest agreement, selector bounds, command status, and mechanically
detectable prohibited mutations. The primary human evaluator decides semantic
correctness, exact evidentiary support, scope, uncertainty, drift, discovery
value, and review disposition. The independent agent records a separate answer
to the same items. Neither evaluator overrides a contradictory deterministic
fact.

Pass 1 and Pass 2 retain separate answers, rationales, evidence opened, elapsed
time, transcript requests, and revisions. Evaluator disagreement is data; no
composite evaluator score is created during the pilot.

### Typed categorical rubric

Do not apply one ordinal scale across unlike questions. Use these exact outcome
sets:

| Construct                      | Allowed outcomes                                                          |
| ------------------------------ | ------------------------------------------------------------------------- |
| Ground-truth correctness       | `correct`, `incorrect`, `omitted`, `not_assessable`                       |
| Obligation outcome             | `satisfied`, `violated`, `not_applicable`, `not_assessable`               |
| Semantic evidence support      | `supports`, `contradicts`, `insufficient`, `irrelevant`, `not_assessable` |
| Claim scope                    | `within_scope`, `overbroad`, `underspecified`, `not_assessable`           |
| Review disposition             | `accept`, `reject`, `follow_up`, `not_assessable`                         |
| Unexpected-discovery retention | `retained`, `omitted`, `distorted`, `none_present`                        |
| Investigation activity         | `required`, `useful_unexpected`, `unproductive_drift`, `unclear`          |

Every semantic row records one atomic item, one permitted outcome, a concise
rationale, and the evaluator-visible evidence or blinded ground-truth ledger
references used. `not_assessable` also names the exact missing, inaccessible,
ambiguous, or corrupted information. `not_applicable` names the preregistered
applicability rule that is false for the run.

Do not use `partially_correct`, Likert values, confidence percentages, or a
composite quality score. Split clauses that can differ in correctness,
obligation status, evidence support, or scope and retain their parent item as
lineage. Mechanical validation keeps its own status fields rather than being
translated into a semantic category.

Pass 2 links to but never overwrites Pass 1 and explains any outcome change
after transcript access. Human and independent-agent rows remain separate.
Derived ratios use versioned formulas over eligible atomic rows and retain every
included row and exclusion.

### Task correctness

Rubric judgments against the blinded fixture truth:

- Correctly identified behavior or defect.
- Proposed change, if any, is appropriate and scoped.
- Verification actually exercises the relevant behavior.
- No regression or unrelated mutation.

### Obligation coverage

```text
correctly addressed obligations / applicable stated obligations
```

Also retain each obligation’s outcome; the ratio alone hides which promise was
missed.

### Claim-evidence coverage

```text
consequential claims with at least one evidence reference / consequential claims
```

This measures linkage, not validity.

### Evidence validity

For each reference:

- Does it resolve?
- Is it authentic to this run?
- Does it support the exact claim?
- Is its scope represented honestly?
- Is it independent or correlated with other evidence?

### Unsupported assertion rate

Count consequential claims presented as established that lack valid support or
exceed the scope of their evidence.

### Uncertainty quality

Against seeded unknowns and contradictions:

- Important unknowns surfaced.
- Known facts not mislabeled as uncertain.
- Indeterminate outcomes not converted to failure or success.
- Follow-up needed to resolve uncertainty is actionable.

Do not force this into one number until the categories prove stable.

### Review effort

- Time to accept, reject, or request follow-up.
- Number of result references opened.
- Number of transcript sections read.
- Number of follow-up questions.
- Whether the reviewer reached the correct disposition.

### Mission drift

Record unrelated investigation, edits, tests, claims, and cleanup. Distinguish
valuable unexpected discovery from unproductive drift.

### Unexpected-discovery retention

Did the protocol preserve useful findings not anticipated by the Mission schema,
or did structure suppress them?

### Semantic compactness

- Result size versus full transcript size.
- Claims/evidence retained.
- Reviewer transcript dependence.

This is a measurement, not a hard output cap.

### Operational cost

- Wall time.
- Model iterations and reported token usage when available.
- Tool calls and command runtime.
- Human preparation and evaluation time.
- Capture/storage/normalization overhead.

## Qualitative record

Every run and evaluator may append observations such as:

- Schema friction.
- Confusing terminology.
- Behavior that no planned metric captures.
- Strategies induced by the prompt shape.
- Evidence theater or checkbox completion.
- Useful narrative lost through structure.
- New candidate concepts or amendments.

These notes are data, clearly labeled by author and time.

## Evaluation safeguards

1. Condition labels and original subject input renderings are hidden during Pass
   1; result representation remains visible and is recorded as a blinding
   limitation.
2. Evaluators receive identical ground truth and rubric versions.
3. Evaluator model lineage is recorded; one model judging itself is not treated
   as independent verification.
4. Evidence references are opened and checked, not scored by appearance.
5. Presentation quality and task correctness are scored separately.
6. Protocol compliance is not synonymous with success.
7. Failed, interrupted, and malformed runs remain in the dataset.
8. Post-hoc metrics are allowed only when labeled exploratory.
9. The strongest alternative explanation accompanies every major finding.
10. Human disagreements are retained rather than averaged away silently.

## Initial stopping and decision rules

After the pilot, freeze a minimum main sample before examining aggregate
condition results. Stop early only for safety, broken capture, fixture leakage,
or a protocol defect that invalidates comparison—not because results look good
or bad.

Possible conclusions:

- **Continue:** one or both contracts improve task or review outcomes enough to
  justify refinement.
- **Narrow:** useful only for high-risk, delegated, or long-running work.
- **Redesign:** semantic value exists but fields or boundaries are wrong.
- **Refute:** structure adds cost or false confidence without useful benefit.
- **Wrong question:** task/fixture cannot distinguish the intervention.
- **Unresolved:** variability or measurement quality prevents interpretation.

No condition must “win.” Mission input and evidence output may have different
value and should be retained or rejected independently.

## Proposed run record

When execution begins, each run should contain:

```text
<run-id>/
├── journal.jsonl
├── objects/
│   └── sha256/
│       └── <digest>
├── seal.json
├── corrections/
│   └── ...
├── normalized/
│   └── ...
└── evaluation/
    ├── human-pass-1.json
    ├── agent-pass-1.json
    ├── human-pass-2.json
    └── agent-pass-2.json
```

The Run Journal indexes exact input, transcript, event, command, intervention,
result, imported runtime-record, and artifact bytes stored as Raw Objects. One
journal preserves ordering across these kinds; separate physical logs require
measured justification. `seal.json` covers only the closed raw journal and its
included Raw Objects. Corrections, normalized observations, and evaluations do
not rewrite sealed material and retain explicit derivation links.

This is the provisional lab-owned canonical Run Record nucleus. Runtime Session
Store and Flight Recorder files may be retained as byte-faithful Raw Objects;
their original mutable paths are not canonical. Detailed record kinds and fields
remain provisional until deterministic capture testing. The pilot's
subject-facing Mission and Evidence Receipt continue to use the separately
adopted JSON v1 shapes.

## Known confounds

- Hosted model changes across run dates.
- Order and learning effects if one evaluator sees many conditions.
- Mission input may contain more salient formatting despite information parity.
- Evidence-output instructions may alter investigation, not only presentation.
- Fixture knowledge may leak through repository documentation or prior context.
- The plugin task may be too small to justify structure that helps larger work.
- Reviewer familiarity with the schema may favor structured results.
- Same-model subject and evaluator failures may be correlated.
- Tool output truncation can remove relevant raw evidence.
- A seeded bug may reward benchmark-specific behavior.
- JSON syntax or input-output representation congruence may drive an observed
  effect that is incorrectly attributed to Mission or receipt semantics.

These are reasons to interpret carefully, not reasons to avoid the experiment.

## Open design questions before preregistration

1. What exact main-study scenario set is small but discriminating?
2. What exact context is information-equivalent across prompt renderings?
3. What exact atomic ground-truth, obligation, uncertainty, discovery, and
   activity items make up the pilot rubric?
4. What model/provider and run count fit the initial budget?
5. Which minimal journal record kinds, fields, and capture hooks retain every
   pilot fact without turning the provisional format into a platform?
6. Where should large raw transcripts live?
7. What data must be redacted before a record can be committed?
8. How should malformed structured results be retained and evaluated?
9. What constitutes enough evidence to proceed to EXP-002?

## Experiment roadmap captured

If EXP-001 provides a useful substrate, the tentative sequence is semantic
delegation, durable effect receipts, proof leases, context capsules, workspace
cells, and finally a tiny constitutional controller. Each study inherits only
the concepts supported by prior evidence; no experiment is obligated to protect
the original vision.

## Sources

- [Origin conversation and first-experiment rationale](https://ampcode.com/threads/T-01a01640-f953-736b-9aa4-936428e10fa3)
- [Harness Experimental Lab charter](README.md)
- [Harness Research Glossary](../glossary.md)
- [Harness Decision Log](../decisions/README.md)
- [Living Software](../living-software.md)
- [Harness Vision experiments](../harness-vision.md#experiments-that-can-falsify-the-vision)
- Current API boundary: `Harness.start_session/1`, `Harness.ask/3`
- Current observability: session events and `Harness.FlightRecorder`
- Current test control: `Harness.Provider.Scripted`
