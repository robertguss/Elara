# ADR-0009: Normalize consequential claims independently

> **Status:** Accepted
>
> **Date:** 2026-08-19
>
> **Scope:** EXP-001 evaluation

## Context

Claim-evidence coverage and unsupported-assertion rate require a denominator.
Allowing receipt conditions to define that denominator would reward declaring
fewer claims. Counting every sentence would instead treat navigation and
procedural narration as equivalent to diagnosis and verification assertions.

## Decision

Classify a claim as consequential when making it false, materially narrower, or
unsupported could reasonably change an evaluator's judgment about an obligation,
invariant, diagnosis, artifact, verification result, uncertainty, acceptance
decision, or recommended next action.

Evaluators derive one normalized atomic claim set from the result and produced
artifacts under a common rubric. Duplicate propositions count once. Split a
compound claim when clauses can differ in evidence, scope, or disposition. The
primary blinded pass does not mine the hidden transcript for extra result
claims; the full-process pass records important findings omitted from the
result.

## Rationale

Independent normalization makes conditions comparable and focuses measurements
on assertions that could change review. Separate transcript-retention analysis
preserves omitted discoveries without changing the primary output denominator.

## Alternatives considered

- **Subject-declared claims only:** directly parseable but gameable through
  omission or bundling.
- **Every factual sentence:** objective-looking but dominated by low-value
  narration and prose style.
- **Ground-truth facts only:** misses false, unexpected, and over-broad claims
  actually made by the subject.

## Consequences

- Normalization requires evaluator effort and agreement checks.
- Free-form and receipt outputs use the same denominator rules.
- Artifacts can carry consequential assertions even when prose omits them.
- Low inter-evaluator agreement can make the study unresolved.

## Revisit triggers

- Consequential classification has unacceptable evaluator disagreement.
- Artifact-derived claims unfairly penalize or advantage one condition.
- Normalization costs approach full-transcript review cost.

## Provenance

- [EXP-001 design thread](https://ampcode.com/threads/T-01a019d7-4ff1-75fa-9070-a705e5065b5c)
- [EXP-001 consequential claims](../experiments/001-mission-receipt.md#consequential-claims-and-epistemic-vocabulary)
- [Consequential claim glossary entry](../glossary.md#consequential-claim)
