# Harness: A BEAM-Native Fabric for Software Work

> **Status:** Design exploration  
> **Updated:** August 2026  
> **Purpose:** Capture the architectural ideas, product primitives, risks, and
> experiments behind evolving Harness beyond a conventional coding-agent CLI.

## Executive thesis

Harness should not become “Pi, but written in Elixir,” nor should its ambition
stop at running more agents in more containers.

The larger opportunity is to build a **durable, supervised fabric of software
work**:

> Software work is a durable causal graph interpreted by supervised actors,
> executed in isolated workspace cells, and accepted through evidence-bearing
> gates.

In this model:

- A model is a replaceable reasoning component.
- A sandbox is a replaceable execution body.
- A BEAM process is the current live embodiment of a durable entity.
- The durable mission, effects, evidence, identity, and causal history are the
  product.

The process is not the agent. **The durable history and identity are the agent;
a process is its current incarnation.**

## From agent loop to software-work runtime

Most coding harnesses can be reduced to this shape:

```text
Prompt ──▶ Model loop ──▶ Tools ──▶ Sandbox ──▶ Answer
```

Harness could become a larger control and execution fabric:

```text
                         ┌─────────────────────┐
                         │ Human control room  │
                         └──────────┬──────────┘
                                    │ commands / approvals
                                    ▼
┌───────────────────────────────────────────────────────────────┐
│                  BEAM control fabric                          │
│                                                               │
│  ┌─────────┐  ┌──────────┐  ┌───────────┐  ┌──────────────┐  │
│  │ Project │─▶│ Missions │─▶│ Sessions  │─▶│ Verification │  │
│  │ Reactor │  │          │  │           │  │ Gates        │  │
│  └─────────┘  └──────────┘  └───────────┘  └──────────────┘  │
│        │             │             │                │          │
│        └─────────────┴──── causal journal ──────────┘          │
└───────────────────────┬───────────────────────────────────────┘
                        │ durable jobs + capability grants
                        ▼
┌───────────────────────────────────────────────────────────────┐
│                     Workspace cells                           │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐  │
│  │ Local cell   │  │ Cloud VM     │  │ Specialized worker │  │
│  │              │  │ / container  │  │ GPU/device/browser │  │
│  └──────────────┘  └──────────────┘  └────────────────────┘  │
└───────────────────────┬───────────────────────────────────────┘
                        │
                        ▼
             Artifacts, patches, evidence, receipts
```

This is closer to an **operating system for software work** than a coding-agent
CLI.

---

## Design principles

### 1. Durable identity, temporary process

Every important logical entity has:

- A stable ID.
- A journal of accepted facts.
- A reducer and reducer version.
- State reconstructed from a snapshot plus journal tail.
- Parent and causal relationships.
- An ownership lease and fencing epoch.
- Pending effect receipts.
- Zero or one active BEAM process.

```text
Durable entity
    │
    ├── snapshot
    ├── journal tail
    ├── pending effect receipts
    └── causal links
           │
           ▼ activation
      ┌───────────┐
      │ GenServer │  current embodiment
      └───────────┘
           │
           ▼ passivation / crash
     durable entity remains
```

Idle entities should passivate. A command or subscribed event can activate them
on any trusted control node that acquires the fenced ownership lease.

### 2. The BEAM is the control plane, not the sandbox

BEAM should own:

- Lifecycle and ownership.
- Mailbox serialization.
- Supervision and failure detection.
- Cancellation and deadlines.
- Coordination and joins.
- Live observability.
- Policy and plugin execution inside the trusted boundary.

External systems should own what they are better suited to own:

- Durable transactional storage.
- Content-addressed artifacts.
- Containers and VMs.
- Workspace snapshots.
- Strong tenant isolation.
- Secret and egress boundaries.

Distributed Erlang can be useful inside one tightly controlled control-plane
trust zone. It should not be the tenant or worker security protocol.

### 3. Supervision is not durability

OTP can restart an interpreter or connection proxy. It cannot determine whether
an external mutation completed before a machine died.

Supervisors restart processes. **Effect receipts and reconciliation recover
work.**

### 4. Uncertainty is a first-class outcome

Harness should distinguish:

- Confirmed not submitted.
- Accepted but still running.
- Confirmed completed.
- Confirmed failed.
- Cancelled.
- Outcome indeterminate.

It must never silently retry an uncertain mutation on another worker.

### 5. Evidence, not confidence

Agent prose is not proof. Consequential results should carry claims, artifacts,
test evidence, tool receipts, uncertainty, versions, and approvals.

### 6. Bounded missions, not autonomous swarms

Agents should receive typed objectives, explicit capabilities, deadlines,
budgets, deliverables, and verification policies. They should exchange retained
artifacts and structured results, not participate in an endless shared chat
room.

---

## Sub-agents as Missions

The original idea—run tool work in another process so the parent context remains
focused—is what other harnesses commonly call a sub-agent. The important
distinction is not process isolation by itself.

```text
Process-isolated tool
  Runs elsewhere
  Returns raw output
  Parent still absorbs that output

Sub-agent / Mission
  Has a separate model context and tool transcript
  Performs a bounded objective
  Returns a compact, complete work product
  Retains details outside the parent context
```

### Why `delegate` should be Session-owned

The model-facing operation should be a built-in `delegate` tool handled by the
parent Session, not a normal plugin.

A Session owns:

- Parent identity.
- Child lifecycle.
- Turn interruption.
- Deadlines.
- Capability inheritance.
- Recursion policy.
- Child retention.
- Causal recording.

A plugin currently lacks the parent-session authority required to manage these
safely. Extending plugin context with that authority would blur execution and
lifecycle boundaries.

### Delegation topology

```text
┌─────────────────── Parent Session ───────────────────┐
│                                                      │
│ Model requests delegate                              │
│          │                                           │
│          ▼                                           │
│ Session owns child lifecycle, deadline, cancellation │
│          │                                           │
└──────────┼───────────────────────────────────────────┘
           ▼
┌──────────────── Child Session ────────────────┐
│ Separate model context and tool transcript    │
│ Fresh child-owned plugin instances            │
│ No delegate tool in v1                        │
│ Complete final response retained here         │
└──────────────────┬────────────────────────────┘
                   │ complete result or semantic summary
                   ▼
           Parent tool result
```

### Proposed input protocol

Initial delegation:

```json
{
  "task": "Trace plugin reload cancellation and identify any race",
  "context_mode": "fresh"
}
```

Follow-up with the same child:

```json
{
  "child_session_id": "child-123",
  "task": "Expand on the lease race and quote the relevant functions"
}
```

Host policy—not the model—controls raw timeout, recursion depth, persistence,
capability ceilings, and emergency transport limits.

### Context modes

- **`fresh`**: repository system prompt, repository instructions, working
  directory, and delegated task only.
- **`minimal`**: latest parent user request plus the delegated task.
- **`inherited`**: settled parent transcript plus the delegated task.
- **Continuation**: the existing child transcript plus the new follow-up task.

The recommended default is `fresh`. Delegation prompts should be self-contained,
and accidental history cloning undermines context isolation.

“Settled” history matters: the live parent transcript contains the unresolved
`delegate` tool call. A child must receive the prefix before that call, not
malformed in-flight history.

### Child capabilities

A child should receive:

- The same working directory and repository instructions.
- Parent built-in and custom tools.
- The same capability ceiling, workspace, and executor router.
- Newly loaded child-owned instances of the same plugins.
- No `delegate` tool in v1.

Plugin state is fresh. Parent plugin references must not be copied because they
point to parent-owned processes and generations.

### Cancellation and recursion

Recommended v1 policy:

- One active delegation per parent.
- Delegation depth exactly one.
- Delegated children do not advertise `delegate`.
- Parent interruption interrupts and stops the child.
- Parent termination stops or durably orphans children according to explicit
  policy.
- Delegation has a dedicated absolute deadline, longer than the normal tool
  timeout.
- Cancellation never pretends to roll back effects that already happened.

### No blind result truncation

Blindly slicing a child answer at an arbitrary byte boundary is unsafe. It can
remove the conclusion, qualification, or decisive evidence while presenting the
remainder as complete.

The result should be a structured envelope:

```json
{
  "v": 1,
  "status": "completed",
  "child_session_id": "child-123",
  "delivery": "summary",
  "content": "The reload race occurs when...",
  "more_available": true,
  "continuable": true,
  "retention": "parent_session"
}
```

Delivery modes:

- **`full`**: complete child result is returned intact.
- **`summary`**: the child semantically compressed its complete original result.
- **`metadata_only`**: semantic compression failed, but the full child result
  remains retained and addressable.

```text
Child completes work
        │
        ▼
Persist complete answer in child transcript
        │
        ▼
Fits parent result budget? ── yes ──▶ delivery: full
        │
        no
        ▼
Ask child once for semantic compression
        │
        ▼
Fits safely? ── yes ──▶ delivery: summary + child ID
        │
        no
        ▼
delivery: metadata_only + child ID + more_available
```

There is still a finite transport ceiling because the parent context is finite.
It becomes an internal invariant, not the summarization mechanism. The envelope
must fit before it reaches Harness’s generic tool-result truncator; content is
never silently byte-sliced.

### ChildSession beneath Delegate and Coordinator

Do not implement delegation as a one-item `Coordinator.run(:parallel, ...)`
call. Extract a smaller lifecycle primitive:

```text
start child
ask child
continue child
interrupt child
stop or passivate child
```

`delegate` owns single-child model-facing policy. Coordinator owns fan-out,
candidates, judges, reducers, worktrees, and aggregate budgets. Both use
`ChildSession`.

---

## Layered target architecture

### Plane 1: Durable truth

Use three related stores:

1. **Entity journal** — commands, accepted facts, transition decisions, effect
   intents, completions, migrations, and approvals.
2. **Immutable content graph** — transcripts, prompts, patches, command output,
   test reports, environment manifests, and other large artifacts addressed by
   digest.
3. **Query projections** — current status, session lists, trees, dashboards,
   search, and event feeds.

The canonical transition boundary should be:

```text
validate fact
   │
   ▼
run pure reducer
   │
   ▼
atomically append:
  fact + transition metadata + domain events + effect intents
   │
   ▼
dispatch effects separately
   │
   ▼
append completion or reconciliation facts
```

Historical outbox entries are not blindly replayed merely because a process
restarted.

Local Harness can use an embedded journal. A hosted deployment can use a boring
transactional database plus object storage. Distributed Erlang and process
registries are not databases.

### Plane 2: Activated entity actors

```text
Project
├── Sessions
│   ├── Missions
│   │   └── Child sessions
│   └── In-flight job proxies
├── Workspace leases
├── Verification gates
└── SDLC reactors
```

This is a logical ownership graph, not necessarily one giant physical OTP link
tree. Processes are supervised by type on whichever trusted node currently owns
the durable entity lease.

### Plane 3: Remote workspace cells

Remote execution evolves from one-shot tool RPC into durable cells:

```text
submit(job_id, operation_digest, workspace_epoch, policy, deadline)
accepted(receipt)
query(job_id)
stream(job_id, cursor)
cancel(job_id)
result(job_id, outcome, artifact_digests)
```

Job states:

```text
planned → submitted → accepted → running
        → completed | failed | cancelled | indeterminate
```

A Workspace Cell provides:

- Immutable base plus writable overlay.
- One fenced mutation lease per overlay.
- CPU, memory, disk, process, and time bounds.
- Secret and egress policy.
- Durable job ledger.
- Resumable event stream.
- Patch, commit, and artifact export.
- Provider-independent lifecycle: local, container, VM, Kubernetes, hosted orb,
  or customer runner.

### Plane 4: Evidence and provenance

Consequential results carry:

- Claims made.
- Source workspace snapshot.
- Resulting patch digest.
- Model, provider, tool, plugin, prompt-policy, and reducer versions.
- Commands and effect receipts.
- Tests, builds, static analysis, reviews, and benchmarks.
- Known uncertainty.
- Human approvals and policy versions.

An independent verifier generally receives the claim, code snapshot, and
evidence requirements—not the candidate’s entire persuasive transcript.

### Plane 5: Gateways and collaboration

Clients become views onto durable entities:

- CLI.
- IDE.
- Web control room.
- API.
- CI adapters.
- Webhook adapters.
- Human approval queues.

Multiple participants observe the same event stream, but each entity retains one
serialized command order. Concurrent proposals branch or wait for leases rather
than racing over shared mutable state.

### Plane 6: Project reactors

Project Reactors are long-lived, mostly passivated repository automata. They
wake for issue, PR, CI, deployment, dependency, review, schedule, or incident
events; create bounded Missions; wait for humans or systems; and resume after
hours or machine loss.

---

## Flagship product primitives

### 1. Living Session

A stable session identity that can detach, reattach, passivate, restart, migrate
nodes, fork from history, and recover unresolved effects.

### 2. Mission

A typed, parent-owned work contract with its own context, transcript,
capabilities, deadline, budget, deliverable, verification policy, and
continuation identity.

### 3. Workspace Cell

A recoverable execution environment independent of its current machine, with
snapshots, overlays, fenced mutation, durable jobs, and artifact export.

### 4. Effect Receipt

Every external effect has a stable ID, retry class, acceptance receipt, status,
and reconciliation path.

### 5. Evidence-Carrying Result

A result contains claims, artifacts, evidence, uncertainty, and provenance
rather than unsupported prose alone.

### 6. Causal Fork

Trace a patch or decision back through parent requests, Missions, jobs,
evidence, and approvals; then fork or inject counterfactual facts from any
causal point.

### 7. Human-Agent Control Room

A durable collaborative event space with principals, roles, proposals,
approvals, handoffs, branches, and mutation leases.

### 8. Project Reactor

A supervised repository-level automaton that responds durably to SDLC events and
orchestrates bounded work.

### 9. Shadow Runtime

Replay recorded facts against new reducers, prompts, routing policies, plugins,
and verification policies before canarying or migrating live entities.

---

## Speculative directions

### Repository memory as a provenance graph

Store architectural decisions, invariants, ownership, prior failed approaches,
incidents, and API contracts as durable facts linked to the exact source
snapshots and evidence supporting them. Facts become stale or uncertain when
supporting code changes.

Context assembly becomes the construction of a small provenance-bearing capsule,
not unbounded vector search or transcript stuffing.

### Software immune system

Mostly sleeping sentinels watch for dependency risk, performance regression,
flaky tests, security-sensitive changes, API drift, and violated invariants.
They open bounded investigation Missions and propose containment, rollback, or
repair through policy gates.

### Many-worlds development

For genuinely uncertain architecture work, fork several workspace snapshots,
assign explicit competing hypotheses, run identical evaluation suites, compare
evidence, and preserve losing branches as searchable knowledge.

### Agent portfolios

Schedule work by measured capabilities rather than permanent personalities:
search model, implementation model, static analyzer, fuzzer, device lab, and
independent verifier. Learn cost, latency, and success distributions from
evidence.

### Counterfactual CI

Ask not only “does this commit pass?” but also:

- Which causal assumption changed?
- Would the prior verification policy have accepted this?
- Does a new policy invalidate earlier work?
- Which historical patches depended on the broken invariant?
- Can relevant Missions be replayed against the changed dependency?

### Executable governance

Versioned policies determine tool access, secret grants, approval requirements,
mutation autonomy, risk levels, and mandatory evidence. A blocked action
produces a causal explanation rather than an opaque denial.

### Incident-to-patch continuity

Operational symptoms, investigation, rollback, diagnosis, patch, tests, release,
and postmortem become one causal graph that survives shifts, handoffs,
environments, and process failures.

---

## Failure semantics

| Failure                                     | Required behavior                                                                       |
| ------------------------------------------- | --------------------------------------------------------------------------------------- |
| Session process or VM dies                  | A new owner rehydrates the entity and reconciles pending effect receipts.               |
| Provider call disappears                    | Record the lost attempt. Retry only as an explicit, new, budgeted attempt.              |
| Worker disconnects before acceptance        | Resubmit the same job ID elsewhere if policy permits.                                   |
| Worker disconnects after accepting mutation | Query the same durable job; report `indeterminate` if proof is unavailable.             |
| Parent dies while child runs                | The durable Mission retains ownership; recovered parent may await, continue, or cancel. |
| Workspace owner changes                     | Advance a fencing epoch so stale workers cannot mutate the overlay.                     |
| Human client disconnects                    | Session continues; reconnect from a durable cursor.                                     |
| Reducer or plugin changes                   | Existing entities remain pinned or undergo an explicit recorded migration.              |

**OTP restart intensity is not a work retry policy.**

---

## Seductive ideas to reject

### Naive distributed Erlang across trust boundaries

PIDs, cookies, atom tables, remote code loading, and transitive connectivity are
not a hostile-boundary protocol.

### Autonomous swarms

Unbounded peer conversations amplify cost, correlated hallucination, unclear
ownership, and cancellation difficulty. Prefer bounded Mission DAGs.

### Process-per-everything

Use processes for active ownership and lifecycle, not as replacements for
durable records, indexes, and object storage.

### Supervision as durability

Restarting a process restores neither durable state nor knowledge of external
mutation.

### Silent mutation failover

Never rerun an uncertain mutation on another worker unless the same durable job
ID can be proven deduplicated.

### Shared writable workspaces

Concurrent work should branch. Agents exchange artifacts and patches, not race
over one filesystem.

### PubSub as truth

PubSub is delivery. The journal is truth.

### Replay as proof

Replay proves control-plane consistency, not external correctness.

### Invisible hot upgrade

Pin generations and record migrations. Reproducibility requires knowing which
code made each decision.

### CRDT transcript merging

Concurrent conversational histories rarely have a meaningful automatic merge.
Branch and reconcile results.

### “Exactly once” marketing

Arbitrary external mutation cannot generally promise exactly once. Promise
receipt-backed reconciliation and explicit uncertainty.

---

## Experiments that can falsify the vision

These should be vertical product slices, not infrastructure demonstrations.

### 1. Crash-everywhere recovery

Inject failure before submission, after worker acceptance, during mutation,
after result arrival but before journal commit, during delegation, and while
awaiting approval.

**Pass:** recovery produces one confirmed mutation or an explicit
`indeterminate` state, with no silent duplicate.  
**Falsifies:** recovery requires ad hoc phase repair or cannot distinguish
unsubmitted from uncertain work.

### 2. Delegation quality benchmark

Compare single-agent Harness with fresh delegated research, delegated
implementation, and independent verification across 30–50 real repository tasks.

Measure correctness, parent-context consumption, latency, cost, follow-up
usefulness, and unsupported claims.

**Pass:** delegation materially improves correctness or context efficiency
without unacceptable cost.  
**Falsifies:** if it only adds cost, retain Missions primarily for isolation and
verification.

### 3. Durable mutation receipt

Submit one marker-producing mutation under the same job ID while repeatedly
killing control processes and severing transport.

**Pass:** no duplicate marker while worker durability remains; loss of proof
yields `indeterminate`.  
**Falsifies:** ordinary tool operations cannot support useful acceptance and
query semantics.

### 4. Cross-entity causal replay

Record parent → delegate → child → job → artifact → verifier → result. Ask why a
patch hunk exists, then inject verifier failure and replay without executing
tools.

**Pass:** one causal query reaches the original request and all relevant
versions; injection changes the gate outcome.  
**Falsifies:** provenance schemas cannot cross entity boundaries cleanly.

### 5. Hostile workspace cell

Attempt symlink escape, host filesystem access, secret discovery, unrestricted
egress, fork bombs, disk exhaustion, and stale-epoch mutation.

**Pass:** all are blocked or bounded by the actual isolation boundary.  
**Falsifies:** remote execution is not ready to be a flagship until a stronger
cell provider exists.

### 6. Durable collaborative control room

Two humans and one agent observe a Mission, disconnect, compete for control,
approve a proposal, and reconnect after VM loss.

**Pass:** commands retain one ordering, stale actions branch or fail safely, and
no events are lost.  
**Falsifies:** collaboration adds no artifact-level value beyond serialized
terminal ownership.

### 7. One real Project Reactor

Use duplicate and out-of-order CI events to wake one logical workflow, delegate
diagnosis, create an isolated patch, verify it, request approval, and create
exactly one external result.

**Pass:** the workflow survives restarts and does not duplicate external
actions.  
**Falsifies:** if generic workflow-engine complexity appears before user value,
narrow the reactor.

---

## Three development horizons

### Horizon 1: Durable semantics on one node

Prove Harness can be a recoverable work runtime before clustering it.

1. Extract `ChildSession`.
2. Add Session-owned `delegate` with semantic result delivery.
3. Add stable entity, transition, effect, and causation IDs.
4. Introduce a journal and effect outbox.
5. Recover a Session from snapshot plus facts.
6. Persist event cursors and parent-child relationships.
7. Move large outputs and child answers into referenced artifacts.
8. Model effect acceptance, completion, cancellation, and indeterminate
   reconciliation.
9. Rebuild Coordinator on `ChildSession`.
10. Pin plugin generations and record reload/migration facts.
11. Inject crashes at every effect boundary.

**Success gate:** recovery and delegation experiments pass.

### Horizon 2: Trusted distributed control plane plus isolated cells

Separate durable orchestration from secure execution.

1. Durable worker job protocol with query, stream, cancel, and deduplication.
2. Real container or VM workspace-cell provider.
3. Snapshot and overlay workspaces.
4. Mutation leases and fencing epochs.
5. mTLS and short-lived capability grants.
6. Durable Missions and child continuation.
7. Evidence bundles and independent verification gates.
8. Shared control-room roles, approvals, and durable cursors.
9. Multi-node activation inside a trusted BEAM control-plane island.

Cluster membership must never be the correctness boundary.

**Success gate:** network-partition, stale-writer, and hostile-cell experiments
pass.

### Horizon 3: Supervised SDLC fabric

Make repositories event-driven collaborative systems.

1. Project Reactors.
2. Issue, PR, CI, deployment, dependency, and incident adapters.
3. Harness-specific durable workflow combinators.
4. Human approval queues and policy-defined verification.
5. Cross-repository Missions and artifact handoffs.
6. Project and organization cost, concurrency, token, and risk budgets.
7. Versioned workflow, policy, plugin, and reducer migrations.
8. Repository memory with provenance and invalidation.
9. Shadow-runtime and canary policy upgrades.
10. Multi-tenant isolation, retention, encryption, audit export, and operations.

If multi-agent benchmarks fail, this horizon still works as a durable
single-agent, verification, and SDLC automation platform. The swarm is optional;
recoverable work and evidence are not.

---

## Evolution of the current Harness code

| Current area              | Evolution                                                                                                                   |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `Harness.Session.Core`    | Remains the deterministic reducer. Keep IO, clocks, PIDs, and retries outside it.                                           |
| `Harness.Session`         | Becomes an activated durable-entity shell with journal commit, outbox dispatch, and job reconciliation.                     |
| `Harness.FlightRecorder`  | Becomes causal export, debugger, replay engine, and counterfactual laboratory over canonical facts.                         |
| `Harness.Session.Store`   | Becomes a transcript/content projection behind a storage behavior.                                                          |
| `Harness.Executor.Router` | Evolves from direct invocation into placement of durable job intents while preserving capability and uncertainty semantics. |
| `Harness.Worker.Server`   | Becomes a workspace-cell agent with durable receipts, resumable streams, fencing, and sandbox integration.                  |
| `Harness.Server`          | Becomes an authenticated gateway and entity locator with durable cursors and principal-aware commands.                      |
| Plugins                   | Remain trusted extensions; generations are pinned and migrations become causal facts. Untrusted plugins run in cells.       |
| `ChildSession`            | New minimal lifecycle substrate shared by `delegate` and Coordinator.                                                       |
| Coordinator               | Becomes a Mission policy interpreter; it no longer owns ephemeral child semantics or byte-truncated answers.                |

The current code does not need to be discarded. The pure core, flight recorder,
router, session tree, remote worker, plugin lifecycle, and coordinator are all
useful seeds. The strategic move is to place durability, causal identity, and
effect uncertainty underneath them before adding broad distribution.

---

## Product constellation

This vision likely becomes several cooperating tools rather than one monolith:

1. **Harness runtime** — trusted BEAM control plane and durable entities.
2. **Cell daemon** — workspace lifecycle, durable jobs, resource and security
   enforcement.
3. **CLI and IDE clients** — local interaction and review.
4. **Web control room** — collaboration, causality, approvals, and live
   operations.
5. **Journal and artifact service** — durable truth and immutable content.
6. **Reactor/adapters SDK** — issue, PR, CI, deployment, and incident
   integrations.
7. **Policy and verification engine** — evidence gates, governance, and
   independent review.

They share versioned protocols and entity semantics, not necessarily one runtime
or deployment artifact.

## Closing formulation

The conventional model is:

> An agent is a model loop with tools.

The Harness model can be:

> **Software work is a durable causal graph interpreted by supervised actors,
> executed in isolated cells, and accepted through evidence-bearing gates.**

That is not simply another agent harness. It is a different theory of how
humans, models, tools, environments, and software-delivery systems can work
together.
