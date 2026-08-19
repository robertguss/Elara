# ADR-0014: Use an append-only JSONL run journal with immutable raw objects

> **Status:** Accepted
>
> **Date:** 2026-08-19
>
> **Scope:** EXP-001 deterministic phase and pilot

## Context

ADR-0013 assigns canonical experimental authority to the lab-owned Run Record
rather than Harness runtime persistence. EXP-001 now needs the smallest format
that can retain ordered lifecycle facts, exact payload bytes, stable evidence
targets, abrupt interruption, and later verification without introducing a
database or general event-store platform.

One JSONL file is easy to inspect, stream, append, recover, version, and process
with ordinary tools. It is not sufficient by itself for arbitrary binary or
large data, and the format alone does not provide immutability, durability, or
tamper evidence. Those properties require explicit writer and sealing rules.

## Decision

Use one run-owned, append-only `journal.jsonl` as the ordered raw journal for an
EXP-001 run. Use write-once, SHA-256-addressed files under `objects/` for exact
payloads that are binary, large, or byte-sensitive. Close the raw record with a
single `seal.json` that authenticates the exact journal bytes and referenced raw
object set.

The minimum raw-record nucleus is:

```text
<run-id>/
├── journal.jsonl
├── objects/
│   └── sha256/
│       └── <digest>
└── seal.json
```

Use one journal rather than separate event, command, transcript, and operator
logs until measured scale or ownership needs justify separation. Record kinds
distinguish those facts without requiring separate physical files.

Apply these rules during the deterministic phase:

1. One writer assigns a monotonically increasing sequence, stable record ID, run
   ID, kind, timestamp, producer, lineage references, and payload or raw object
   references to each record.
2. Each complete record is one strict JSON object terminated by a newline. The
   writer opens the journal for append, never updates or deletes prior bytes,
   and durably syncs each record during Phase 0. Sync policy may be relaxed only
   after measuring the cost and preserving the same declared durability.
3. Create run-owned operation IDs before consequential operations. A started and
   finished record share that identity so an absent completion remains
   observable. IDs required in an Evidence Receipt must be shown to the subject
   consistently across conditions.
4. Store exact byte-sensitive content as a write-once raw object. Journal
   references include at least its SHA-256 digest, byte length, media type or
   declared unknown type, and role. Do not use base64 inside JSONL as the
   default raw-object store.
5. If interruption leaves a non-newline-terminated tail, preserve those bytes
   exactly. Recovery may append a delimiter and new recovery records, but must
   identify the original tail boundary and classify the tail as partial rather
   than silently completing, dropping, or repairing it.
6. After normal completion or recovery, close the journal and write `seal.json`
   once. The seal records termination and capture status and digests the exact
   journal plus every included raw object. The seal does not claim that captured
   assertions are true or that missing data never existed.
7. Treat sealed journal and object bytes as immutable. Later corrections,
   annotations, normalization, and evaluation are separately linked records and
   never alter the sealed raw material.
8. Record missing, truncated, redacted, or unrecoverable material explicitly. A
   seal may validly describe partial capture; it may not silently relabel it as
   complete.

The detailed record-kind catalog, exact field schema, redaction policy, and
capture hooks remain provisional until Scripted-provider tests exercise normal,
malformed, failed, interrupted, and partial cases. Those tests may revise this
decision before preregistration through a superseding ADR.

Do not add a per-record hash chain, SQLite, Ecto, Ash, or an event-store service
for the Phase 0 baseline. The seal's whole-journal and object digests provide
the initial post-seal integrity check. This does not claim protection against a
writer that is compromised before sealing.

## Rationale

The journal preserves temporal and causal facts in a format that remains usable
after a partial final write. Content-addressed objects preserve exact bytes
without making JSONL enormous or unable to represent malformed binary material.
A separate seal avoids a self-referential file digest and makes capture
completeness a declared status rather than an inference from a clean-looking
last line.

One journal also avoids premature partitioning. If commands, events, provider
interactions, and interventions later need different retention or access
policies, their already typed records can be projected or split through an
explicit amendment.

## Alternatives considered

- **JSONL only, with every payload inline:** easy to copy but inefficient for
  large data and unable to safely represent every exact byte sequence without
  encoding overhead.
- **Separate JSONL file for each record kind:** visually organized but creates
  multiple ordering, recovery, and sealing boundaries before volume justifies
  them.
- **Flight Recorder framing as the lab journal:** already append-written but
  normalized around Core replay and missing run-level capture facts.
- **One mutable JSON document:** simple after completion but rewrites history
  and makes interruption recovery and partial retention less explicit.
- **SQLite or a database framework:** useful when queries and concurrent writers
  demand it, neither of which is established for the pilot.
- **Per-record hash chaining:** can authenticate prefixes but adds canonical
  serialization and recovery complexity that a sealed single-writer file does
  not yet require.

## Consequences

- The Run Record has a small portable raw-capture nucleus with no new runtime
  dependency.
- Exact provider bodies, tool output, imported Session Store and Flight Recorder
  bytes, and file artifacts can share one object mechanism.
- Evidence locators resolve through stable run-owned records rather than
  ambiguous command text or mutable runtime paths.
- Phase 0 must test partial-line preservation, sequence and ID uniqueness,
  digest verification, duplicate-object handling, recovery, and partial seals.
- Syncing every record prioritizes pilot durability but its measured latency and
  write cost become operational-cost observations.
- Secret exclusion and redaction remain a required design decision; content
  addressing must never become a reason to capture credentials.
- Normalized observations and evaluations remain outside the sealed raw layer
  and retain derivation links to its journal records and objects.

## Revisit triggers

- Multiple independent writers are required for one run.
- Per-record syncing materially distorts the behavior or cost under study.
- Journals become too large for reliable inspection or batch processing.
- Access control or retention differs materially by record kind.
- Whole-file sealing cannot identify or recover the required interruption
  boundaries.
- A database comparison using real pilot queries demonstrates lower complexity
  or stronger correctness without replacing raw bytes as authority.

## Provenance

- [EXP-001 design thread](https://ampcode.com/threads/T-01a019d7-4ff1-75fa-9070-a705e5065b5c)
- [Harness Experimental Lab](../experiments/README.md)
- [EXP-001 Mission Receipt](../experiments/001-mission-receipt.md)
- [ADR-0003 — Preserve layered experimental records](0003-preserve-layered-experimental-records.md)
- [ADR-0011 — Use a typed evidence registry](0011-use-typed-evidence-registry.md)
- [ADR-0013 — Separate experiment records from runtime persistence](0013-separate-experiment-records-from-runtime-persistence.md)
