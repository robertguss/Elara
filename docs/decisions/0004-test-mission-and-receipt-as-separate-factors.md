# ADR-0004: Test Mission and receipt as separate factors

> **Status:** Accepted
>
> **Date:** 2026-08-19
>
> **Scope:** EXP-001

## Context

A structured Mission input and Evidence-Carrying Result output could affect work
through different mechanisms. Testing only the combined contract would not show
whether input structure, output evidence requirements, their interaction, or
ordinary task variation caused an observed difference.

## Decision

Use a 2×2 design:

- A: ordinary narrative input and free-form output.
- B: structured Mission input and free-form output.
- C: ordinary narrative input and evidence receipt output.
- D: structured Mission input and evidence receipt output.

Ordinary and Mission inputs contain information-equivalent task content.
Free-form conditions may provide evidence voluntarily.

## Rationale

The factorial design estimates the input and output effects separately and makes
an interaction visible without forbidding baseline conditions from performing
well.

## Alternatives considered

- **Baseline versus combined Mission Receipt:** lower sample cost but cannot
  attribute an effect to one contract.
- **Test Mission first, then receipt:** simpler sequencing but model and fixture
  drift can confound the comparisons.
- **Prohibit evidence in free-form output:** creates an artificially weak
  baseline.

## Consequences

- Prompt parity and randomization become protocol obligations.
- More runs and evaluator effort are required than a two-condition study.
- An interaction may reflect representation congruence rather than semantics and
  must be interpreted cautiously.

## Revisit triggers

- Pilot results show that the factors cannot be manipulated independently.
- Receipt parsing failures dominate all other observations.
- Required sample cost makes the factorial comparison infeasible.

## Provenance

- [EXP-001 Mission Receipt](../experiments/001-mission-receipt.md)
- Commit `3693629` (`Design the Mission Receipt experiment`)
- [Harness vision and experiment discussion](https://ampcode.com/threads/T-01a01640-f953-736b-9aa4-936428e10fa3)
