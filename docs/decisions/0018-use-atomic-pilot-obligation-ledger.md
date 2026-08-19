# ADR-0018: Use one atomic pilot obligation ledger

> **Status:** Accepted
>
> **Date:** 2026-08-19
>
> **Scope:** EXP-001 pilot evaluation

## Context

The information-equivalent pilot inputs declare factual, investigative,
artifact, evidence, effect, and completion requirements. Several required
factual answers are already represented by the atomic correctness ledger. If the
obligation rubric repeats those statements under unrelated IDs, lineage can
drift and the same fact can be counted twice merely because it appears under two
parent Mission obligations.

The receipt factor also imposes JSON output requirements only on conditions C
and D. Adding those condition-specific requirements to shared obligation
coverage would change the denominator by condition and mistake format compliance
for task quality.

## Decision

Use one atomic pilot obligation ledger with three kinds of entries:

1. Required factual content reuses the canonical `COR-001` through `COR-015`
   atoms. Each receives a correctness assessment and a linked obligation
   assessment with common lineage. Multiple parent Mission obligations do not
   duplicate an atom in the denominator.
2. `OBL-001` through `OBL-021` represent independently variable actions, test
   properties, execution reporting, evidence delivery, prohibited effects, and
   final deliverables exactly as defined in the EXP-001 protocol.
3. O6 creates one dynamic `OBL-DISC-<candidate-id>` row per relevant unexpected
   discovery available to the subject. When no candidate exists, use
   `OBL-DISC-NONE` to evaluate the required explicit negative outcome.

For required factual content, derive the linked obligation outcome from the
correctness assessment: `correct` becomes `satisfied`; `incorrect` or `omitted`
becomes `violated`; and `not_assessable` remains `not_assessable`. No factual
content atom is inapplicable in the adopted pilot. This derivation does not make
correctness and obligation completion synonymous outside this declared mapping,
and it does not establish evidence support.

Do not add one scored “all obligations explicit” row. Each absent atomic item
already retains its own omission and violation, so an aggregate row would count
the same absence again.

Retain native deterministic validation for mechanical facts and prevent a linked
semantic outcome from contradicting it. Record receipt parsing and
assigned-format compliance as a condition-specific manipulation check rather
than including it in shared Mission-obligation coverage. Preserve malformed raw
results and separately evaluate any recoverable semantic content.

## Rationale

Defining each semantic requirement once keeps prompt atoms, correctness,
obligation coverage, and evaluator records traceable without losing the fact
that one statement can answer several parent requirements. Independent action
and artifact rows still expose shallow answers that repeat correct facts without
doing the requested work.

Separating the receipt manipulation check prevents conditions C and D from being
penalized by a denominator created by the experimental factor itself. It also
distinguishes failure to produce assigned JSON from failure to diagnose the
fixture correctly.

## Alternatives considered

- **Duplicate every correctness fact as a separately worded obligation:** easy
  to tabulate but invites semantic drift and accidental double-counting.
- **Score only O1 through O6:** concise, but each parent combines clauses and
  can conceal missed behavior, evidence, or artifact properties.
- **Put all mechanical checks into semantic labels:** superficially uniform but
  discards useful parser, command, diff, and reference-validation detail.
- **Include receipt conformance in obligation coverage:** measures assigned
  format compliance but creates different denominators across conditions.
- **Ignore malformed receipt semantics:** avoids interpretation difficulty but
  silently discards potentially useful positive, negative, and unexpected data.
- **Add a single completion score:** convenient, but duplicates the outcomes of
  every omitted child obligation.

## Consequences

- Evaluator records need common atomic lineage and may attach more than one
  typed assessment to that lineage without duplicating the canonical statement.
- The obligation-coverage formula must count unique applicable atoms, not parent
  references.
- Dynamic discovery candidates must be normalized from the full Run Record
  before O6 and discovery-retention evaluation.
- The evaluator packet must expose authoritative mechanical results while
  retaining their native detail.
- Receipt contract validation is reported alongside, but not inside, shared
  obligation coverage.
- The remaining uncertainty, discovery-candidate, and investigation-activity
  rules still require exact pilot definitions.

## Revisit triggers

- One content atom legitimately requires different obligation outcomes for two
  parent Mission obligations.
- Derived obligation outcomes conceal a distinction needed by evaluators.
- Dynamic discovery normalization is too unstable to produce comparable atomic
  rows.
- Format nonconformance prevents semantic evaluation often enough that separate
  reporting becomes misleading.
- Reviewers repeatedly interpret manipulation-check failure as task failure
  despite the separation.

## Provenance

- [EXP-001 design thread](https://ampcode.com/threads/T-01a019d7-4ff1-75fa-9070-a705e5065b5c)
- [EXP-001 Mission Receipt](../experiments/001-mission-receipt.md)
- [Harness Research Glossary](../glossary.md)
- [ADR-0006 — Diagnose and add a regression test](0006-diagnose-and-add-regression-test.md)
- [ADR-0007 — Audit information-equivalent prompts](0007-audit-information-equivalent-prompts.md)
- [ADR-0015 — Use human-primary two-pass evaluation](0015-use-human-primary-two-pass-evaluation.md)
- [ADR-0016 — Use typed categorical rubric outcomes](0016-use-typed-categorical-rubric-outcomes.md)
- [ADR-0017 — Use an atomic pilot correctness ledger](0017-use-atomic-pilot-correctness-ledger.md)
