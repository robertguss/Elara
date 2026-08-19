# ADR-0005: Use partial-preparation rollback for the pilot

> **Status:** Accepted
>
> **Date:** 2026-08-19
>
> **Scope:** EXP-001 pilot

## Context

A malformed first plugin replacement fails before any candidate becomes pending,
so it mainly tests rejection. The existing Harness reload path prepares plugins
sequentially and must abort earlier candidates if a later candidate fails. That
path supplies a deterministic, externally visible atomicity failure without
concurrency timing.

## Decision

Use an isolated two-plugin fixture. Plugin A has a valid generation-2 candidate;
plugin B has malformed source. Seed one defect in which B's prepare failure does
not abort A's prepared candidate. The reload reports failure and commits no new
generation, but A remains pending and its prior valid tool becomes unavailable.

Keep the exact revealing existing test out of the subject fixture. Maintain a
blinded ground-truth ledger and deterministic evaluator reproducer.

## Rationale

This scenario exercises actual rollback after partial preparation, remains
deterministic, and provides observable preserved, violated, and out-of-scope
facts for evidence evaluation.

## Alternatives considered

- **Single malformed replacement:** does not exercise prepared-state cleanup.
- **Healthy reload:** useful later for false-positive detection but lacks the
  pilot's target contradiction.
- **In-flight generation coherence:** valuable but adds timing and scheduling
  variability too early.

## Consequences

- Findings apply to a narrow multi-plugin failure path.
- The fixture is contaminated for later held-out use.
- Removing the revealing test must not remove unrelated subject information.
- Concurrency and successful-migration guarantees remain unresolved.

## Revisit triggers

- The fixture cannot hide the answer without creating an unrealistic checkout.
- The failure is too trivial or too difficult for all conditions.
- Deterministic mechanics cannot reproduce the intended externally visible
  symptom.

## Provenance

- [EXP-001 design thread](https://ampcode.com/threads/T-01a019d7-4ff1-75fa-9070-a705e5065b5c)
- [EXP-001 adopted pilot scenario](../experiments/001-mission-receipt.md#adopted-pilot-scenario-partial-preparation-rollback)
- `lib/harness/session.ex`
- `lib/harness/plugin/server.ex`
- `test/harness/plugin_test.exs`
