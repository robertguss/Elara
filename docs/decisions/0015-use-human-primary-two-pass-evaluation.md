# ADR-0015: Use human-primary two-pass evaluation with an independent agent

> **Status:** Accepted
>
> **Date:** 2026-08-19
>
> **Scope:** EXP-001 evaluation

## Context

EXP-001 measures both task correctness and whether a result carries useful,
valid evidence. Some evaluation questions are mechanically decidable; others
require semantic judgment about exact support, scope, uncertainty, drift, and
review utility. Treating either class as authoritative for the other would
create false precision.

Evaluation can also reveal the experimental condition. An evaluator who sees the
subject's exact input learns the Mission-input factor. Even without a condition
label, the raw result normally reveals whether the output contract required a
JSON Evidence Receipt. Normalizing every result into one presentation before
primary review would hide that representation but would also replace the actual
work product being evaluated.

A full transcript can improve evaluation but defeats the review-efficiency
question if supplied from the beginning. Same-model subject and evaluator
failures may also be correlated, while a human-only process provides no
repeatable independent-agent comparison.

## Decision

Divide evaluation authority by the kind of question:

- Deterministic validation is authoritative for mechanical facts such as strict
  parsing, ID uniqueness, reference resolution, run ownership, digest agreement,
  selector bounds, command status, and detectable prohibited mutations.
- A blinded human evaluator is primary for semantic judgments such as diagnosis
  correctness, exact evidentiary support, honest scope, uncertainty quality,
  Mission drift, unexpected-discovery value, and the review disposition.
- An independent agent applies the same versioned rubric separately as a
  sensitivity and reproducibility check. Its result is not automatically
  averaged with the human result and does not act as a tiebreaker.

Use two ordered, frozen evaluation passes for both the human and independent
agent:

1. **Pass 1 — Result and referenced evidence:** provide a condition-neutral task
   rendering from the Semantic Ledger, the raw subject result, starting and
   final workspace artifacts needed for review, the blinded ground-truth ledger,
   the rubric, and evidence targets explicitly referenced by the result. Do not
   provide the condition label, original input rendering, or full transcript.
2. **Pass 2 — Full Run Record:** after Pass 1 is frozen, provide the complete
   Run Record and transcript needed to evaluate process, Mission drift,
   unexpected discoveries, omitted evidence, and transcript dependence.

If an evaluator cannot reach a Pass 1 disposition without the transcript, record
the request, reason, time, and evidence already inspected before revealing it.
Freeze the pre-reveal answers; do not silently replace them with hindsight.

Call the primary procedure **label-blinded**, not representation-blinded. The
condition label and Mission input rendering are hidden, but the raw result may
make the Evidence Receipt factor inferable. Record this limitation rather than
claiming stronger blinding.

Run the independent-agent evaluation in an isolated evaluator context without
the subject session's hidden state. Prefer a different model lineage from the
subject when practical. Record provider, model, version or route date, prompt,
tools, and shared dependencies; “independent” does not imply statistically
independent errors.

Retain human-agent disagreements item by item with each rationale and evidence
path. Do not force consensus, silently adjudicate, or collapse disagreement into
one average during the pilot. A later adjudication protocol may be added if main
study decisions require one.

## Rationale

This split gives deterministic mechanisms authority only where reproducibility
is realistic and reserves semantic interpretation for a human who can account
for context and scope. The agent supplies a repeatable comparison and exposes
rubric ambiguity or evaluator-lineage effects without manufacturing consensus.

Freezing result-first evaluation before transcript access directly measures
whether Mission Receipts reduce review dependence. A second full-record pass
preserves process findings and unexpected discoveries that a compact result may
omit. Using the neutral Semantic Ledger hides the input rendering without
changing the subject's raw output.

## Alternatives considered

- **Independent agent as the primary evaluator:** easier to scale but vulnerable
  to correlated subject/evaluator errors and premature trust in rubric parsing.
- **Human evaluation only:** semantically credible but provides no repeatable
  agent comparison and less evidence about future evaluation automation.
- **Average human and agent judgments:** creates false consensus and hides the
  exact disagreements most useful during a pilot.
- **Adjudicate every disagreement immediately:** may produce one operational
  label but destroys disagreement as data before rubric quality is understood.
- **Provide the full transcript initially:** improves context but prevents a
  direct measure of result sufficiency and transcript dependence.
- **Normalize all results before primary review:** can conceal representation,
  but evaluates the normalizer's product rather than the subject's actual
  result.
- **Claim full blinding from hidden labels:** inaccurate because JSON versus
  prose remains visible in the raw result.

## Consequences

- The protocol must define a condition-neutral evaluator task packet separately
  from all four subject prompts.
- Pass 1 and Pass 2 responses, timing, evidence opened, transcript requests, and
  revisions must be retained independently.
- Mechanical validation results remain separate from semantic evidence
  assessments and cannot be overridden by presentation quality.
- Human evaluation time is a real pilot cost and part of operational-cost
  measurement.
- Evaluator agents require recorded lineage and isolated context; using the same
  model family remains a documented correlation, not disqualifying hidden data.
- Receipt representation remains visible. Interpret evaluator differences with
  this confound rather than calling the evaluation representation-blind.
- The pilot must inspect item-level human-agent disagreement before deciding
  whether an adjudication rule or additional evaluators are justified.

## Revisit triggers

- Human evaluation cost prevents the preregistered sample from being completed.
- Human or agent evaluators cannot apply rubric items consistently after one
  documented clarification pass.
- Pass 1 lacks enough evidence to assess most results without the transcript.
- The neutral task rendering materially differs from what subjects were asked.
- Representation visibility dominates task-correctness judgments.
- Human-agent disagreement is systematic and a decision requires one resolved
  label.
- A second human or deterministic semantic verifier demonstrates a more reliable
  primary procedure.

## Provenance

- [EXP-001 design thread](https://ampcode.com/threads/T-01a019d7-4ff1-75fa-9070-a705e5065b5c)
- [EXP-001 Mission Receipt](../experiments/001-mission-receipt.md)
- [Harness Experimental Lab](../experiments/README.md)
- [ADR-0007 — Audit information-equivalent prompts](0007-audit-information-equivalent-prompts.md)
- [ADR-0009 — Normalize consequential claims independently](0009-normalize-consequential-claims.md)
- [ADR-0010 — Use a minimal epistemic vocabulary](0010-use-minimal-epistemic-vocabulary.md)
- [ADR-0011 — Use a typed evidence registry](0011-use-typed-evidence-registry.md)
