# Define catalog replacement and failure behavior

Parent: [Live plugin discovery and reload](../map.md)
Type: grilling
Labels: wayfinder:grilling
Status: resolved
Assignee: codex
Blocked by: 01

## Question

For the chosen workflow, what must remain authoritative when plugin discovery,
preparation, activation, invocation, or removal fails or overlaps other work?

Resolve discovery scope, including explicitly selected paths and `plugins: []`;
name/identity collisions; state migration; interrupted invocations and held
leases; and removal behavior. Specify the promised session, transcript, and
plugin-state continuity, including the boundary between a live session and a
later resumed session. Define how the owner/model learns which revision became
active and what happens if a plugin process dies during sequential commit.

Use the existing prepare/commit path as evidence, without assuming it already
provides crash-atomic multi-process activation or rollback of external effects.

## Answer

Implementation decision under the owner's 2026-09-06 execution authorization:
default-discovery sessions rescan their project plugin directory; explicit
selections remain fixed, including `plugins: []`. Prepare existing revisions,
stage new plugins, validate IDs and the combined tool table, then commit. On
ordinary validation/initialization/migration failure, stop staged processes and
abort prepared revisions. Existing session/process/state/history survive.

Reload stays idle-only and refuses an outstanding invocation lease. A missing
loaded path rejects reload; removing/unloading a plugin is deferred. The TUI
shows active IDs and versions after success. The next provider request uses the
updated tool table; recorded descriptors include generation information.

Plugin state is live-session state, not resumed-transcript state. Sequential
commit is not crash-atomic; callbacks can perform effects that rollback cannot
undo. Process death during commit remains outside this first slice's guarantee.
See [the user contract](../../../docs/plugins.md) for the exact boundaries.
