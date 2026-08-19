# ADR-0001: Use versioned decision records

> **Status:** Accepted
>
> **Date:** 2026-08-19
>
> **Scope:** Harness research and design

## Context

Harness decisions currently arise in threads, repository documents, code, and
experiments. Those sources preserve discussion but do not provide one compact,
stable answer to what was chosen, why, and what evidence should revisit it.
Without a decision record, later work can inherit conclusions while losing
rejected alternatives and original uncertainty.

## Decision

Record consequential research and design decisions as numbered ADRs under
`docs/decisions/`. Maintain a canonical index, stable IDs, explicit status,
source provenance, consequences, and revisit triggers.

When a decision changes materially, add a superseding ADR and retain the old
record. Protocols and findings cite the ADR IDs they use or affect.

## Rationale

Small Markdown ADRs are inspectable in Git, easy to cite from experiments, and
sufficient before a general knowledge or governance system proves necessary.
They preserve causality without making threads or runtime infrastructure the
source of truth.

## Alternatives considered

- **One mutable decision log:** simpler initially, but individual decisions lack
  durable identity and are easy to rewrite accidentally.
- **Threads as the record:** preserve rich discussion but are difficult to pin,
  diff, and consume consistently from every environment.
- **A database or ADR service:** adds infrastructure before usage semantics are
  known.

## Consequences

- Decisions gain stable IDs and can be linked to protocols, runs, and findings.
- Authors incur a small documentation and maintenance cost.
- ADRs must remain concise enough that recording does not become ceremony.
- The system records decisions, not every routine implementation choice.

## Revisit triggers

- ADR maintenance costs more than the traceability it provides.
- Cross-repository or machine-query requirements cannot be met by Markdown and
  Git without duplication or ambiguity.

## Provenance

- [EXP-001 design thread](https://ampcode.com/threads/T-01a019d7-4ff1-75fa-9070-a705e5065b5c)
- [Harness Experimental Lab](../experiments/README.md)
- [Harness Research Glossary](../glossary.md)
