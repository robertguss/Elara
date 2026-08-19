# Harness Decision Log

> **Status:** Canonical decision-record index

This directory records consequential Harness research and design decisions as
small Architecture Decision Records (ADRs). The
[research glossary](../glossary.md) defines terms; ADRs preserve choices,
rationale, alternatives, consequences, and revisit conditions.

Git is the source of truth. Threads, sessions, experiments, and run notes may
propose decisions, but an accepted decision becomes canonical only when recorded
in an ADR commit.

## Traceability

```text
conversation · code · paper · prior result
                    │
                    ▼
                 ADR decision
                    │ governs
                    ▼
              protocol or design
                    │
                    ▼
               run · finding
                    │ informs
                    ▼
          retained · superseding ADR
```

- Protocols list their governing ADR IDs and glossary revision.
- Run manifests record the protocol version; they may also name ADRs that
  directly govern execution or interpretation.
- Findings and later decisions cite affected ADR IDs.
- A changed decision creates a new ADR that supersedes the old one. Do not
  rewrite the old context or rationale as if the earlier decision never existed.
- Corrections append a clearly labeled note or use a superseding ADR when the
  meaning changes.

## Statuses

- **Proposed:** under discussion; not canonical.
- **Accepted:** current decision for its declared scope.
- **Rejected:** considered and explicitly not adopted.
- **Superseded:** replaced by a named later ADR.
- **Deprecated:** retained for history but no longer recommended and not yet
  replaced by one specific decision.

## When an ADR is required

Create or amend the decision log when a choice can materially change:

- A research question, factor, scenario, fixture, or protocol.
- Prompt information, subject permissions, output contracts, or evidence rules.
- Capture, retention, normalization, evaluation, or stopping behavior.
- Public architecture, state semantics, authority, or consequential effects.
- The interpretation or application of an experimental finding.

Do not create ADRs for routine edits or choices that have no meaningful
alternative or downstream consequence.

## ADR template

```text
# ADR-NNNN: Imperative decision title

> Status
> Date
> Scope
> Related experiment/protocol

## Context
What forced a choice and what was observed rather than inferred?

## Decision
What is chosen, at what scope, and what is explicitly not chosen?

## Rationale
Why this alternative best fits the current evidence and constraints.

## Alternatives considered
Real alternatives and why they were not selected.

## Consequences
Positive costs, negative costs, confounds, and follow-on obligations.

## Revisit triggers
Evidence or conditions that should cause reconsideration.

## Provenance
Source threads, documents, code, commits, experiments, findings, and prior ADRs.
```

## Index

| ID                                                               | Decision                                                 | Status   | Scope                       |
| ---------------------------------------------------------------- | -------------------------------------------------------- | -------- | --------------------------- |
| [ADR-0001](0001-use-versioned-decision-records.md)               | Use versioned decision records                           | Accepted | Harness research and design |
| [ADR-0002](0002-version-canonical-research-vocabulary.md)        | Version canonical research vocabulary                    | Accepted | Harness research            |
| [ADR-0003](0003-preserve-layered-experimental-records.md)        | Preserve layered experimental records                    | Accepted | Experimental Lab            |
| [ADR-0004](0004-test-mission-and-receipt-as-separate-factors.md) | Test Mission and receipt as separate factors             | Accepted | EXP-001                     |
| [ADR-0005](0005-use-partial-preparation-rollback-pilot.md)       | Use partial-preparation rollback pilot                   | Accepted | EXP-001 pilot               |
| [ADR-0006](0006-diagnose-and-add-regression-test.md)             | Diagnose and add a regression test without repair        | Accepted | EXP-001 pilot               |
| [ADR-0007](0007-audit-information-equivalent-prompts.md)         | Audit information-equivalent prompts                     | Accepted | EXP-001                     |
| [ADR-0008](0008-use-json-v1-contracts.md)                        | Use JSON v1 contracts                                    | Accepted | EXP-001 pilot               |
| [ADR-0009](0009-normalize-consequential-claims.md)               | Normalize consequential claims independently             | Accepted | EXP-001 evaluation          |
| [ADR-0010](0010-use-minimal-epistemic-vocabulary.md)             | Use a minimal epistemic vocabulary                       | Accepted | EXP-001                     |
| [ADR-0011](0011-use-typed-evidence-registry.md)                  | Use a typed evidence registry with mechanical resolution | Accepted | EXP-001                     |
| [ADR-0012](0012-defer-ash-adoption.md)                           | Defer Ash adoption until pilot-derived needs justify it  | Accepted | Experimental Lab / EXP-001  |
