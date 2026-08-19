# ADR-0002: Version canonical research vocabulary

> **Status:** Accepted
>
> **Date:** 2026-08-19
>
> **Scope:** Harness research

## Context

Terms such as thread, session, run, evidence, supported, unresolved, and
indeterminate can imply different things across conversations, Harness,
execution environments, and experiments. Inconsistent meanings would make
prompts, measurements, and historical conclusions difficult to compare.

## Decision

Use `docs/glossary.md` as the canonical working vocabulary for semantically
important Harness research terms. Give each term a stable `snake_case` key.
Preregistered protocols pin the glossary Git commit they use.

A protocol may narrow a definition only by citing the canonical term and stating
the scoped difference. Semantic changes after preregistration require a protocol
amendment and do not retroactively alter prior runs.

## Rationale

A versioned glossary supplies shared language while allowing evidence-driven
revision. Pinning the revision prevents later wording changes from silently
changing how older records are interpreted.

## Alternatives considered

- **Definitions local to each prompt:** self-contained but likely to drift and
  duplicate semantics.
- **Threads as canonical definitions:** not reliably available to every run or
  repository consumer.
- **A formal ontology or DSL:** premature before the terms survive experiments.

## Consequences

- Protocol and run records must retain a glossary revision.
- Load-bearing new terms must be defined before preregistration.
- Ordinary language remains ordinary; only interpretation-changing terms need
  entries.
- The glossary can be wrong, but changes become explicit and traceable.

## Revisit triggers

- Two experiments require irreconcilable meanings for the same stable key.
- Markdown cannot express relationships needed for validation or querying.
- Vocabulary maintenance becomes detached from actual protocol use.

## Provenance

- [EXP-001 design thread](https://ampcode.com/threads/T-01a019d7-4ff1-75fa-9070-a705e5065b5c)
- [Harness Research Glossary](../glossary.md)
- [Harness Experimental Lab](../experiments/README.md)
