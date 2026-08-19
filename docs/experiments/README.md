# Harness Experimental Lab

> **Status:** Draft lab charter  
> **Updated:** August 2026  
> **Purpose:** Establish a repeatable, traceable, and revisable method for
> testing the Harness and living-software hypotheses.

The lab exists to turn provocative ideas into evidence without prematurely
turning them into doctrine or production architecture. It is deliberately small
at first. The process, schemas, and storage model should evolve when experiments
show that they are wrong or burdensome.

The first study is [EXP-001: Mission Receipt](001-mission-receipt.md). The
[Harness Research Glossary](../glossary.md) is the canonical working vocabulary
for lab protocols and records. The
[Harness Decision Log](../decisions/README.md) records consequential choices,
rationale, alternatives, and revisit triggers.

## Research posture

1. **Preserve before interpreting.** Raw prompts, outputs, events, artifacts,
   failures, and environment facts are retained before analysis.
2. **Negative results are results.** Refutation, ambiguity, model failure,
   protocol friction, and “wrong question” outcomes are first-class.
3. **Separate observation from judgment.** Raw observations, normalized
   measures, interpretations, and decisions are distinct records.
4. **Prefer falsifiable questions.** Every experiment states what result would
   weaken or refute its hypothesis.
5. **Change the method explicitly.** Protocol amendments are versioned and never
   silently rewritten after seeing results.
6. **Avoid premature aggregation.** Preserve individual measurements rather than
   hiding tradeoffs behind one score.
7. **Reproduce conditions, not stochastic outputs.** Model responses may not be
   byte-identical; inputs, environment, lineage, and evaluation must be
   reconstructable.
8. **Start with semantic contracts.** Validate Mission, evidence, effect, and
   uncertainty concepts on one node before distributed infrastructure.
9. **Keep escape hatches.** Free-form discoveries that do not fit a schema must
   remain capturable.
10. **Treat the lab as an experiment.** Its own ceremony, cost, and blind spots
    are measured and open to removal.
11. **Version the language.** Semantically important terms use the canonical
    glossary. A protocol pins its glossary revision and declares any scoped
    narrowing rather than silently changing a definition.
12. **Retain decisions, not only conclusions.** Consequential choices receive a
    stable ADR that records context, rationale, rejected alternatives,
    consequences, provenance, and revisit triggers.

All data deserves preservation at this exploratory stage, but not all data has
equal evidentiary weight. A model assertion, a deterministic test, a production
observation, and a human judgment can all matter while supporting different
kinds of conclusions. **Equal right to retention does not mean equal proof.**

## Experiment lifecycle

```text
Proposed
   │ research question
   ▼
Pre-registered
   │ protocol, measures, stopping rules frozen
   ▼
Pilot
   │ validate mechanics; results excluded from main comparison
   ▼
Running
   │ immutable raw capture
   ▼
Analyzing
   │ normalized measures + blinded evaluation
   ▼
Concluded
   │ supported · unresolved · refuted · wrong question
   ▼
Replicated / Superseded
```

An experiment may move backward only through an explicit amendment. Pilot data
is retained but labeled; it must not be quietly mixed into the main sample.

## Record layers

### 1. Source and protocol

What we intended to test:

- Research question and competing hypotheses.
- Source conversations, papers, repository facts, and prior experiments.
- Protocol version and amendments.
- Conditions, controls, measures, and stopping rules.
- Fixture and evaluator definitions.

### 2. Immutable raw record

What happened:

- Exact input and system/context material available to the subject.
- Complete model and tool transcript.
- Harness events and Flight Recorder references.
- Standard output, standard error, exit status, and timing.
- Produced files and artifact digests.
- Environment and implementation manifest.
- Failures, interruptions, retries, and operator interventions.

Raw records are append-only. Corrections create a linked note; they do not edit
history.

### 3. Normalized observations

Facts derived reproducibly from raw records:

- Claim and obligation mappings.
- Evidence-reference validation.
- Timing, token, tool, and artifact counts.
- Rubric responses.
- Reviewer interactions and transcript dependence.

Derivation scripts and versions are part of the record.

### 4. Interpretation and decision

What we think the observations mean:

- Findings and plausible competing explanations.
- Confounds and limitations.
- Unexpected discoveries.
- Whether a hypothesis was supported, unresolved, or weakened.
- What to retain, change, remove, or test next.

Conclusions never overwrite raw or normalized data.

## Provenance model

Every experiment, run, artifact, claim, evaluation, and conclusion receives a
stable ID.

```text
EXP-001                         experiment
EXP-001-P2                     protocol version 2
EXP-001-RUN-20260820-004       run
EXP-001-ART-...                artifact
EXP-001-EVAL-...               evaluation
EXP-001-FIND-...               finding
ADR-0005                       governing decision
```

Each run manifest should eventually include:

```text
experiment_id
protocol_version
glossary_commit
governing_decision_ids
condition_id
scenario_id
run_id
parent/source thread URLs
repository URL, branch, starting commit, dirty-state digest
fixture and task versions
Harness commit and configuration digest
provider, requested model/mode, reported model when available
system prompt, plugin, and tool-description digests
Elixir/OTP/OS/toolchain versions
environment and relevant dependency lock digests
start/end time and termination reason
randomization position
operator interventions
raw-record and artifact digests
```

Secrets and personal data are never captured merely for completeness. The
manifest records that a secret capability existed, not its value.

## Source traceability

Each experiment maintains a source ledger. Sources can include:

- Amp thread URLs and the specific question or decision extracted from them.
- Repository commits and file/line ranges.
- External papers, documentation, issues, and articles with retrieval date.
- Prior experiment IDs, run IDs, findings, and artifacts.
- Human assertions labeled as assertions rather than external facts.

A finding cites raw run IDs and source IDs. A conclusion cites findings. A later
ADR cites the conclusion or states why it diverges. Protocols cite their
governing ADRs. This creates the chain:

```text
conversation / paper / code
          │
          ▼
  ADR ──▶ experiment hypothesis ──▶ protocol ──▶ raw runs
   ▲                                             │
   │                                             ▼
   │                                     normalized findings
   │                                             │
   └──────────── retained or superseded ◀────────┘
```

## Proposed repository shape

Do not create every directory until a real artifact needs it. The intended shape
is:

```text
docs/
├── glossary.md                       canonical research vocabulary
├── decisions/                        canonical decision records
│   └── README.md                     ADR index and process
└── experiments/
    ├── README.md                     lab charter
    └── 001-mission-receipt.md        current design and preregistration

experiments/                          created when execution begins
└── EXP-001-mission-receipt/
    ├── protocol/
    ├── fixtures/
    ├── runs/
    │   └── <run-id>/
    │       ├── manifest.json
    │       ├── input/
    │       ├── raw/
    │       ├── artifacts/
    │       └── evaluation/
    ├── analysis/
    └── reports/
```

Git should retain protocols, small raw records, manifests, derived data,
analysis, and conclusions. If raw transcripts or artifacts become large, store
them content-addressably outside ordinary Git and commit their digests plus a
retrieval reference. Never silently omit a large failed run because storage is
inconvenient.

Markdown and JSON are canonical initially. Human HTML reports should eventually
be generated from the canonical records rather than maintained as a second
manual source that can drift.

## Standard experiment workflow

1. **Frame:** state the question, why it matters, alternatives, and failure
   conditions.
2. **Source:** build the provenance ledger before running anything.
3. **Operationalize:** define variables, scenarios, measures, and evaluators.
4. **Pre-register:** freeze the main protocol and stopping rule in a commit.
5. **Pilot:** verify capture and rubric mechanics; revise explicitly.
6. **Freeze fixtures:** digest the task, code, environment, and expected facts.
7. **Randomize and run:** use clean environments and capture all interventions.
8. **Blind-evaluate:** hide condition identity and transcript where the question
   permits it.
9. **Normalize:** derive metrics using versioned scripts.
10. **Interpret adversarially:** record the strongest alternative explanation.
11. **Conclude:** supported, unresolved, refuted, wrong question, or useful only
    under stated conditions.
12. **Decide:** continue, modify, replicate, stop, or split the hypothesis.

## Measurement rules

- Record raw components; do not begin with one composite “quality” score.
- Define every metric before the main run and preserve its formula/version.
- Measure protocol overhead as well as benefit.
- Separate task correctness from result presentation quality.
- Record missing data rather than imputing convenient values.
- Keep qualitative surprises alongside planned quantitative measures.
- Use paired or randomized conditions where practical.
- Treat model/version drift and correlated evaluators as explicit confounds.
- Report distributions and individual runs before averages.
- A schema field being filled is not evidence that its content is valid.

## From lab records to tests and evals

Captured data has several possible uses that must not be conflated:

1. **Exploratory record:** preserves what happened, including malformed and
   failed runs. It is evidence about the experiment but not automatically a good
   benchmark case.
2. **Development example:** helps design prompts, schemas, tools, and metrics.
   Once designers or subjects have seen it, assume contamination.
3. **Regression case:** freezes a discovered failure or invariant into a
   deterministic or model-based test. Repeated exposure is expected.
4. **Evaluation case:** estimates behavior on unseen work. Its ground truth and
   scoring details must remain held out from the subject and from prompt/tool
   design where practical.

A run may be promoted only through a recorded curation decision. Promotion
preserves the original run ID, source lineage, license/privacy status, ground
truth method, known contamination, and dataset split.

```text
raw run ──curation──▶ development example
   │
   ├──curation──▶ regression case
   │
   └──independent fixture design──▶ held-out eval case
```

Experiment fixtures that we inspect are not later described as unseen evals.
Datasets receive versions and immutable membership manifests. Changes to labels,
rubrics, or ground truth create a new version rather than silently altering past
scores. Model and evaluator exposure is recorded because contamination can occur
through prompts, transcripts, generated documentation, and repeated agent
use—not only training data.

The lab should eventually maintain at least three explicit splits:

- **Development:** visible and reusable while inventing the system.
- **Regression:** stable cases that protect specific learned behavior.
- **Held-out:** minimally exposed cases reserved for comparative evaluation.

This means “capture too much” is compatible with rigorous evaluation, provided
retention does not imply indiscriminate reuse.

## Initial experiment sequence

1. **EXP-001 — Mission Receipt:** typed Mission input and evidence-carrying
   result around plugin hot reload.
2. **EXP-002 — Semantic Delegation:** separate child context with a retained,
   semantically compressed result.
3. **EXP-003 — Effect Receipt:** stable mutation identity, crash injection, and
   explicit indeterminacy.
4. **EXP-004 — Proof Lease:** causal invalidation of evidence when assumptions
   change.
5. **EXP-005 — Context Capsule:** provenance, least context, authority, and
   contamination boundaries.
6. **EXP-006 — Workspace Cell Contract:** one Mission across local and remote
   executors.
7. **EXP-007 — Tiny Constitutional Controller:** observation → contradiction →
   Mission → evidence → satisfaction or amendment proposal.

This sequence is a hypothesis, not a roadmap commitment. Each conclusion may
reorder, remove, or redefine what follows.

## Origin

- [Harness vision and experiment discussion](https://ampcode.com/threads/T-01a01640-f953-736b-9aa4-936428e10fa3)
- [Living Software](../living-software.md)
- [Harness Vision](../harness-vision.md)
