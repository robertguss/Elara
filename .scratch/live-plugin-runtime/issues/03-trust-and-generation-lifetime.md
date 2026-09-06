# Set plugin trust and generation lifetime limits

Parent: [Live plugin discovery and reload](../map.md)
Type: grilling
Labels: wayfinder:grilling
Status: resolved
Assignee: codex
Blocked by: 01

## Question

What trust and resource-lifetime contract is sufficient for the first plugin
workflow, and which stronger guarantees should be deferred?

Resolve whether activation is confined to trusted local code, which authority
declarations/checks the initial slice requires, and how restricted children are
treated. Account for code executed during compilation and migration, not only
tool invocation. Define a bounded policy for distinct revisions, held leases,
and old generations, with observable behavior when a limit is reached.

Keep a user-approved local trust model distinct from a claim of sandboxing.
Do not assume bounded module slots alone bound atoms created by arbitrary
source, or that retiring code reclaims existing atoms.

## Answer

Implementation decision under the owner's 2026-09-06 execution authorization:
retain Elara's existing trusted-local-code contract. Explicit controller
activation applies to both compile-time and runtime code; no sandbox or new
authority-grant system is introduced. Explicitly disabled plugins stay disabled,
including the existing restricted child-session configuration.

The accepted workflow is a bounded two-version experiment. It does not establish
a general resource-lifetime policy. Existing invocation leases remain in force;
successful modules remain loaded, and no automatic retirement or generation cap
is added. Restart the runtime to reclaim these generations. Automated or
unbounded generated-plugin experiments require a separately scoped lifetime and
isolation design. These limits are documented rather than claimed as solved.
