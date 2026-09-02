# BEAM-native harness roadmap

> **Status:** The four prototype experiments in this document are implemented.
> It is retained as the architectural path that produced the current runtime.
> See the [canonical Elara roadmap](../docs/roadmap.md) for current
> implementation status, the next challenge, and its falsification criteria.

## Product thesis

The goal is not merely to rewrite an existing coding agent in Elixir. The goal
is an agent runtime in which sessions are durable actors, tools are movable
capabilities, clients can attach and detach, and failures stay inside explicit
supervision boundaries.

BEAM's most useful advantage here is not raw throughput. It is the combination
of explicit state ownership, cheap isolated processes, supervision, message
passing, distribution, and runtime introspection.

Elara already has the right core boundaries:

- One supervised session process owns each history.
- `Elara.Session.Core` is a pure, deterministic state machine.
- Provider and tool effects run in isolated tasks.
- Tools are data rather than closures.
- Sessions are persisted and can be resumed, cloned, forked, and rewound.

The experiments below should extend those boundaries rather than replace the
small core with a framework.

## Important constraints

### Hot code does not preserve state by itself

Code and state must be separate. Stateful plugins should keep state in a process
that survives implementation reloads. Reloads happen at a safe boundary, never
during one of that session's tool calls. A plugin may provide an explicit state
migration when its state shape changes.

### Actors are not an external protocol

Processes provide the internal client/server boundary. Browsers, editors, and
non-BEAM clients still require a versioned command/event protocol, stable
session identity, replay cursors, and reconnect semantics.

### Distributed Erlang is not a sandbox boundary

Directly connected Erlang nodes are highly trusted. Distribution is a strong
choice between trusted control-plane machines. Untrusted Docker containers and
remote sandboxes should use a narrow authenticated worker protocol that grants
only declared capabilities, rather than receiving broad access to the brain
node.

### Processes represent ownership and failure boundaries

Not every module or transformation should become a `GenServer`. Keep pure data
transformations pure. Introduce processes when they own mutable state, isolate
failure, execute concurrently, or have an independent lifecycle.

## Target shape

```text
                         +---------------------+
 CLI / TUI / editor ---->| command/event       |
 Web / mobile ---------->| gateway             |
                         +----------+----------+
                                    | stable session ID
                         +----------v----------+
                         | session process      |
                         | history + pure core  |
                         +------+---------+----+
                                |         |
                     +----------v--+   +--v---------------+
                     | provider     |   | tool router       |
                     | brain        |   +--+-------------+--+
                     +--------------+      |             |
                                  +--------v---+   +-----v---------+
                                  | local or   |   | remote worker |
                                  | plugin tool|   | sandbox       |
                                  +------------+   +---------------+
```

`Elara.Session.Core` should remain unaware of placement. It emits provider and
tool effects; the session shell and its collaborators decide where those effects
execute.

## Experiment 1: stateful live plugin reload

Build the smallest compelling proof of BEAM hot reload:

- A plugin contract for metadata, tool specifications, initial state, tool
  handling, and optional state migration.
- A state process per loaded plugin.
- A plugin registry generation that changes only after a successful reload.
- Reload only while the owning session is idle.
- Version metadata on installed plugin tools.
- Failure-safe loading: syntax, compilation, validation, or migration failure
  leaves the previous plugin active.
- A `/reload` command and a public API equivalent.

Proof scenario:

1. Load a stateful counter tool.
2. Call it and receive `v1 count=1`.
3. Change its implementation while the session remains alive.
4. Reload it.
5. Call it and receive `v2 count=2`.

Success requires the same session and plugin-state processes, uninterrupted
history, no mid-tool version switch, and rollback to the previous working code
when a replacement is invalid.

Start with trusted local source plugins. Do not add package management, remote
installation, dependency resolution, or a marketplace until the runtime contract
has been proven.

## Experiment 2: detachable session server

Move session ownership out of the terminal client's VM and into a small
long-lived service.

Build:

- Stable session IDs instead of public PIDs.
- A transport-neutral command protocol for ask, interrupt, subscribe, inspect,
  and session management.
- Events with monotonic sequence numbers.
- Subscription from an event cursor so reconnecting clients can replay missed
  events without duplicates.
- Initial `mix elara.server` and `mix elara.attach SESSION` clients.
- Multiple observers, with explicit control ownership where needed.

Proof scenario:

1. Start a long-running tool.
2. Terminate the CLI without terminating the session.
3. Attach from a second CLI.
4. Replay missed events and continue the same conversation.
5. Attach a second read-only observer.

The same protocol can later support a TUI, web UI, editor extension, or mobile
observer. Phoenix is not required to prove the boundary.

## Experiment 3: remote hands

Put tool execution behind an executor contract with local and remote
implementations. Requests and replies must be serializable values.

A tool request should include:

- Tool-call and session IDs.
- Tool name, version, and arguments.
- A workspace identity rather than an assumed host filesystem path.
- Deadline and cancellation identity.
- Required capabilities and placement constraints.

Workers advertise capabilities such as:

- `filesystem:read` and `filesystem:write`
- `shell`
- `docker`
- `linux:x86_64`
- `gpu`
- `browser`
- `network:public`

The router can select workers by capability, health, affinity, and load.

Proof scenario:

1. Keep the model and session on a local trusted machine.
2. Execute filesystem and shell tools in Docker or on a remote worker.
3. Kill the worker during a tool call.
4. Verify the session survives and records exactly one terminal tool result.
5. Start a replacement worker and continue the session.

Do not blindly retry interrupted mutating tools. A worker can die after a side
effect but before its acknowledgement. Reads may be retried safely; mutations
need idempotency keys, a worker-side journal, or an explicit indeterminate
outcome followed by reconciliation.

## Experiment 4: multi-agent coordination

Model a coordinator as an actor that supervises child sessions instead of
putting orchestration branches inside the session loop.

The coordinator should:

- Start child sessions under a dynamic supervisor.
- Clone or fork parent history.
- Give coding children isolated git worktrees.
- Monitor sessions and worker nodes.
- Enforce shared token, time, and concurrency budgets.
- Collect compact structured results instead of injecting full transcripts.
- Cancel remaining work once an answer is selected.

Initial orchestration patterns:

- Parallel investigation across independent subsystems.
- Candidate generation followed by a judge.
- Map/reduce analysis across packages or files.
- Specialist roles for debugging, tests, documentation, and security review.

Proof scenario: fork three candidates from one parent, execute them in isolated
worktrees or nodes, kill one child, collect the remaining results, and select a
winner without losing the parent session.

## Supporting BEAM-native features

### Deterministic flight recorder

Record each fact passed to the pure core and the resulting effects. This can
support:

- Offline replay without provider or tool calls.
- Behavior comparison before and after a core upgrade.
- Fault injection at any transition.
- Property tests for interruption, stale replies, and crash invariants.
- A `/why` debugger that explains which fact produced a transition.

### Process-per-command tools

Use a supervised Port-owning process for shell commands so the runtime can
stream output, interrupt cleanly, expose status and resource usage, and allow
clients to detach from long-running tests or development servers and reattach
later.

### Capability-based permissions and placement

Treat permission and placement as runtime data, not prompt advice. The same
capability model can decide whether an action is allowed and which worker may
perform it.

### Live extension points beyond tools

Once tool reload proves the contract, the same lifecycle may apply to:

- Permission policies.
- Prompt and context contributors.
- Event observers.
- Output renderers.
- Provider adapters.
- Tool-result processors.

Do not generalize the plugin framework to these extension points before the tool
experiment supplies concrete requirements.

### Observability and admission control

Expose session phase, current effect, mailbox length, worker health, budgets,
and child process relationships. Use those signals for per-session limits and
load-aware admission rather than adding unconstrained concurrency.

## Outcome and successor

The prototype now includes stateful plugin reload, detachable sessions,
capability-routed remote execution, a coordinator, deterministic replay, and
runtime observability. These results established useful boundaries, but they do
not make session work durable across VM loss and do not reconcile mutations
whose acknowledgement was lost.

The next stage is therefore not another breadth feature. It is the
[durable-effect research sequence](../docs/roadmap.md): commit one mutation as a
stable job, crash every boundary, and test whether Elara can recover truthfully
without a duplicate effect.
