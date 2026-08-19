# ADR-0012: Defer Ash adoption until pilot-derived needs justify it

> **Status:** Accepted
>
> **Date:** 2026-08-19
>
> **Scope:** Harness Experimental Lab and EXP-001

## Context

Ash can provide typed Resources, Actions, relationships, policies, querying, and
data-layer integrations. Its extensions can add state machines, audit history,
jobs, and action-event replay. These capabilities may eventually help a lab with
stable normalized concepts and repeated cross-run queries.

EXP-001 is still establishing those concepts. Harness is currently a small Mix
application with one runtime dependency and file-based session/recording stores.
Adopting an application framework now could make Ash's ontology part of the
experiment and add persistence, migration, compile-time, and operational costs
before they solve observed problems.

AshEvents records and replays instrumented Ash create/update/destroy actions; it
is not a byte-faithful, tamper-evident store for arbitrary experiment records.
AshPaperTrail audits resource changes but does not define scientific provenance,
decision supersession, or immutable raw-record semantics.

## Decision

Do not adopt Ash, an Ash data layer, Ash extensions, or `usage_rules` during
EXP-001's deterministic phase or pilot.

Keep canonical raw experimental records framework-independent, with stable IDs,
exact retained bytes, format and derivation versions, digests, and explicit
record layers. Ash must not become the sole authority for raw evidence.

Do not schedule an Ash spike automatically after the pilot. Consider one only
when adoption triggers are met. The narrowest legitimate trial is a disposable,
rebuildable normalized read projection populated from verified canonical
records. Compare the same real ingestion and three to five recurring queries
using plain Elixir or Ecto/SQLite and Ash core with exactly one data layer. Add
no extension without a demonstrated requirement.

Defer `usage_rules` independently. Reconsider it when several nontrivial
dependencies create repeated API misuse and generated guidance can remain
subordinate to repository policy.

## Rationale

Deferral preserves EXP-001 as a test of Mission and evidence semantics rather
than framework adoption. Framework-independent raw records protect later
migration, while a trigger-driven projection trial preserves the option to use
Ash where its resource/action model has measurable value.

## Alternatives considered

- **Adopt Ash core now:** gains typed resources early but risks premature domain
  modeling and framework coupling.
- **Adopt Ash with SQLite:** avoids a server, but adds a younger data layer and
  migrations before query requirements exist.
- **Adopt AshPostgres and extensions:** supplies the richest ecosystem at the
  greatest operational and semantic cost.
- **Use AshEvents as canonical history:** records Ash action semantics rather
  than arbitrary exact raw experiment bytes and lacks tamper-evident
  immutability.
- **Adopt only `usage_rules`:** independent and potentially useful, but
  currently duplicates curated `AGENTS.md` ownership without demonstrated
  benefit.

## Consequences

- Initial lab records and normalization remain plain, versioned, and portable.
- Minimum future-migration boundaries—IDs, exact bytes, digests, versions, and
  derivation lineage—must not be omitted merely because Ash is deferred.
- Any future Ash database is disposable and reproducible from canonical records.
- The project avoids an immediate dependency and database expansion.
- Querying may remain less convenient until actual repetition justifies a
  projection.

## Adoption triggers

Evaluate Ash only when most of these are true:

- Pilot concepts survive at least one revision without structural churn.
- Repeated cross-run queries are awkward with files or a small index.
- Multiple workflows need the same validation or action invariants.
- Relationships or authorization are demonstrated requirements.
- A suitable data layer fits the CLI without introducing Postgres primarily for
  Ash.
- A bounded comparison shows clear maintainability or correctness benefit over
  plain Elixir/Ecto.
- Projection rebuilds reproduce results from pinned raw records and derivation
  versions.
- Dependency, migration, and framework-upgrade ownership is explicit.

## Rejection triggers

Reject Ash for this scope if:

- Raw capture must pass through Ash actions or AshEvents.
- An Ash database becomes the only copy or source of truth.
- Analysis remains file-scale and batch-oriented.
- Postgres is required mainly to accommodate the framework.
- Resource/action terminology starts determining experimental semantics.
- Projection rebuilds cannot reproduce query results from canonical records.
- Framework churn costs more than the queries and invariants it simplifies.

Reject `usage_rules` if generated guidance conflicts with local rules, creates a
second canonical instruction source, or produces noisy lockstep updates.

## Revisit triggers

- A pilot-derived adoption trigger is satisfied and documented.
- A multi-user control plane creates immediate relationship, policy, or query
  requirements under a separate ADR.
- Curated dependency guidance becomes costly to maintain manually.

## Provenance

- [EXP-001 design thread](https://ampcode.com/threads/T-01a019d7-4ff1-75fa-9070-a705e5065b5c)
- [Ash architecture overview](https://github.com/ash-project/ash/blob/main/documentation/topics/about_ash/what-is-ash.md)
- [AshEvents](https://github.com/ash-project/ash_events)
- [UsageRules](https://usage-rules.hexdocs.pm/readme.html)
- [Harness Experimental Lab](../experiments/README.md)
- [EXP-001 Mission Receipt](../experiments/001-mission-receipt.md)
