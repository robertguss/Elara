# ADR-0017: Use an atomic pilot correctness ledger

> **Status:** Accepted
>
> **Date:** 2026-08-19
>
> **Scope:** EXP-001 pilot evaluation

## Context

The pilot's blinded ground-truth ledger currently describes six compound facts
covering cause, failure behavior, preserved behavior, the diagnosis boundary,
and limits on what the fixture can establish. ADR-0016 requires atomic rubric
items because clauses that can differ should not share one outcome.

Scoring the six narrative facts directly would hide meaningful differences. A
result could identify the returned parse error while incorrectly claiming a new
generation committed, or preserve one untested guarantee as unresolved while
overstating another. Conversely, assigning correctness to exact wording would
penalize semantically equivalent descriptions of the same behavior.

## Decision

Evaluate pilot ground-truth correctness with the 15 atomic `COR-001` through
`COR-015` rows defined in the EXP-001 protocol. Preserve `GT-001` through
`GT-006` as lineage only; they are not additional scored rows.

The rows separately represent:

- Preparation order, returned error, and committed registry and generations.
- The omitted abort, resulting pending candidate, and externally visible tool
  availability.
- Preserved session history and completed pre-reload outcome.
- The narrow causal production boundary.
- Three separate guarantees that this fixture does not establish.

Apply these rules:

1. Judge semantic equivalence rather than exact terminology.
2. Require the result or delivered artifact to state or unambiguously entail an
   assertion; evaluator-hidden evidence alone does not prevent `omitted`.
3. Judge correctness independently from whether cited evidence supports the
   assertion.
4. Keep rows unweighted and uncollapsed.
5. For each unestablished guarantee, assign `correct` when the result preserves
   the limit as unresolved, `incorrect` when it claims the guarantee, and
   `omitted` when it does not address the limit.
6. A separate claim-scope row may evaluate the same proposition without
   replacing or changing its correctness outcome.

## Rationale

Fifteen rows are sufficient to separate facts that can vary independently
without inventing substeps that the research question does not need. Explicit
scope-limit rows test the Mission's uncertainty obligation rather than treating
silence as honest uncertainty. Keeping correctness and evidence support separate
allows EXP-001 to detect a correct but unsupported diagnosis as distinct from an
incorrect one.

## Alternatives considered

- **Score the six narrative ground-truth entries:** shorter, but compound rows
  would require partial outcomes or hide important disagreements.
- **Evaluate only externally visible behavior:** avoids implementation-specific
  facts, but cannot distinguish accidental symptom reproduction from diagnosis
  of the seeded cause and responsible boundary.
- **Move all three scope limits only to claim-scope evaluation:** would identify
  overbroad claims but would not measure the explicit obligation to distinguish
  guarantees that the scenario cannot establish.
- **Give causal or externally visible facts greater weight:** introduces a value
  judgment and composite score before the pilot shows that weighting is useful.
- **Require exact vocabulary:** mechanically tempting but would measure phrasing
  rather than semantic correctness.

## Consequences

- The evaluator packet must include the atomic ledger and its parent lineage.
- Pilot reporting retains each row and outcome; any later counts or ratios name
  their included rows.
- The correctness ledger does not by itself assess obligation completion,
  evidence resolution or support, prohibited effects, or review disposition.
- Evaluators may need examples during Phase 0 to calibrate explicit assertion
  versus unambiguous entailment.
- The remaining Mission obligations must be normalized independently, even when
  one result statement informs both an obligation and a correctness row.

## Revisit triggers

- Evaluators cannot consistently distinguish entailment from omission.
- A row repeatedly combines facts that can receive different outcomes.
- A row cannot be assessed from the frozen evaluator packet.
- The three explicit scope-limit rows dominate obligation coverage without
  improving uncertainty discrimination.
- The fixture implementation or blinded reproducer contradicts an adopted row.

## Provenance

- [EXP-001 design thread](https://ampcode.com/threads/T-01a019d7-4ff1-75fa-9070-a705e5065b5c)
- [EXP-001 Mission Receipt](../experiments/001-mission-receipt.md)
- [ADR-0005 — Use partial-preparation rollback for the pilot](0005-use-partial-preparation-rollback-pilot.md)
- [ADR-0006 — Diagnose and add a regression test without repair](0006-diagnose-and-add-regression-test.md)
- [ADR-0015 — Use human-primary two-pass evaluation](0015-use-human-primary-two-pass-evaluation.md)
- [ADR-0016 — Use typed categorical rubric outcomes](0016-use-typed-categorical-rubric-outcomes.md)
