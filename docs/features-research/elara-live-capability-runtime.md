# Elara: Repository Findings and Live Capability Runtime Exploration

Captured: September 6, 2026  
Repository: https://github.com/robertguss/Elara  
Inspected revision reported in the discussion: `9f92a4c`  
Status: Research discussion and proposed direction; not an approved implementation specification.

## About this document

This document consolidates the supplied repository-research summary and the subsequent exploration of live themes, layouts, skills, plugins, MCP servers, tools, and BEAM runtime evolution. It preserves the substantive findings, recommendations, examples, and experiment order.

This capture does not independently repeat the repository inspection, external research, or tests. Current-state statements describe the earlier inspection. Protocol-version claims and external specification details below are recorded as claims from that discussion and must be revalidated before implementation. The original search citation handles were not portable sources, so they are omitted; explicit URLs supplied in the discussion are retained. The earlier interactive visualization is represented here by a standalone boundary table.

## 1. Motivation and desired outcome

The starting question was whether Elara could hot-reload its TUI themes and layouts without killing a live session. The larger objective is to explore what its Elixir/BEAM authority and Rust process boundaries make possible:

- Load skills, MCP servers, plugins, and tools mid-session and on demand.
- Preserve session identity, history, state, and continuity as capabilities change.
- Move beyond cosmetic demos toward meaningful changes in what the harness can do.
- Explore ambitious extensions of supervision, persistent sessions, replay, and dynamic processes.

The proposed product concept is a **live capability runtime**: replacing versioned capability catalogs and supervised processes while preserving session identity, state, evidence, and mutation honesty.

## 2. Repository orientation

The preceding research reported a clean clone at `9f92a4c`, with no repository files changed. Its inspection covered documentation, history, Elixir runtime, Rust programs, persistence, providers, protocols, plugins, threads, handoffs, and tests. It also reported reviewing 24 external sources across Elara's public footprint, toolchains, TUI stack, and adjacent BEAM-agent projects.

### Architecture and implementation model

- Elara is a source-run, BEAM-native coding agent.
- `Elara.Session.Core` is the pure deterministic reducer.
- `Elara.Session` is the authoritative actor serializing persistence, provider work, tools, input delivery, recovery, and handoff.
- Rust occupies two process boundaries: a Ratatui client using protocol v2 and a cancellable execution guardian behind an Erlang Port. There are no NIFs and no Rust-owned session policy in the inspected design.
- Persistence combines tree-shaped JSONL conversations, SQLite effect ledgers, deterministic flight recordings, durable input receipts, and file-backed thread transport.
- The built-in `write` tool has receipt-backed recovery and explicit indeterminacy. The earlier review did not find the same production guarantee for `edit`, `bash`, plugins, or remote execution.
- Persistent children are real sessions. Coding children receive Git worktrees; research children share the checkout with restricted tools.
- Thread communication uses stable message identities, receipts, bounded wakeups, and preserved original evidence.
- Context exhaustion creates a linked successor session with an extractive index, transfers queued ownership, and preserves source threads for later evidence retrieval.
- Providers include OpenAI-compatible APIs, Grok OAuth, and a subscription-backed Codex adapter using the ChatGPT backend. The adapter privately preserves encrypted continuation state while exposing public reasoning summaries, commentary, answers, and usage.
- The Rust TUI includes three layouts, four themes, multiline editing, search/copy, typed tool inspection, attachments, queue/steer, session management, thread navigation, and automatic handoff following.

### Project status reported at inspection

- The next substantive milestone was `SPLIT-5`, described as a two-week/five-working-day daily-driver trial followed by a keep-or-reverse decision on the Elixir/Rust split. The exact trial-duration wording should be clarified when planning execution.
- `ROADMAP.md` said TUI-8 was uncommitted despite commit `b972b27`; the detached guide also understated current TUI lifecycle features.
- The project was reported to be approximately three weeks old, with 162 commits and no open issues, open PRs, CI checks on HEAD, releases, tags, or license file.
- Repository integrity, tracked diffs, JSON fixtures, Python PTY helpers, shell syntax, and worktree cleanliness were checked successfully in the preceding work.
- Mix and Cargo verification could not be reproduced because `elixir`, `mix`, `rustc`, and `cargo` were absent from that runtime's PATH.
- The implementation record reported 448 Mix tests, 113 TUI tests, and six execution-stub tests. These were project-reported results, not independently executed results from the research session.

## 3. What can change in a live session today?

| Target | Behavior reported in the inspected code | Does the session survive? |
| --- | --- | --- |
| Switch a built-in theme or layout | Immediate switching through F3 and `Model.set_appearance/1` | Yes |
| Edit Rust theme/layout source | The running TUI cannot load newly compiled Rust machine code | A long-lived server can preserve the session while the client restarts and reattaches |
| Reload an existing plugin file | `Elara.reload_plugins/1` and chat `/reload` | Yes |
| Add or remove plugin files | Reload only revisits original plugin paths | Not implemented as live catalog discovery |
| Load a discovered skill body | Existing `skill` tool | Yes |
| Discover a newly created skill | Discovery catalog fixed at session startup | No live rescan implemented |
| Register remote execution capacity | Workers can register live | Yes; does not itself introduce new tool definitions |
| Attach MCP servers or tools | Not implemented | Requires lifecycle machinery |
| Reload Elara core modules | Technically possible on BEAM | Not currently a safe, guaranteed product operation |

### Command ambiguity

Chat `/reload` reloads plugins, whereas TUI `/reload` sends `session_reload`, which only requests a fresh snapshot. Proposed distinct commands:

- `/refresh`
- `/plugins reload`
- `/skills rescan`
- `/mcp status`
- `/ui reload`

### Relevant repository files

- `native/elara-tui/src/appearance.rs`
- `native/elara-tui/src/presentation.rs`
- `lib/elara/plugin/server.ex`
- `lib/elara/plugin/loader.ex`
- `lib/elara/session.ex`
- `lib/elara/session/core.ex`

## 4. BEAM live-code behavior and its limits

The earlier exploration reported research across 154 search results, focusing on OTP 29, Elixir 1.20, MCP `2026-07-28`, and primary specifications. These version references are preserved as research context, not newly verified compatibility targets.

### Module code and process state are separate concerns

BEAM can maintain current and old versions of a module. Fully qualified calls enter current code while a process may remain in old code. Loading another version can require purging the oldest; purging code still in use can terminate affected processes. A deliberate upgrade protocol must account for this behavior.

Updating GenServer code does not automatically migrate process state. State changes require a coordinated mechanism such as `code_change/3` through OTP system messages or release handling: suspend, load, migrate, and resume.

Elixir's `Code.compile_file/2` and `Code.compile_quoted/2` can compile modules inside the live VM. Compilation alone is not a complete upgrade protocol.

### Existing plugin generation design

The inspected plugin implementation was described as a small custom live-upgrade system:

1. Each source revision compiles to an immutable, content-addressed module name.
2. Mutable plugin state lives in a persistent `Plugin.Server` process.
3. Tool calls lease a specific generation.
4. Reload prepares every candidate and migration before replacing the tool table.
5. Compile failures, migration failures, and name collisions preserve the old active generation.
6. Different sessions may stay on different revisions.

### Generation growth and isolation

Every distinct revision creates a module atom, and the inspected implementation did not unload successful old revisions. Atoms are not garbage-collected. Frequent file watching or agent-generated revisions therefore needs a bounded strategy before becoming a routine feature.

Two proposed strategies:

- **Bounded module slots:** reference counting, lease drainage, `soft_purge`, and safe slot reuse.
- **Disposable extension nodes/processes:** recycle an extension runtime to reclaim its atom and code universe.

A separate BEAM node can improve failure and memory isolation, but is not an OS security sandbox. Untrusted extensions require appropriate process/container, filesystem, network, and credential isolation.

## 5. Recommended runtime architecture

### Separate four replacement mechanisms

| Boundary | Replaceable unit | Owner and continuity strategy |
| --- | --- | --- |
| Presentation data | Theme specifications and declarative layouts | Rust validates and atomically replaces presentation data while preserving widget state |
| Capability catalog | Skills, tools, plugin bindings, MCP bindings, grants | Elixir commits immutable catalog epochs at explicit activation boundaries |
| Extension process | Plugin generation, MCP transport, remote/disposable worker | Supervision stages replacements and drains or retires old processes |
| Core authority | Session actor/code and state | Later research: replay-gated migration and actor handover |

### Immutable runtime snapshot

```elixir
%Elara.Runtime.Snapshot{
  epoch: 17,
  system_digest: "...",
  tools: %{"read" => binding, "mcp.github.search" => binding},
  skills: %{"reviewing-code" => revision},
  extensions: %{"github" => generation},
  grants: MapSet.new(["filesystem:read", "github:read"]),
  digest: "..."
}
```

Each session uses one snapshot epoch. The proposed replacement lifecycle is:

1. Discover.
2. Prepare.
3. Validate.
4. Authorize.
5. Commit the new epoch.
6. Drain the old generation.

### Essential invariants

1. Every provider request receives one exact catalog epoch.
2. Tool calls bind to the generation the model saw.
3. Preparation may overlap ongoing work, but ordinary activation occurs only when no provider response or ordinary tool invocation is in flight.
4. If an always-present `capability_request` tool triggers mid-turn activation, it is the sole call in that batch. Commit the new catalog before the next provider iteration.
5. Compilation, schema validation, migrations, collision checks, and permission checks happen before activation.
6. Activation is all-or-nothing; failure preserves the previous snapshot.
7. Record extension changes with artifact and schema digests so replay and resume cannot silently substitute code.
8. Extensions cannot grant themselves additional authority.
9. Preserve causal honesty: transport loss after a mutation attempt is indeterminate and must not cause a blind retry.

This generalizes the existing plugin prepare/commit/lease machinery.

## 6. Live themes and layouts

### Theme files

Keep theme ownership in Rust. Replace the fixed `Theme` enum with a registry of validated specifications, using locations such as:

```text
~/.elara/themes/*.json
project/.elara/themes/*.json
```

Embed built-in themes as fallbacks. A watcher should:

1. Read changes after an atomic rename settles.
2. Parse semantic tokens.
3. Validate completeness and contrast.
4. Atomically replace the registry entry.
5. Repaint immediately.
6. Preserve the previous theme and display a notice if validation fails.

This enables zero-restart theme editing while retaining the centralized semantic-color pass.

### Layout options

| Approach | Result | Recommendation |
| --- | --- | --- |
| Rebuild/relaunch Rust client and reattach | Arbitrary Rust changes with a brief client restart | Development fallback |
| Declarative `ViewSpec` interpreted by Rust | Live rearrangement of known widgets | Best next step |
| BEAM plugin emits a versioned render tree | Extension-contributed UI surfaces | Explore later |
| Rust dynamic libraries | Arbitrary native extensions with ABI and safety complexity | Avoid |

A `ViewSpec` can describe named panes, rows/columns, constraints, breakpoints, and bindings to transcript, thinking, composer, tools, threads, and diagnostics widgets. Stable widget IDs preserve focus, scroll anchors, selection, expanded tools, and draft state across reloads.

### Arbitrary Rust changes without losing the session

1. Run `mix elara.server` as the long-lived authority.
2. Serialize a local `UiCheckpoint`.
3. Build and re-exec the TUI.
4. Reattach and restore the checkpoint.

The session survives the client replacement. Missing work includes preserving drafts, selection, attachments, and local view state.

## 7. Live skills, plugins, and tools

### Skill rescanning

Skills are the simplest functional starting point. The earlier inspection found that Elara retains discovery options and rebuilds project instructions before asks. The proposed change is to evolve `refresh_instructions/1` into `refresh_runtime_context/1`, including skill discovery.

Required revision semantics:

- A catalog refresh makes a new skill discoverable.
- Loading a skill body pins a content digest.
- Editing a previously loaded skill must not silently rewrite instructions already in the conversation.
- A new revision explicitly supersedes the previous revision or activates at the next turn/handoff.

### Plugin add/remove/rescan

Current reload iterates `shell.plugins`. A complete rescan should classify files as unchanged, upgraded, added, or removed.

Stage new plugin processes under the supervisor, prepare existing-state migrations, mark removals as draining, and validate the complete tool table before one atomic commit.

### Authority gap to close

The earlier review reported that `Plugin.ToolSpec` declares only name, description, and schema; plugin tools default to non-mutating/no capabilities; and the plugin execution clause precedes the ordinary capability check.

This fits a wholly trusted plugin model but is insufficient for model-driven activation. Proposed host-enforced declarations include:

- Required capabilities.
- Mutating/read-only classification.
- Placement.
- Trust source and artifact digest.
- Credential handles.
- Optional expiry and scope.

Enforce authority centrally before both plugin and ordinary tool execution.

## 8. MCP integration

### Protocol assumptions captured from the discussion

The prior answer identified MCP `2026-07-28` as current and stated that it replaced the previous initialization/session model with per-request protocol and capability metadata. It also named `server/discover`, `subscriptions/listen`, and `notifications/tools/list_changed` as relevant mechanisms. These claims need verification against the actual supported protocol before implementation; this document records them rather than establishes them.

Explicit references supplied in the discussion:

- https://modelcontextprotocol.io/docs/2026-07-28/learn/versioning
- https://modelcontextprotocol.io/specification/2026-07-28/architecture
- https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2640

The discussion described tool catalogs as changeable, deterministic, and cacheable, with notifications prompting a catalog refresh.

### Proposed client process

Use an `Elara.MCP.Client` process per server to:

- Supervise stdio or HTTP transport lifecycle.
- Discover supported versions and capabilities.
- Namespace tool names, for example `mcp.github.search_code`.
- Translate JSON Schema into `Elara.Tool` bindings.
- Subscribe to supported catalog/resource changes.
- Reconnect with backoff after failure.
- Mark transport loss after mutating attempts as indeterminate.
- Expose only the session's cwd/worktree and approved credentials.
- Treat tool annotations as untrusted hints; Elara policy owns authority classification.

### Conceptual mapping

| MCP primitive discussed | Proposed Elara interpretation |
| --- | --- |
| Tools | Versioned runtime tool bindings |
| Resources | Searchable/readable evidence sources |
| Prompts | Workflow templates or skill candidates |
| Subscriptions | Durable inbox events and agent wakeups |
| Multi-round-trip input | Paused tool requiring owner input in the TUI |
| Tasks extension | Long-running work surviving turns and detach |
| MCP Apps | Possible future declarative panes/forms rendered by the TUI |

These are architectural mappings, not claims that every primitive directly supports native terminal rendering or is implemented in Elara.

The previous discussion described SEP-2640, Skills over MCP, as a draft/in-review extension proposing `skills/list`, `skills/get`, digested manifests, and skill resources. The recommendation was an experimental adapter, without coupling Elara's internal skill model to an unfinished specification.

## 9. Possibilities unlocked by a live capability runtime

### 9.1 Just-in-time capability acquisition

Keep a bootstrap tool permanently available:

```text
capability_request(
  intent: "inspect the customer PostgreSQL schema",
  scope: "turn",
  trust: "workspace-approved"
)
```

The manager resolves an installed plugin or MCP server, starts it, validates tools, obtains any required grant, commits an epoch, and continues the same user turn with the new tools.

This avoids putting hundreds of schemas into every request and allows the harness to acquire the instrument needed for its current task.

### 9.2 Self-authored tools with a promotion pipeline

An agent could:

1. Write a project-specific plugin.
2. Compile it inside a disposable extension cell.
3. Run contract tests and read-only probes.
4. Present the requested authority delta to the owner.
5. Activate it for the current session.
6. Use it immediately.
7. Promote it to project or user scope after it proves useful.

The demonstration is a harness creating and using a missing instrument without losing context. Activation remains distinct from installation: downloading code, modifying dependency files, or expanding credentials is a separately authorized mutation.

### 9.3 Ephemeral capability leases

Possible lifetimes include one invocation, one turn, until handoff, until revocation, or persistent workspace scope.

A database credential, production log reader, or deployment capability can be confined to a supervised process. The proposal is to stop that process on revocation and remove bindings through the catalog lifecycle. The implementation must define the exact revocation behavior for calls already in flight.

### 9.4 Event-driven sleeping agents

Resource subscriptions, filesystem watchers, test runners, CI events, and review feedback can enter the durable input queue. Agents can wake when:

- Tests fail.
- A build finishes.
- A PR receives review.
- A watched file changes.
- A background task needs input.
- A child sends evidence.

This extends the event-driven `thread_wait` approach into a general reactive harness.

### 9.5 Per-agent capability topologies

Because children are full sessions, each can receive a distinct catalog:

| Role | Example capabilities |
| --- | --- |
| Research | Documentation/search services, read-only workspace |
| Coding | Compiler, LSP, worktree mutation |
| Reviewer | Static analysis, security scanners |
| Release | Signing/deployment with short-lived credentials |

Capabilities become part of an agent's role and can evolve without replacing its identity.

### 9.6 Replay-gated core upgrades

The pure Core and flight recorder suggest a later experiment:

1. Load a candidate Core generation.
2. Replay recorded session facts against it.
3. Compare normalized state and effects.
4. Migrate/checkpoint shell state.
5. Switch a stable session proxy to the candidate actor.
6. Retain the old actor as a possible rollback target.

The idea is to verify reproduction of past behavior before transferring authority. Replay is an upgrade gate, not proof that every future behavior is safe; rollback behavior must also account for effects performed after handover.

Read-only plugin calls could be shadowed against old and candidate generations to compare results. Never shadow-run mutations.

### 9.7 Extension-contributed TUI surfaces

Extensions could contribute typed declarative data and actions for panels showing:

- Test progress.
- Git diff navigation.
- Process and supervision trees.
- Database schemas.
- Deployment state.
- Thread topology.
- Effect receipts and uncertainty.

Rust retains rendering and interaction ownership. Terminal adaptation of external app surfaces would require a defined supported schema.

### 9.8 Distributed capability fabric

The inspected executor router already models placement, health, affinity, load, workspace, and capabilities. With dynamic tool definitions and an extension catalog, a logical tool could be supplied by:

- A local BEAM plugin.
- A local Rust/OS process.
- An MCP service.
- A remote worker.
- A disposable container.
- A specialist child session.

The model requests a capability; Elara determines where it should execute under its authority and workspace constraints.

## 10. Recommended experiment order

1. **Separate commands and process lifetimes.** Make the detachable server the normal development mode and use `/refresh` for a fresh snapshot.
2. **Hot-load theme files.** Prove watching, validation, atomic replacement, fallback, and live diagnostics.
3. **Introduce declarative `ViewSpec`.** Rearrange existing widgets without loading native code.
4. **Introduce `Runtime.Snapshot` and `catalog_epoch`.** First cover existing tools, skills, and plugins without changing behavior.
5. **Add live skill rescanning and plugin add/remove.** Address plugin authority classification and generation-memory growth before frequent or agent-driven reloads.
6. **Integrate one MCP server.** Verify the supported protocol, then implement discovery, listing, supported subscriptions, namespacing, reconnect, and uncertainty semantics.
7. **Add `capability_request`.** Activate installed capabilities between provider iterations during the same turn.
8. **Build the disposable extension lab.** Compile, test, inspect, activate, and retire agent-authored plugins.
9. **Explore replay-gated core actor handover.** Treat this as advanced research after the capability lifecycle is proven.

## 11. Defining acceptance scenario

> A session asks for an unavailable capability. Elara stages and activates it. The next provider iteration uses it. A broken candidate leaves the old runtime untouched. The session ID, transcript, and draft remain intact. Replay records exactly which code and tool catalog were authoritative.

## 12. Proposed direction

Use **live capability runtime** as the working name. Hot reload is one mechanism within it. The larger goal is a supervised harness that can change what it knows how to do, with explicit authority and provenance, without losing the session that discovered the need.

This discussion establishes an exploration direction and experiment sequence. It does not authorize repository changes or settle the remaining implementation contracts, protocol compatibility, migration rules, or production guarantees.
