# ADR-0016: Use typed categorical rubric outcomes without partial scores

> **Status:** Accepted
>
> **Date:** 2026-08-19
>
> **Scope:** EXP-001 evaluation

## Context

ADR-0015 divides mechanical and semantic evaluation authority and requires a
human and independent agent to apply the same rubric separately. The rubric now
needs stable response values that preserve why an item succeeded, failed, was
absent, or could not be assessed.

One universal numeric or ordinal scale would conflate different questions. A
ground-truth assertion can be correct but unsupported, an obligation can be
inapplicable rather than violated, and relevant evidence can be insufficient
rather than irrelevant. A `partially_correct` value would also allow compound
rubric items to survive instead of requiring evaluators to identify which atomic
clause differs.

## Decision

Use typed categorical outcomes matched to each evaluation construct:

| Construct                      | Allowed outcomes                                                          |
| ------------------------------ | ------------------------------------------------------------------------- |
| Ground-truth correctness       | `correct`, `incorrect`, `omitted`, `not_assessable`                       |
| Obligation outcome             | `satisfied`, `violated`, `not_applicable`, `not_assessable`               |
| Semantic evidence support      | `supports`, `contradicts`, `insufficient`, `irrelevant`, `not_assessable` |
| Claim scope                    | `within_scope`, `overbroad`, `underspecified`, `not_assessable`           |
| Review disposition             | `accept`, `reject`, `follow_up`, `not_assessable`                         |
| Unexpected-discovery retention | `retained`, `omitted`, `distorted`, `none_present`                        |
| Investigation activity         | `required`, `useful_unexpected`, `unproductive_drift`, `unclear`          |

The canonical glossary defines every value. These are evaluator outcomes, not
substitutes for the subject's epistemic type or claim disposition. In
particular, `correct` does not imply `supported`, and `not_assessable` is not
the subject's `unresolved` disposition.

Apply these rules:

1. Rubric items are atomic. If clauses can receive different outcomes, split the
   item and retain their parent ground-truth fact or obligation as lineage.
2. Do not use `partially_correct`, Likert ratings, confidence percentages, or an
   overall quality score in the preregistered pilot rubric.
3. Every semantic outcome includes a concise rationale and the evaluator-visible
   evidence or ground-truth references used. A rationale may be brief, but it
   cannot be inferred only from the selected label.
4. `not_assessable` requires the exact missing, inaccessible, ambiguous, or
   corrupted information that prevents judgment. It must not be used merely
   because evaluation is difficult.
5. `not_applicable` is allowed only for an obligation whose preregistered
   applicability rule is false, with that rule identified.
6. Mechanical validation retains its native status fields and observations; it
   is not translated into a semantic rubric label merely for uniformity.
7. Pass 2 never overwrites Pass 1. It links to the earlier assessment, records
   its own outcome and rationale, and explains any change after transcript
   access.
8. Human and independent-agent outcomes remain separate. Agreement and
   disagreement are derived item by item without averaging category values.

Ratios such as obligation coverage or unsupported-assertion rate may be derived
later from eligible atomic outcomes using a versioned formula. Retain every row
and exclusion so a ratio cannot hide which obligation, claim, or reference drove
it.

## Rationale

Construct-specific categories preserve distinctions that matter to EXP-001's
hypotheses while remaining simple enough for human and agent evaluators. Atomic
items make disagreement interpretable and prevent a middle category from hiding
one correct clause beside one incorrect clause.

Required rationale and evidence references make evaluator judgments auditable
without demanding essays. A common `not_assessable` escape hatch preserves real
missing data while its required reason discourages convenience use.

## Alternatives considered

- **One pass/fail value for every item:** mechanically simple but conflates
  omission, inapplicability, insufficient evidence, and incorrectness.
- **One five-point quality scale:** easy to aggregate but creates
  evaluator-scale calibration problems and hides the construct being judged.
- **Add `partially_correct`:** convenient for compound rows but weakens the rule
  that independently variable clauses receive independent outcomes.
- **Require numeric confidence:** suggests precision that this small pilot
  cannot calibrate; uncertainty belongs in reasons and evidence status.
- **Use claim dispositions for every rubric item:** `supported`, `contradicted`,
  and `unresolved` describe claims, not obligation completion, review action,
  discovery retention, or activity classification.
- **Allow free-form verdicts:** retains nuance but prevents consistent
  comparison and reproducible derived measures.

## Consequences

- The ground-truth ledger and obligation list must be normalized into atomic
  evaluator rows before the pilot.
- Each semantic evaluation row needs an outcome, rationale, and evidence or
  ground-truth references.
- Discovery retention requires Pass 2 to identify candidate useful discoveries
  before deciding `retained`, `omitted`, `distorted`, or `none_present`.
- Investigation activity requires evaluator-normalized activity units with
  transcript or event bounds; that unit definition remains to be tested.
- Review disposition remains separate from correctness and protocol compliance:
  an expected failing regression test can still support `accept` for the scoped
  diagnostic deliverable.
- Pilot analysis reports category counts and item-level rows before any derived
  ratios.

## Revisit triggers

- Evaluators repeatedly need an outcome that cannot be represented without
  distorting one of the defined categories.
- Atomic splitting produces excessive evaluator burden or unstable item sets.
- `not_assessable` or `unclear` dominates despite complete packets.
- Human-agent disagreement clusters around one ambiguous value definition.
- A calibrated ordinal measure becomes necessary for a later, larger study and
  demonstrates acceptable inter-rater reliability.

## Provenance

- [EXP-001 design thread](https://ampcode.com/threads/T-01a019d7-4ff1-75fa-9070-a705e5065b5c)
- [EXP-001 Mission Receipt](../experiments/001-mission-receipt.md)
- [Harness Research Glossary](../glossary.md)
- [ADR-0009 — Normalize consequential claims independently](0009-normalize-consequential-claims.md)
- [ADR-0010 — Use a minimal epistemic vocabulary](0010-use-minimal-epistemic-vocabulary.md)
- [ADR-0011 — Use a typed evidence registry](0011-use-typed-evidence-registry.md)
- [ADR-0015 — Use human-primary two-pass evaluation](0015-use-human-primary-two-pass-evaluation.md)
