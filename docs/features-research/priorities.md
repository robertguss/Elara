# Runtime feature priorities

Captured 2026-09-06 from a review of both feature-research documents and checkout
`052a0a7`. This is a research assessment and prioritization reference.
[ROADMAP.md](../../ROADMAP.md) remains the sole implementation queue and status
source; this list does not schedule work or change existing milestone status.

The owner selected **live plugin discovery and reload** as the first experiment
and then authorized the focused test→fix→rerun workflow. Its decisions live in the
[Live plugin discovery and reload decision map](../../.scratch/live-plugin-runtime/map.md).
The assessment below describes the reviewed checkout before implementation;
consult `PLUGIN-1` in the roadmap and [Live plugins](../plugins.md) for the
resulting behavior. The first slice covers addition and revision; removal is deferred.

## Prioritization basis

Elara is an experimental project for understanding BEAM/Elixir as an agentic
coding runtime while becoming useful for the owner's coding work. Both goals
matter. The owner is actively developing Elara and has not begun daily use, so
practical-value ratings are hypotheses rather than observed productivity gains.

Favor a bounded experiment that changes what a session can do and builds on
existing mechanisms. Distinguish native BEAM benefits, such as supervision and
live module loading, from architectural choices such as pure reducers, replay,
durable storage, and immutable catalogs that are also possible elsewhere.

Complexity below describes an initial useful slice, not the complete vision.
The ordering expresses recommendations; only the leading experiment has been
selected for scoping. In particular, skill rescanning is a possible companion
feature, not an established prerequisite for plugin discovery.

## Priorities and feasibility

| Priority | Idea | Complexity | Assessment and practical boundary |
| --- | --- | --- | --- |
| Foundation | Reliable baseline and development lifecycle | Depends on the specific defect | Triage failures relevant to the experiment and clarify snapshot refresh versus plugin reload. Exercise existing detached sessions and multiple views. Atomic execution-stub replacement and draft restoration are useful when they remove actual development friction. Avoid making every unrelated defect a prerequisite. |
| Selected first experiment | Live plugin discovery, revision changes, and removal | Medium–high | Strongest combination of BEAM learning and potential utility. Existing compilation, state migration, generation leases, and idle-only reload provide a foundation. Define discovery scope, activation, removals, failure behavior, and continuity before implementation. Explicit activation between turns is the initial recommendation, still to be decided. |
| Near term | Skill rescanning | Low–medium | A small functional addition using existing discovery and prompt composition. Preserve historical loaded bodies, make revision changes clear, and bound catalog context. Useful, but offers little BEAM-specific evidence. |
| Next candidate | Agent-authored local tools | Medium–high within an explicitly trusted model | Build on plugin discovery using one practical project tool. Establish whether reuse/state/continuity improves work over an ordinary script. Model-driven activation and installation are separate capabilities; neither is implied by owner-triggered reload. |
| Next candidate | One supervised MCP integration | Medium–high | Potentially strong everyday value. Start with a needed server, one transport, and tool invocation. Verify its supported protocol. Namespacing, lifecycle, workspace/credential scope, and indeterminate mutations matter; broad resources/prompts/apps/subscriptions support can wait. |
| Next candidate | One event-driven wakeup source | Medium for one source | A strong BEAM experiment using existing durable inputs and thread-wait machinery. Begin with a concrete event such as job completion. Define deduplication, stop/pause behavior, and wake budgets. Prioritize this above a layout language or core self-patching. |
| Later | Per-agent capability profiles | Medium for static profiles; high for live changes | Existing research/coding child distinctions are a starting point. Child plugins are currently disabled. Add differentiated profiles when real assignments need them; runtime catalog changes require additional lifecycle and authority work. |
| Later | Catalog epochs and same-turn capability acquisition | High | Bind calls to the catalog/generation the model saw. Introduce the smallest identity/provenance contract needed by actual dynamic sources. A comprehensive `Runtime.Snapshot` is not automatically the first step. Activation between provider iterations requires new Core behavior beyond today's idle-only replacement. |
| Optional convenience | File-defined themes and client draft restoration | Low–medium | Theme files fit the existing Rust token system but provide little evidence about BEAM. Restoring local UI state across client replacement can improve development continuity. An independent server is required for live work to survive client exit. |
| Defer | Declarative layouts and extension-contributed panels | High | A layout/rendering language introduces focus, selection, state identity, validation, and compatibility work. First identify a useful panel or arrangement that existing widgets cannot adequately express. Keep rendering ownership in Rust. |
| Defer | Disposable extension lab and expiring capability grants | High–very high | Revisit when frequent generated code or stronger isolation is required. Define authority before execution and revocation during in-flight calls. A separate BEAM node is not an OS sandbox; stopping a process cannot undo effects or revoke already-copied credentials. |
| Research horizon | Replay-gated core actor handover | Very high | Interesting after extension lifecycles are dependable. Replay is a bounded Core regression check; it does not prove shell migration, external effects, or future behavior. Fix stale hook captures and define migration, authority transfer, and rollback limits before relying on core reload. |
| Research horizon | Distributed capability fabric | Very high | The existing executor router provides placement, health, load, affinity, workspace, and capability selection. Dynamic definitions, heterogeneous deployment, credentials, and workspace semantics remain substantial additional work. Require a concrete remote-execution need before generalizing. |

## Why the broader proposal should be reordered

[The live-capability exploration](elara-live-capability-runtime.md) usefully
separates presentation data, capability catalogs, extension processes, and core
authority. Its generation binding, provenance, activation boundaries, and
truthful mutation outcomes are valuable design constraints.

Its theme-first, layout-language-first sequence spends effort before establishing
agent-runtime utility. A useful plugin evolving within one session is a more
direct experiment. Introduce broader abstractions when concrete plugin/MCP
requirements justify them. [The hot-reload note](hot-reload.md) is closer to this
incremental approach, but understates the difference between a live-code probe
and a dependable core-upgrade operation.

## Grounding and limits

- TUI `session_reload` returns a snapshot in `lib/elara/server.ex`; chat reload
  invokes the plugin path. The short research note conflates these operations.
- `lib/elara/session.ex` reloads only existing plugin paths, and
  `lib/elara/session/core.ex` replaces tools only at idle. New-file discovery,
  removal, and same-turn activation are additional work.
- Plugin preparation handles ordinary compile, migration, and collision
  failures. Commits happen sequentially across plugin processes; this is not
  evidence of a crash-atomic multi-process transaction. Compilation and
  migration run trusted code and may themselves have side effects.
- `lib/elara/plugin.ex` lacks tool authority declarations; the plugin execution
  branch bypasses the ordinary capability check. Restricted or automatically
  acquired plugins require a deliberate authority contract.
- `lib/elara/plugin/loader.ex` assigns revision-specific module names and does
  not retire successful old generations. Frequent generated revisions need a
  bounded lifetime strategy. Unloading code alone does not reclaim atoms.
- `lib/elara/flight_recorder.ex` replays Core against recorded facts without
  rerunning tools/providers. Plugin descriptors retain logical version and
  generation, not a complete archived executable artifact. Replay matching is
  not proof of tool implementation equivalence or safe core migration.
- `lib/elara/skills.ex` discovers metadata once and rereads a selected body at
  load time. Discovery/revision semantics and catalog context cost need to be
  explicit when adding live refresh.

Verification in the review session: targeted plugin/skills/replay tests passed
23 tests; Rust passed 114 TUI tests and 6 execution-stub tests. The full Elixir
run passed 436/448 tests. Identified contributors included Linux `/proc`
assumptions in shell-liveness tests and default user-skill discovery affecting
context budgets. Timeout and session-discovery failures remained unresolved.
These results describe that local run, not a clean cross-platform baseline.

A controlled comparison discovered 77 user skills, adding about 35 KB of
catalog text. With one image, the fallback context budget requested handoff;
an empty catalog did not. Context estimates are conservative byte-based
estimates, not measured tokenizer occupancy. Live discovery should account for
this cost. The hot-reload document's isolated two-turn probe also reproduced
changed read-tool output followed by `{:match, 8}` from replay.

## Deferred evals

The owner explicitly deferred dedicated evals and benchmarking. They are not
part of the current decision map or a prerequisite for this experiment.
Ordinary regression tests and concrete acceptance scenarios remain appropriate.
Revisit an eval program as a separately scoped decision when desired.
