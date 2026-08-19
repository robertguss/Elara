# ADR-0006: Diagnose and add a regression test without repair

> **Status:** Accepted
>
> **Date:** 2026-08-19
>
> **Scope:** EXP-001 pilot

## Context

Diagnosis-only work would produce mostly prose and give evidence references few
concrete artifacts to address. Requiring a production repair would introduce
implementation quality, repair choice, and larger mutation as confounds.

An unconditional instruction to leave a failing test would also pressure the
subject to confirm an unverified report.

## Decision

Require the subject to diagnose the report and add one minimal deterministic
regression test of externally observable behavior, but prohibit production-code
repair.

The test asserts the invariant without accommodating the suspected defect. Its
actual outcome is retained. Failure is expected if the report is correct, but a
passing or un-runnable test must be reported rather than forced to fail.

## Rationale

The regression test creates a reviewable artifact and deterministic evidence
while keeping the task focused on diagnosis and epistemic reporting. Preserving
the actual outcome permits contradiction and uncertainty.

## Alternatives considered

- **Diagnose only:** lower cost but over-weights narrative quality and weakens
  artifact/evidence evaluation.
- **Diagnose and repair production:** more realistic coding work but adds
  solution correctness and mutation scope to the factors.
- **Require a red test regardless of evidence:** deterministic expectation but
  rewards manufactured confirmation.

## Consequences

- The prompt must explain that a green worktree is not required and production
  repair is prohibited.
- The evaluator must distinguish a valid test artifact from a failure forced for
  the wrong reason.
- The subject-authored test remains evidence, not blinded ground truth.

## Revisit triggers

- Test-writing variance overwhelms diagnosis or receipt effects.
- Subjects routinely repair production despite equivalent prohibitions.
- A public-behavior assertion cannot reproduce the scenario deterministically.

## Provenance

- [EXP-001 design thread](https://ampcode.com/threads/T-01a019d7-4ff1-75fa-9070-a705e5065b5c)
- [EXP-001 adopted pilot work scope](../experiments/001-mission-receipt.md#adopted-pilot-work-scope-diagnose-and-add-a-regression-test)
