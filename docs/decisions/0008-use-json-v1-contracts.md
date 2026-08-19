# ADR-0008: Use JSON v1 contracts for the pilot

> **Status:** Accepted
>
> **Date:** 2026-08-19
>
> **Scope:** EXP-001 pilot

## Context

The pilot needs structured input and output that can carry stable IDs and be
validated mechanically. Markdown is flexible but structurally permissive. YAML
has implicit typing and parser differences; TOML is awkward for nested claim and
evidence records.

## Decision

Use a pretty-printed JSON v1 Mission for conditions B and D and one JSON v1
evidence receipt for conditions C and D. Deliver JSON inside a minimal text
wrapper when needed. Preserve the exact prompt and raw result before parsing.

Do not silently repair malformed, fenced, partial, or nonconforming output. Do
not build a general schema framework before pilot semantics are tested.

## Rationale

JSON is strict, supports nested records, is mechanically parseable, and is
already supported by Harness through Jason. A small versioned shape is enough to
test the contract.

## Alternatives considered

- **Structured Markdown:** readable but difficult to parse and validate
  consistently.
- **YAML:** readable but brings implicit types, duplicate-key behavior, and
  parser variability.
- **TOML:** precise for configuration but cumbersome for nested repeated claims.
- **A formal schema platform:** premature infrastructure.

## Consequences

- EXP-001 tests JSON-serialized contracts, not format-independent semantics.
- JSON verbosity and malformed-output rate are treatment costs, not noise to
  erase.
- Using JSON for both input and output may advantage condition D through
  representation congruence.
- A later replication should vary representation before generalizing.

## Revisit triggers

- JSON formatting failures prevent semantic evaluation in most receipt runs.
- Review effort reflects serialization difficulty rather than evidence utility.
- Another representation demonstrates substantially different outcomes.

## Provenance

- [EXP-001 design thread](https://ampcode.com/threads/T-01a019d7-4ff1-75fa-9070-a705e5065b5c)
- [EXP-001 serialization decision](../experiments/001-mission-receipt.md#prompt-construction-and-pilot-serialization)
