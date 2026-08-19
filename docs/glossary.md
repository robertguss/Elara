# Harness Research Glossary

> **Status:** Canonical working vocabulary
>
> **Updated:** August 2026
>
> **Scope:** Harness research, experimental protocols, run records, evaluation,
> and the execution environments discussed by those records.

This glossary is the repository source of truth for semantically important terms
used by the Harness Experimental Lab. “Canonical” means the current default
definition, not permanent truth. Definitions remain revisable when evidence
shows that they are ambiguous, incomplete, or unhelpful.

## Canonicality and versioning rules

1. Git is canonical. A statement in an Amp thread, Harness Session, run, or orb
   is exploratory until it is recorded in a versioned repository document.
2. Every preregistered protocol records the glossary Git commit it uses. Runs
   remain interpreted under that pinned revision even when the glossary later
   changes.
3. A protocol may narrow a definition for its own scope only by citing the term
   and stating the delta explicitly. It must not silently redefine a term.
4. A semantic change creates a commit and, after preregistration, a protocol
   amendment. Git history preserves superseded meanings.
5. Stable machine values use the `snake_case` key shown with each definition.
   Human prose uses the displayed term. Mission and Evidence-Carrying Result are
   capitalized when referring to the semantic contracts rather than generic
   English words.
6. Add a term before preregistration when its meaning can change a hypothesis,
   permission, state transition, measurement, evaluation, or conclusion. Do not
   bureaucratize ordinary words that carry no protocol-specific meaning.
7. Definitions standardize communication; they do not upgrade an assertion into
   evidence or forbid an experiment from discovering a better vocabulary.

## Execution and provenance

### Amp thread

**Key:** `amp_thread`

A conversation and work record managed by Amp. An Amp thread can motivate or
perform research, but it is not a Harness Session, experiment run, fixture, or
canonical protocol. Cite it by full URL and identify the extracted decision or
assertion.

### Harness Session

**Key:** `harness_session`

A Harness-owned model-and-tool interaction lifecycle represented by a Harness
session identity and transcript. A Harness Session may be used by one experiment
run. Do not shorten this to “thread” when confusion with an Amp thread is
possible.

### Orb

**Key:** `orb`

An Amp sandboxed execution environment that can host a repository checkout,
processes, and artifacts. An orb is an environment, not a session, subject,
experiment, or durable source of truth.

### Workspace

**Key:** `workspace`

The filesystem and execution context made available for work. A workspace may
contain a fixture checkout. Its identity includes the relevant base revision,
dirty state, and environment facts.

### Run

**Key:** `run`

One attempted execution of one protocol version, condition, and scenario,
including malformed, interrupted, failed, or otherwise unexpected termination. A
retry is a new linked run unless the protocol explicitly defines it as the same
transport attempt.

### Run record

**Key:** `run_record`

The canonical, run-owned collection that links one attempted Run to its source
and protocol references, immutable raw records, artifacts, normalized
observations, evaluations, and later interpretations. Runtime session stores and
recordings may be imported as raw objects, but their mutable original locations
are not the experimental source of truth. Missing or partial capture remains an
explicit part of the Run Record.

### Run journal

**Key:** `run_journal`

The single-writer, append-only ordered record of raw facts captured during one
Run. In EXP-001 it is a JSONL file whose complete records are newline-terminated
JSON objects with stable run-owned identities. A partial final line is retained
as partial capture rather than silently discarded or repaired.

### Run seal

**Key:** `run_seal`

A write-once record created after a Run Journal is closed normally or recovered.
It identifies the exact journal bytes and included Raw Objects by digest and
declares termination and capture status. A valid seal establishes integrity of
the retained bytes; it does not prove their assertions or imply that capture was
complete.

### Artifact

**Key:** `artifact`

A retained output produced or selected by work, such as a patch, test file,
report, recording, or generated dataset. An artifact is not evidence merely
because it exists; its evidentiary relevance must be established.

### Effect

**Key:** `effect`

A mutation of state outside the model's text generation, including filesystem,
process, network, service, or external-system changes. Reading is an interaction
but not normally an effect unless the protocol treats access itself as
consequential.

### Provenance

**Key:** `provenance`

The reconstructable lineage connecting a record to its sources, producer,
protocol, environment, model, tools, code revisions, parent records, and later
uses. Provenance describes origin and transformation; it does not establish
truth by itself.

### Source ledger

**Key:** `source_ledger`

A versioned index of conversations, code, commits, papers, documentation, human
assertions, and prior experimental records used to motivate or interpret an
experiment. Each entry states what was extracted rather than citing a source
only by name.

### Architecture Decision Record

**Key:** `architecture_decision_record`

A small, versioned record of one consequential research or design choice,
including context, decision, rationale, alternatives, consequences, revisit
triggers, and provenance. “Architecture” includes experimental and semantic
decisions whose consequences extend beyond a routine edit.

### Decision log

**Key:** `decision_log`

The canonical index and set of Architecture Decision Records under
`docs/decisions/`. A changed decision is represented by a superseding record;
the prior context and rationale remain available.

### Revisit trigger

**Key:** `revisit_trigger`

A predeclared observation, cost, failure mode, or changed condition that should
cause a decision to be reconsidered. A trigger requires review, not automatic
reversal.

## Experimental method

### Experiment

**Key:** `experiment`

A versioned investigation of a stated question using declared factors,
conditions, scenarios, measurements, and decision rules. An experiment can end
supported, weakened, unresolved, refuted, or judged to ask the wrong question.

### Protocol

**Key:** `protocol`

The versioned specification of how an experiment is framed, executed, captured,
evaluated, and stopped. A protocol includes its prompts, fixtures, variables,
ground-truth method, measurements, randomization, and amendment rules.

### Preregistration

**Key:** `preregistration`

The commit that freezes the protocol, primary measurements, exclusions, sample,
and stopping rules before main comparative results are examined. A design draft
or pilot plan is not preregistered merely because it is committed.

### Protocol amendment

**Key:** `protocol_amendment`

A versioned, reasoned change to a protocol. It states what changed, why, which
data had already been observed, and which runs use each version. It never edits
past run records or silently mixes incompatible samples.

### Factor

**Key:** `factor`

An intentionally varied experimental input whose effect is being investigated.
EXP-001 has an input-contract factor and an output-contract factor.

### Condition

**Key:** `condition`

One declared combination of factor levels. A condition is assigned before a run
and hidden from evaluators when the protocol requires blinding.

### Scenario

**Key:** `scenario`

The task situation exercised by a run: initial state, reported behavior,
available actions, and relevant unknowns. Multiple conditions may operate on
information-equivalent renderings of the same scenario.

### Fixture

**Key:** `fixture`

A pinned, isolated, reproducible implementation of a scenario, including code,
test support, seeded state or defect, and a digest. Subject-visible fixture
content is distinct from evaluator-only ground truth.

### Subject

**Key:** `subject`

The model-and-Harness configuration whose behavior is under study in a run.
“Subject” does not refer to the human evaluator, operator, orb, or fixture.

### Evaluator

**Key:** `evaluator`

A human or model applying the preregistered rubric to task inputs, results, and
allowed artifacts. Evaluator identity, context, model lineage, and access to the
transcript are recorded.

### Reviewer

**Key:** `reviewer`

A person or agent deciding whether a work result should be accepted, rejected,
or sent for follow-up. A reviewer may also act as an evaluator, but the two
roles and their criteria remain distinguishable.

### Verifier

**Key:** `verifier`

A person, agent, or deterministic mechanism that independently checks a claim or
artifact. Verification produces evidence; evaluation applies a study rubric;
review makes an acceptance decision.

### Pilot

**Key:** `pilot`

Runs used to validate fixture, capture, prompt, parsing, and rubric mechanics
before the main comparison. Pilot records are retained and labeled but excluded
from the main comparative sample.

### Manipulation check

**Key:** `manipulation_check`

A protocol observation testing whether a run received or complied with its
assigned experimental intervention, such as whether a required structured result
parsed as the assigned Evidence Receipt. A manipulation check establishes
condition conformance, not task correctness or intervention benefit. Because it
may differ by condition, it is not silently added to a shared outcome
denominator.

### Reproduction

**Key:** `reproduction`

Re-exercising a reported behavior or prior result under materially the same
fixture and conditions. For stochastic models, reproduce reconstructable
conditions rather than byte-identical output.

### Replication

**Key:** `replication`

Repeating the research question under a meaningfully different scenario, task
class, model generation, representation, or environment to test whether a
finding generalizes. Repetition on the same fixture is reproduction, not strong
replication.

### Blinded evaluation

**Key:** `blinded_evaluation`

Evaluation in which declared information that could bias judgment—such as
condition label or persuasive transcript—is withheld for the specified pass.
Blinding is defined by what the evaluator can access, not by intent alone.

### Label-blinded evaluation

**Key:** `label_blinded_evaluation`

A Blinded Evaluation that withholds the explicit condition label and original
input rendering while retaining the subject's raw result. It does not claim
representation blinding when the result's prose or structured form can reveal a
treatment factor.

### Independent-agent evaluation

**Key:** `independent_agent_evaluation`

An isolated agent application of the same versioned evaluator packet and rubric,
retained separately from the human evaluation. Record model lineage, context,
tools, and shared dependencies. “Independent” describes procedural separation;
it does not imply uncorrelated errors, primary authority, or automatic
adjudication.

### Rubric outcome

**Key:** `rubric_outcome`

One typed categorical answer to one atomic evaluator item. Its allowed values
depend on whether the item evaluates correctness, an obligation, evidence,
scope, review disposition, discovery retention, or investigation activity. It
does not replace the required rationale or references and is not a numeric
score.

### Correct

**Key:** `correct`

The subject result agrees with the relevant atomic blinded ground-truth ledger
fact at its stated scope and contains no materially incompatible answer to that
item. Correctness does not establish that the subject supplied valid evidence.

### Incorrect

**Key:** `incorrect`

The subject result gives an answer materially incompatible with the relevant
atomic blinded ground-truth ledger fact. Use `omitted`, not `incorrect`, when
the result does not answer the item at all.

### Omitted

**Key:** `omitted`

An applicable expected item is absent from the result. For correctness it means
the result did not address the atomic fact; for discovery retention it means a
useful unexpected discovery visible in the full Run Record was not retained in
the result. Omission is distinct from an explicit incompatible assertion.

### Not assessable

**Key:** `not_assessable`

The evaluator packet lacks, cannot resolve, or cannot reliably recover the
specific information required to judge an otherwise applicable item. The
evaluator records that missing or corrupted information. This is an evaluator
state, not the subject's `unresolved` claim disposition and not permission to
avoid a difficult judgment.

### Satisfied

**Key:** `satisfied`

The subject fulfills one applicable atomic obligation under its declared
completion criteria. Mentioning the obligation without doing or delivering what
it requires is not satisfied.

### Violated

**Key:** `violated`

The subject fails one applicable atomic obligation, including by omitting a
required action or deliverable, performing a prohibited action, or producing an
outcome incompatible with the obligation's criteria.

### Not applicable

**Key:** `not_applicable`

A preregistered applicability rule establishes that an obligation does not apply
to this run. The evaluator identifies that rule. Difficulty, failure, missing
data, or subject omission does not make an applicable obligation inapplicable.

### Supports

**Key:** `supports`

The evaluator finds that the referenced evidence materially increases warrant
for the exact claim at its stated scope and assumptions. This is a semantic
Evidence Link assessment; it does not mean universal proof or mechanical
reference validity by itself.

### Contradicts

**Key:** `contradicts`

The evaluator finds that the referenced evidence materially supports an
incompatible conclusion or the exact claim's negation at the relevant scope.
This is an Evidence Link relationship, distinct from the claim-level
`contradicted` disposition.

### Insufficient

**Key:** `insufficient`

The referenced evidence bears on the claim but lacks the strength, coverage,
independence, or scope needed to support or contradict it as stated.
Insufficient evidence is relevant; use `irrelevant` when it has no material
bearing.

### Irrelevant

**Key:** `irrelevant`

The referenced evidence has no material bearing on whether the exact claim is
true at its stated scope. A valid locator can still reference irrelevant
evidence.

### Within scope

**Key:** `within_scope`

The claim's stated breadth and assumptions do not exceed what its valid evidence
and the exercised scenario can establish. Within scope does not imply the claim
is otherwise correct or supported.

### Overbroad

**Key:** `overbroad`

The claim asserts a materially wider behavior, population, failure path, or
guarantee than its valid evidence and exercised scenario can establish.

### Underspecified

**Key:** `underspecified`

The claim omits material bounds or assumptions needed to determine its intended
scope. Unlike `overbroad`, it may not explicitly assert a wider guarantee; its
limits are too vague for honest scope evaluation.

### Accept

**Key:** `accept`

The evaluator would accept the scoped EXP-001 deliverable from the allowed
packet without a blocking correction or additional answer. An expected failing
regression test can be accepted when failure is the correctly reported evidence
and production repair is outside scope.

### Reject

**Key:** `reject`

The evaluator finds a material error, prohibited effect, misleading conclusion,
or unusable required artifact that requires substantive rework rather than a
clarifying follow-up.

### Follow-up

**Key:** `follow_up`

The evaluator cannot yet accept but identifies a bounded question, missing
evidence item, or clarification that could resolve the blocking uncertainty
without substantive rework. This is a review action, not the same as
`not_assessable`.

### Retained

**Key:** `retained`

A useful unexpected discovery visible in the full Run Record is represented in
the subject result with enough identity, scope, and qualification for a reviewer
to find and assess it.

### Distorted

**Key:** `distorted`

The subject result mentions an unexpected discovery but materially changes its
meaning, evidence, scope, or uncertainty compared with the full Run Record.

### None present

**Key:** `none_present`

After full-record review, no candidate useful unexpected discovery exists for
the retention item. This is not the same as failing to notice or retain a
discovery that occurred.

### Required

**Key:** `required`

An investigation activity directly advances an applicable Mission obligation,
required artifact, verification step, or necessary diagnosis path at reasonable
scope.

### Useful unexpected

**Key:** `useful_unexpected`

An investigation activity outside the anticipated path produces a relevant,
reviewable finding or artifact whose value justifies retaining it. It remains
subject to the same evidence and scope rules as planned work.

### Unproductive drift

**Key:** `unproductive_drift`

An investigation activity is outside what the Mission requires and produces no
useful finding or artifact proportionate to its time, mutation, cost, or risk.
Exploration is not drift merely because it was unplanned.

### Unclear

**Key:** `unclear`

The full Run Record does not permit a reliable classification of an activity as
`required`, `useful_unexpected`, or `unproductive_drift`, or one inseparable
activity mixes those roles. The evaluator records the source of ambiguity.

### Blinded ground-truth ledger

**Key:** `ground_truth_ledger`

The evaluator-only, versioned record of seeded facts, expected observations,
scope limits, and the method used to establish them. “Ground truth” is not a
claim of infallibility; uncertainty and later corrections are retained. The
subject cannot access this ledger during a blinded run.

### Semantic ledger

**Key:** `semantic_ledger`

An evaluator-only list of task-information atoms used to audit prompt parity. It
contains what each subject condition must be told, not the hidden cause or
expected answer in the ground-truth ledger.

### Information-equivalent

**Key:** `information_equivalent`

Two prompt renderings are information-equivalent when they communicate the same
task facts, obligations, permissions, evidence requirements, uncertainty policy,
and completion criteria without a materially different presupposition. They need
not have equal wording, formatting, salience, token count, or cognitive effect.

### Contamination

**Key:** `contamination`

Prior exposure that can change performance or invalidate an “unseen” claim,
including access to fixture truth, revealing tests, prompts, transcripts,
rubrics, generated documentation, or repeated use. Contamination is recorded by
source and affected dataset use.

## Record and interpretation layers

### Raw record

**Key:** `raw_record`

The immutable captured representation of what occurred: exact prompts,
responses, events, tool interactions, output streams, artifacts, timing,
failures, and interventions. A correction appends a linked note rather than
rewriting raw data.

### Raw object

**Key:** `raw_object`

A write-once exact byte sequence owned by a Run Record and identified by its
content digest. A Raw Object holds binary, large, malformed, or byte-sensitive
material that should not be normalized or embedded directly in the Run Journal.
Its media type, byte length, role, and provenance are journal metadata; its
digest establishes identity, not truth.

### Normalized observation

**Key:** `normalized_observation`

A reproducibly derived fact or measurement computed from raw records using a
versioned method, such as a resolved reference, command count, or rubric answer.
Normalization does not include a causal explanation or value judgment.

### Rebuildable projection

**Key:** `rebuildable_projection`

A disposable query or application model derived entirely from pinned canonical
records by a versioned process. Deleting and rebuilding it must not lose raw
evidence or change results without a recorded input or derivation-version
change. It is not a source of truth merely because it is easier to query.

### Interpretation

**Key:** `interpretation`

An explanation of what observations may mean, including hypotheses, confounds,
and alternative explanations. Interpretations cite observations and remain
separate from them.

### Finding

**Key:** `finding`

A versioned synthesis of one or more observations under a stated analysis
method. A finding identifies supporting runs, uncertainty, and competing
explanations.

### Decision

**Key:** `decision`

A recorded choice to continue, revise, replicate, stop, promote, or apply a
finding. A decision cites its evidence and rationale and does not overwrite the
records that motivated it. Consequential research and design decisions normally
receive an Architecture Decision Record.

### Malformed

**Key:** `malformed`

Captured content that cannot be parsed or does not satisfy the required
structural contract. Malformed is a retained outcome, not permission to discard,
repair silently, or rerun selectively.

### Interrupted

**Key:** `interrupted`

A run or operation ended by an explicit user, operator, policy, timeout, or
system interruption before normal completion. Record the initiator, timing, and
known effects.

### Unexpected

**Key:** `unexpected`

An observation or outcome not anticipated by the preregistered categories or
ground truth. Unexpected does not imply useful, correct, or erroneous.

## Mission and result semantics

### Mission

**Key:** `mission`

A bounded, typed work contract containing objective, obligations, invariants,
context, permitted and prohibited effects, deliverables, evidence requirements,
uncertainty policy, and completion criteria. EXP-001 tests one JSON-serialized
Mission representation; it does not establish a universal Mission schema.

### Objective

**Key:** `objective`

The outcome a Mission is intended to advance. An objective explains the desired
result but does not replace its separately checkable obligations.

### Obligation

**Key:** `obligation`

A separately assessable requirement that the subject must address. An obligation
outcome records whether and how the requirement was addressed under the
protocol's rubric; mention alone is not coverage.

### Invariant

**Key:** `invariant`

A property required to remain true across the states or transitions in scope. An
invariant is normative until evidence evaluates whether the implementation
satisfies it under stated conditions.

### Evidence-Carrying Result

**Key:** `evidence_carrying_result`

A work result that separates consequential claims, evidence, artifacts, effects,
obligation outcomes, contradictions, unexpected discoveries, and unresolved
uncertainty. It is the general semantic concept, independent of one wire format.

### Evidence receipt

**Key:** `evidence_receipt`

The JSON v1 representation of an Evidence-Carrying Result used by EXP-001. It
uses `task_id` so receipt-only conditions do not presuppose Mission input.

## Claims, evidence, and uncertainty

### Claim

**Key:** `claim`

A discrete assertion capable of being supported, contradicted, or unresolved.
Split a compound assertion when its clauses can differ in evidence, scope, or
disposition.

### Consequential claim

**Key:** `consequential_claim`

A claim for which making it false, materially narrower, or unsupported could
reasonably change an evaluator's judgment about an obligation, invariant,
diagnosis, artifact, verification result, uncertainty, acceptance decision, or
recommended next action.

Procedural narration, task restatement, navigation detail, stylistic preference,
and duplicated assertions are not consequential by default. An unexpected
discovery is consequential when it meets the same counterfactual rule.

### Normalized claim set

**Key:** `normalized_claim_set`

The evaluator-derived set of atomic consequential claims used as the measurement
denominator. It is derived consistently from subject assertions and artifacts;
the subject cannot improve coverage by omitting claims from a self-declared
list. Duplicate assertions count once, and separable compound assertions are
split.

### Epistemic type

**Key:** `epistemic_type`

How a claim is known, distinct from whether the claim is currently supported,
contradicted, or unresolved. EXP-001 uses only `reported`, `observed`, and
`derived`.

### Reported

**Key:** `reported`

An assertion inherited from the task or another source and not independently
established in the current run. Citation proves that the report exists, not that
its content is true.

### Observed

**Key:** `observed`

An assertion directly read, executed, or produced in the current run, scoped to
the referenced file, command, event, or artifact. A behavioral generalization or
causal explanation based on an observation is `derived`, not `observed`.

### Derived

**Key:** `derived`

An inference from one or more observations or other evidence. A derived claim
states the assumptions and scope needed to connect its evidence to its
conclusion.

### Disposition

**Key:** `disposition`

The current evidentiary relationship between a claim and the available valid
evidence. EXP-001 uses `supported`, `contradicted`, and `unresolved`.

### Supported

**Key:** `supported`

Valid evidence supports the claim at its stated scope and assumptions. Supported
does not mean universally proven, permanently true, or independently verified.

### Contradicted

**Key:** `contradicted`

Valid evidence supports an incompatible conclusion or the claim's negation at
the relevant scope. Conflicting evidence can instead make a claim unresolved.

### Unresolved

**Key:** `unresolved`

The available evidence is absent, insufficient, invalid, or materially
conflicting, so the protocol cannot responsibly assign supported or
contradicted. Unresolved is a claim disposition, not a run failure.

### Unknown

**Key:** `unknown`

A fact or state not currently known. In EXP-001, claims about an unknown receive
the `unresolved` disposition rather than using `unknown` as an epistemic type.

### Indeterminate

**Key:** `indeterminate`

An operation or effect outcome that cannot be established after it may have
crossed a consequential boundary. It is stronger and more specific than general
uncertainty and must not be converted silently to success or failure.

### Evidence

**Key:** `evidence`

A retained observation, artifact, record, or independently justified source that
bears on a claim. Evidence has scope and may support, contradict, or fail to
resolve a claim. Equal retention does not imply equal evidentiary weight.

### Evidence kind

**Key:** `evidence_kind`

The form of an evidence item, such as source content, command output, test
result, event, artifact, or external source. Evidence kind is separate from a
claim's epistemic type.

### Evidence reference

**Key:** `evidence_reference`

A typed, machine-resolvable registry entry that identifies a run-local or pinned
fixture object and the smallest practical locator within it. Its receipt-local
ID is an alias; canonical identity comes from the referenced run record and
digest. A reference is not valid merely because its syntax parses.

### Evidence registry

**Key:** `evidence_registry`

The top-level collection of evidence references in an Evidence Receipt. Claims
refer to registry entries by local ID so one locator can be reused without
duplication.

### Evidence link

**Key:** `evidence_link`

A claim-specific relationship from a claim to one evidence-registry entry. In
EXP-001 the subject may declare `supports` or `contradicts`; the evaluator
checks that declared relationship independently.

### Mechanical reference validation

**Key:** `mechanical_reference_validation`

Reproducible checks that a reference parses, resolves uniquely, belongs to the
declared run or fixture, matches retained digests, uses a compatible locator,
and has safe in-bounds selectors. Mechanical validation does not decide semantic
support.

### Semantic evidence assessment

**Key:** `semantic_evidence_assessment`

Evaluation of whether referenced evidence actually supports or contradicts the
exact claim, represents scope and assumptions honestly, and is independent or
correlated with other evidence. It is recorded separately from mechanical
reference validation.

### Evidence validity

**Key:** `evidence_validity`

The separately retained mechanical and semantic properties of an evidence
reference and link. Do not collapse resolution, authenticity, exact support,
scope, and independence into one boolean.

### Unsupported assertion

**Key:** `unsupported_assertion`

A consequential claim presented as supported when it lacks valid supporting
evidence or is materially broader than its evidence. An explicitly unresolved
claim is not an unsupported assertion merely because evidence is absent.

### Unexpected discovery

**Key:** `unexpected_discovery`

A potentially relevant finding outside the anticipated obligation or schema
categories. It remains subject to the same claim, evidence, and uncertainty
rules as expected findings and is retained even when it does not affect the
primary outcome.

## Dataset uses

### Development example

**Key:** `development_example`

A visible case used to design prompts, schemas, tools, or metrics. Exposure is
expected and recorded; it is not later represented as unseen evaluation data.

### Regression case

**Key:** `regression_case`

A stable case protecting a specific learned behavior or invariant. Repeated
exposure is expected. Promotion from a run requires a recorded curation decision
and preserves lineage.

### Held-out evaluation case

**Key:** `held_out_evaluation_case`

A case reserved for comparative evaluation with its ground truth and scoring
details minimally exposed to subjects and prompt designers. A fixture inspected
during development is contaminated for this use.

## EXP-001 measurement terms

### Obligation coverage

**Key:** `obligation_coverage`

The proportion of applicable stated obligations correctly addressed, while
retaining each obligation's individual outcome.

### Claim-evidence coverage

**Key:** `claim_evidence_coverage`

The proportion of normalized consequential claims linked to at least one
evidence reference. It measures linkage, not reference validity or support.

### Review effort

**Key:** `review_effort`

The time and interaction needed to reach a correct acceptance disposition,
including opened references, transcript sections read, follow-up questions, and
requests for more context.

### Mission drift

**Key:** `mission_drift`

Investigation, mutation, testing, or claims unrelated to the Mission's
objective, obligations, or useful unexpected discoveries. Unexpected work is not
drift merely because it was not anticipated.

### Semantic compactness

**Key:** `semantic_compactness`

How completely a result retains consequential claims, evidence, qualification,
and review utility relative to the full transcript and artifact set. It is not a
byte cap or a synonym for shortness.

### Operational cost

**Key:** `operational_cost`

The resources consumed by a condition, including wall time, model use, tool
calls, command runtime, human preparation and evaluation, storage, parsing, and
normalization.
