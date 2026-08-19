# ADR-0013: Separate canonical experiment records from runtime persistence

> **Status:** Accepted
>
> **Date:** 2026-08-19
>
> **Scope:** Harness Experimental Lab and EXP-001

## Context

EXP-001 requires immutable raw records that retain malformed, interrupted,
failed, and unexpected attempts with provenance to their protocol, run, code,
environment, and later interpretation. Harness already has two useful
persistence mechanisms, but they serve runtime responsibilities rather than this
experimental authority boundary.

`Harness.Session.Store` retains a resumable tree of domain messages with entry
IDs, parent links, and timestamps. Despite its JSONL representation, each save
rewrites the complete file through a temporary path and rename. It does not
retain provider transport data, session events, command timing, environment
facts, or experiment lineage.

`Harness.FlightRecorder` append-writes framed, normalized Core states, facts,
effects, and causal links for deterministic replay. It captures useful material
that the session transcript does not, including the pre-truncation tool outcome.
However, it has no clean-close record, run manifest, file digest, or
immutability enforcement; a truncated final frame is accepted as the completed
prefix. It also does not retain provider wire responses, usage metadata, command
timing, workspace snapshots, operator interventions, or failed plugin-reload
attempts.

These observations make both files valuable capture inputs without making either
one a complete canonical raw record.

## Decision

The Experimental Lab owns the canonical record for each EXP-001 run. Harness
Session Store and Flight Recorder files remain runtime records and are not the
experimental source of truth.

When a run relies on either runtime record, preserve a byte-faithful copy or
prefix under the run's ownership, assign its identity from the run record,
record its relationship to the originating session and incarnation, and index
its digest. A reference to a mutable runtime path alone is insufficient.

The canonical run record must represent an attempted run even when it is
malformed, interrupted, failed, or only partly captured. Missing, truncated, or
unrecoverable material is retained as an explicit capture status rather than
silently omitted or described as complete. Corrections add linked records and do
not rewrite sealed raw material.

This decision establishes authority and minimum preservation semantics only. It
does not yet choose the exact open-run journal, sealing transaction, recovery
procedure, storage layout, redaction boundary, or subject-visible command and
event ID mechanism. Those must be resolved before preregistration and validated
with the Scripted-provider phase.

Do not replace Session Store or Flight Recorder, adopt a database, build a
general lab platform, or change Harness product persistence merely to implement
this boundary. Add a Harness capture hook later only if the deterministic phase
shows that a required fact cannot be retained at a lab-owned boundary.

## Rationale

Separating authorities preserves the runtime stores' focused responsibilities
and allows the experiment to retain their exact useful output without pretending
that either is complete. A small lab-owned record can add run provenance,
digests, lifecycle status, and missing boundary observations without making
experimental concerns part of Harness session semantics.

This boundary also keeps raw records framework-independent and permits any
future query database or Ash resource model to remain a rebuildable projection.
It minimizes EXP-001's implementation surface while still making interrupted and
negative attempts first-class records.

## Alternatives considered

- **Use Session Store as the canonical record:** resumable and human-readable,
  but physically rewritten and limited to the domain transcript.
- **Use Flight Recorder as the canonical record:** causally rich and replayable,
  but normalized around Core transitions and incomplete at provider, command,
  workspace, lifecycle, and provenance boundaries.
- **Copy runtime files only after normal completion:** very small, but silently
  loses the attempts for which interruption-safe capture matters most and cannot
  recover facts the runtime files never contained.
- **Redesign Harness persistence as the lab store:** could unify storage, but
  expands the product and confounds the first semantic experiment with a general
  persistence architecture.
- **Adopt a database or event-sourcing framework now:** improves querying or
  application modeling before the pilot establishes stable record semantics;
  ADR-0012 defers this path.

## Consequences

- EXP-001 must distinguish runtime files, imported raw objects, normalized
  observations, and later interpretations.
- Run-owned digests and identities establish canonical evidence targets; runtime
  filenames and provider-assigned IDs are not sufficient by themselves.
- The deterministic phase must test normal, malformed, interrupted, and partial
  capture before the pilot.
- Provider metadata and raw response material, command outcome and timing,
  failed reload attempts, workspace snapshots, lifecycle termination, and
  operator interventions remain documented capture gaps.
- Command and event locators required from subjects need stable, visible
  run-owned identities; optional evidence kinds must not be presented as usable
  until their locators can resolve.
- Exact sealing, recovery, redaction, and storage mechanics remain open design
  work rather than implied implementation requirements.

## Revisit triggers

- Byte-faithful import cannot reconstruct the subject-visible interaction or
  distinguish observed facts from planned Core effects.
- Required provider or tool facts cannot be captured without changing a public
  Harness boundary.
- Copying runtime records creates unacceptable duplication or operational cost.
- The run-owned record repeatedly diverges from Harness lifecycle semantics.
- Pilot evidence shows that one existing runtime record can satisfy the full
  authority, immutability, provenance, and interruption requirements more
  simply.

## Provenance

- [EXP-001 design thread](https://ampcode.com/threads/T-01a019d7-4ff1-75fa-9070-a705e5065b5c)
- [Harness Experimental Lab](../experiments/README.md)
- [EXP-001 Mission Receipt](../experiments/001-mission-receipt.md)
- [ADR-0003 — Preserve layered experimental records](0003-preserve-layered-experimental-records.md)
- [ADR-0011 — Use a typed evidence registry](0011-use-typed-evidence-registry.md)
- [ADR-0012 — Defer Ash adoption](0012-defer-ash-adoption.md)
- [`Harness.Session.Store`](../../lib/harness/session/store.ex)
- [`Harness.FlightRecorder`](../../lib/harness/flight_recorder.ex)
- [`Harness.Session`](../../lib/harness/session.ex)
