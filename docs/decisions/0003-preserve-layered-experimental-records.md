# ADR-0003: Preserve layered experimental records

> **Status:** Accepted
>
> **Date:** 2026-08-19
>
> **Scope:** Harness Experimental Lab

## Context

Positive, negative, malformed, interrupted, and unexpected outcomes can all
change what Harness should build. Selective retention and mutable summaries
would hide failure modes and make later reinterpretation depend on memory.
However, retaining data does not make every item equally reliable evidence.

## Decision

Retain immutable raw records for every attempted run, subject to declared secret
and privacy redaction. Derive normalized observations reproducibly, then keep
interpretations and decisions as separate linked layers.

Do not overwrite raw or normalized records when an interpretation changes.
Promote retained runs into development examples, regression cases, or held-out
evaluation cases only through an explicit curation decision that preserves
lineage and contamination status.

## Rationale

Layering preserves what happened while allowing methods and conclusions to
evolve. Explicit curation reconciles complete exploratory retention with valid
dataset use.

## Alternatives considered

- **Retain only successful or parseable runs:** cheaper but systematically hides
  the behavior the experiment most needs to understand.
- **One editable record per run:** convenient but conflates observation and
  judgment.
- **Treat all retained data as evaluation data:** ignores contamination and
  encourages benchmark leakage.

## Consequences

- Storage, redaction, normalization, and provenance cost must be measured.
- Corrections append records rather than rewriting history.
- Equal retention is explicitly not equal evidentiary weight.
- Dataset membership and label changes require versions.

## Revisit triggers

- Privacy or licensing prevents safe retention of a record class.
- Capture cost materially exceeds its research value.
- Layer boundaries repeatedly prevent reproducible derivation or useful review.

## Provenance

- [Harness vision and experiment discussion](https://ampcode.com/threads/T-01a01640-f953-736b-9aa4-936428e10fa3)
- [Harness Experimental Lab](../experiments/README.md)
- [EXP-001 Mission Receipt](../experiments/001-mission-receipt.md)
