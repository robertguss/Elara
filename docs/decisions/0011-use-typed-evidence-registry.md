# ADR-0011: Use a typed evidence registry with mechanical resolution

> **Status:** Accepted
>
> **Date:** 2026-08-19
>
> **Scope:** EXP-001

## Context

Claim-evidence measurements require references that can be resolved against one
run. Opaque strings are difficult to validate, repeated inline locators can
drift, and an evidence item may support one claim while contradicting another.
Mechanical resolution also cannot determine whether evidence semantically
supports a claim.

## Decision

Store receipt evidence in one top-level registry. Claims link to receipt-local
evidence IDs with a claim-specific `supports` or `contradicts` relation.

The pilot permits these evidence kinds:

- `source_content`
- `test_artifact`
- `test_result`
- `session_event`

It permits typed `file_span`, `command`, and `event` locators. Canonical
identity comes from the pinned workspace snapshot or run-owned command/event
record, not the receipt-local evidence ID. Digests live in the run index.

Mechanically validate parsing, IDs, links, kind/locator compatibility, target
existence, run or fixture ownership, digest authenticity, path safety, and
selector bounds. Evaluate exact semantic support, scope, and evidence
independence separately. Do not collapse them into one validity boolean.

## Rationale

Typed objects are simple to parse and extend without inventing a URI grammar.
Separating registry entries from claim links avoids duplication and correctly
places support/contradiction on the relationship. Separate mechanical and
semantic assessments prevent a resolvable citation from being mistaken for
proof.

## Alternatives considered

- **Opaque citation strings:** compact but ambiguous and difficult to validate.
- **Inline full locators on every claim:** mechanically possible but duplicated
  and prone to drift.
- **Content digests supplied by the subject:** strong identity but subjects may
  not have or reliably reproduce generated digests.
- **Infer evidence from the transcript:** rewards hidden process rather than
  result linkage and undermines review-efficiency measurement.

## Consequences

- Command and event IDs must be visible to subjects expected to cite them.
- A capture inventory must treat missing stable IDs as a capture gap rather than
  silently accepting ambiguous command text.
- Free-form results require versioned normalization into the same reference
  model.
- Malformed, missing, ambiguous, mismatched, and out-of-bounds references remain
  retained observations.

## Revisit triggers

- Existing Harness capture cannot expose stable targets without invasive product
  changes.
- The four evidence kinds cannot represent pilot claims without generic escape
  fields.
- Mechanical resolution or human semantic assessment has low agreement or
  excessive review cost.

## Provenance

- [EXP-001 design thread](https://ampcode.com/threads/T-01a019d7-4ff1-75fa-9070-a705e5065b5c)
- [EXP-001 evidence references](../experiments/001-mission-receipt.md#evidence-reference-representation-and-validation)
- [Evidence reference glossary entry](../glossary.md#evidence-reference)
