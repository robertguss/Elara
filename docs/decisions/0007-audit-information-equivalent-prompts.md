# ADR-0007: Audit information-equivalent prompts

> **Status:** Accepted
>
> **Date:** 2026-08-19
>
> **Scope:** EXP-001

## Context

A more complete Mission than narrative baseline would test information quantity,
not structured input. Independently authored prompts can differ subtly in facts,
permissions, expectations, and presuppositions even when they describe the same
task.

## Decision

Maintain an evaluator-only JSON semantic ledger of task-information atoms. Audit
both the ordinary narrative and structured Mission input segments against it.
Every atom must be represented without an additional factual claim or materially
different presupposition.

Construct A–D compositionally from one input segment and one output clause. Keep
system context, fixture, tools, symptom report, permissions, and task facts
identical outside the manipulated factors. Do not pad prompt lengths.

## Rationale

The ledger makes parity disagreements inspectable while preserving natural
differences in formatting, salience, and length as part of the Mission
treatment. Compositional construction prevents output instructions from changing
task facts.

## Alternatives considered

- **Informal human judgment only:** lightweight but difficult to reproduce and
  audit.
- **Identical prose with JSON punctuation added:** may preserve words but
  creates an unnatural Mission and does not test typed grouping meaningfully.
- **Equal token or byte counts:** adds artificial padding without ensuring
  semantic equivalence.

## Consequences

- The semantic ledger is protocol data but remains unavailable to the subject.
- Prompt changes require a parity audit and version update.
- Information-equivalent does not mean cognitively equivalent; salience remains
  a known mechanism and confound.

## Revisit triggers

- Independent parity review repeatedly finds unmappable atoms.
- Semantic-ledger maintenance becomes more subjective than direct prompt review.
- Prompt rendering itself adds material facts or omissions.

## Provenance

- [EXP-001 design thread](https://ampcode.com/threads/T-01a019d7-4ff1-75fa-9070-a705e5065b5c)
- [EXP-001 prompt construction](../experiments/001-mission-receipt.md#prompt-construction-and-pilot-serialization)
