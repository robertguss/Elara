# ADR-0010: Use a minimal epistemic vocabulary

> **Status:** Accepted
>
> **Date:** 2026-08-19
>
> **Scope:** EXP-001

## Context

The broader vision lists many ways a claim can be known. Most do not occur in
the pilot, and a large taxonomy can induce ceremonial classification. At the
same time, flattening reports, direct observations, and inferences into one
label would hide important differences in evidence strength and scope.

## Decision

Use three epistemic types:

- `reported`: inherited from a source and not established in the current run.
- `observed`: directly read, executed, or produced in the current run at the
  referenced scope.
- `derived`: inferred from evidence with assumptions and scope stated.

Keep epistemic type separate from claim disposition. Use `supported`,
`contradicted`, and `unresolved` dispositions. Treat test result, source
content, and command output as evidence kinds rather than epistemic types. Use
`unresolved` for claims about unknowns; reserve `indeterminate` for uncertain
operation or effect outcomes after a consequential boundary may have been
crossed.

## Rationale

Three types distinguish source inheritance, direct observation, and
inference—the differences needed by the pilot—without implying a false ladder of
proof. Separate dispositions prevent “unknown” and “contradicted” from mixing
how a claim is known with what current evidence says about it.

## Alternatives considered

- **Full vision taxonomy:** expressive but mostly unused and likely ceremonial
  in this scenario.
- **Observed versus inferred only:** cannot represent an unverified supplied
  report distinctly.
- **One combined type/status enum:** creates ambiguous combinations and weakens
  normalization.
- **Add `test_supported`:** duplicates evidence kind rather than epistemic
  basis.

## Consequences

- Some claims may need splitting to use one primary epistemic type honestly.
- Future experiments may add types through an explicit protocol decision.
- `supported` remains scoped support, not universal proof.

## Revisit triggers

- Pilot claims repeatedly require a fourth basis to avoid distortion.
- Evaluators cannot apply the three types consistently.
- A later experiment introduces formal proof, production measurement, or human
  authority that the current types cannot represent.

## Provenance

- [EXP-001 design thread](https://ampcode.com/threads/T-01a019d7-4ff1-75fa-9070-a705e5065b5c)
- [EXP-001 epistemic vocabulary](../experiments/001-mission-receipt.md#consequential-claims-and-epistemic-vocabulary)
- [Epistemic type glossary entry](../glossary.md#epistemic-type)
