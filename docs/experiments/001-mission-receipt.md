# EXP-001: Mission Receipt

> **Status:** Design draft; not pre-registered  
> **Protocol version:** 0  
> **Updated:** August 2026  
> **System under study:** Harness operating on its plugin hot-reload behavior

This document designs the first Harness lab experiment. Nothing here is frozen.
The design should change before preregistration whenever a clearer question,
fairer control, or more useful measure emerges.

See the [lab charter](README.md) for provenance and data-handling rules.

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

## Mission draft

```text
Mission
├── id
├── objective
├── obligations
├── invariants
├── context and source references
├── permitted and prohibited effects
├── deliverables
├── required evidence
├── uncertainty policy
└── completion criteria
```

Candidate content:

```text
Objective
  Verify plugin hot-reload correctness and identify any unsupported guarantee.

Obligations
  Reloaded tools become available to subsequent turns.
  Existing session history remains intact.
  In-flight calls retain one coherent plugin generation.

Invariants
  A session never observes a partially installed generation.
  Failed reload preserves the last valid generation.
  State transitions remain attributable to one generation.

Permitted effects
  Read and modify the isolated fixture checkout.
  Run targeted tests and local commands.

Prohibited effects
  No push, publication, external write, or unrelated cleanup.

Required evidence
  Relevant tests and their exact outcomes.
  Observed generation/state behavior.
  Reload failure behavior.
  File or event references for consequential claims.

Completion
  Every obligation is supported, contradicted, or explicitly unresolved.
```

This is a starting representation, not a proposed public API.

## Evidence-carrying result draft

```text
MissionResult
├── mission_id
├── status
├── claims[]
│   ├── stable claim ID
│   ├── statement
│   ├── epistemic type
│   ├── evidence references
│   ├── scope and assumptions
│   └── supporting · contradicted · unresolved
├── obligation outcomes[]
├── artifacts[]
├── effects[]
├── contradictions[]
├── unexpected discoveries[]
├── unresolved uncertainty[]
└── recommended next action
```

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

Do not begin with all scenarios. Select one representative scenario for the
pilot, then freeze a small balanced set for the main run. Seeded defects must be
documented in a blinded ground-truth ledger unavailable to the subject.

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

The evaluator initially receives the task, result, and produced artifacts—but
not the condition label or full transcript. Record when it must request the
transcript. A second pass may inspect the complete run to evaluate process and
missed discoveries.

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

## Primary measurements

Keep raw values separate. Do not create a composite score in EXP-001.

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

1. Condition labels are hidden during primary review.
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
├── manifest.json
├── input/
│   ├── task.md
│   ├── system-context.digest
│   └── condition.json
├── raw/
│   ├── transcript.jsonl
│   ├── events.jsonl
│   ├── commands.jsonl
│   └── operator-log.jsonl
├── artifacts/
│   ├── index.json
│   └── ...
├── result/
│   ├── raw.txt
│   └── normalized.json
└── evaluation/
    ├── blind-review.json
    └── full-review.json
```

Formats remain provisional until the deterministic phase proves what Harness can
capture without invasive implementation.

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

These are reasons to interpret carefully, not reasons to avoid the experiment.

## Open design questions before preregistration

1. What exact scenario set is small but discriminating?
2. Should the subject diagnose only, or diagnose and modify?
3. What qualifies as a consequential claim?
4. Which epistemic types are useful without becoming ceremonial?
5. How are evidence references represented and mechanically validated?
6. What context is information-equivalent across prompt formats?
7. Which evaluator should establish the primary disposition?
8. What model/provider and run count fit the initial budget?
9. Where should large raw transcripts live?
10. What data must be redacted before a record can be committed?
11. How should malformed structured results be retained and evaluated?
12. What constitutes enough evidence to proceed to EXP-002?

## Experiment roadmap captured

If EXP-001 provides a useful substrate, the tentative sequence is semantic
delegation, durable effect receipts, proof leases, context capsules, workspace
cells, and finally a tiny constitutional controller. Each study inherits only
the concepts supported by prior evidence; no experiment is obligated to protect
the original vision.

## Sources

- [Origin conversation and first-experiment rationale](https://ampcode.com/threads/T-01a01640-f953-736b-9aa4-936428e10fa3)
- [Harness Experimental Lab charter](README.md)
- [Living Software](../living-software.md)
- [Harness Vision experiments](../harness-vision.md#experiments-that-can-falsify-the-vision)
- Current API boundary: `Harness.start_session/1`, `Harness.ask/3`
- Current observability: session events and `Harness.FlightRecorder`
- Current test control: `Harness.Provider.Scripted`
