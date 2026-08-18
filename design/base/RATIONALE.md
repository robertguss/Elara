# Rationale. Candidate 1: event-sourced session core, mechanical shell

## Problem

Build the smallest Mix app that runs a real ReAct loop on a local repo. The
shape is non-obvious because three constraints pull apart. The session process
must be the single writer of history, the user must see tool calls as they
happen, and the state machine plus loop must be ExUnit-testable with no live
network. A loop written inside a process blocks its mailbox and needs a process
to test. A loop extracted into a task splits history ownership mid-turn. The
Valim constraints (hot swap, client-server, distribution) must stay open in the
types without shipping any of them.

## Usage (caller's view)

Full version with three call sites in `USAGE.md`. The spec in two lines:

```elixir
{:ok, session} = Harness.start_session()
{:ok, answer} = Harness.ask(session, "what files are in this repo?")
```

The CLI (`mix harness.ask "..."`) is client one. It subscribes, calls
`ask_async`, and prints each `{:harness, pid, event}`. Call site two registers a
project tool as a plain struct with an `{module, function}` run field. Call site
three watches a running session from IEx by subscribing. Errors are values a
caller can match:
`{:error, :busy | :turn_limit | :interrupted | {:provider_error, e}}`.

## Shape

The agent is one pure function, `Core.step(state, fact) :: {state, [effect]}`.
Facts are what happened (ask, provider result, tool result, crash, timeout,
interrupt). Effects are what to do (call provider, run tool, emit event). The
ReAct loop is the fixpoint of feeding effect results back as facts. The
GenServer shell is mechanical. It turns each mailbox message into a fact, runs
`step`, and executes the effects in order, with provider and tool work in
`async_nolink` tasks so the mailbox stays free for subscribe and interrupt
mid-turn.

Load-bearing decisions:

- History is written only by `Core.step` (per separate-before-serializing; the
  shell cannot construct State, so single-writer is structural, not
  conventional).
- Phase is a sum:
  `:idle | {:calling_provider, ref, iter} | {:running_tool, ref, call, rest, iter}`.
  Each variant carries exactly its data, so "running with no current tool" has
  no representation (per type-system-discipline and model-the-domain; the
  transition table in `SKETCH.md` is the design).
- Refs are a counter in state, not `make_ref`, so the core stays pure and every
  transition replays in a test by feeding facts. Stale refs are dropped, which
  gives named end states for retry, crash, and interrupt (per
  make-operations-idempotent). Invariant I2 guarantees history stays wire-legal
  on every path, including interrupt mid-tool.
- Tools are data: name, description, JSON Schema map, `{module, function}`. The
  type bans closures, which is the Pi hot-swap lesson encoded where it costs
  nothing now (per foundational-thinking), and it keeps core state fully
  serializable, which is the persistence and distribution door.
- Wire JSON and env vars die at the edges. `Provider.OpenAI` owns the wire in
  two pure functions (`build_body`, `parse_response`), `Config.from_env` owns
  `HARNESS_*` (per boundary-discipline). Malformed tool-call JSON is parsed at
  the boundary into `{:malformed, raw}` and decided in the core, so even that
  path is a pure test.

Interface depth is judged explicitly. Four public calls (`start_session`,
`ask`/`ask_async`, `subscribe`, `interrupt`) hide the state machine, task
supervision, timers, truncation, turn budget, and the wire. Callers never see
GenServer message shapes or vendor JSON. The fact/effect vocabulary is internal
to core and shell, not public surface. Deliberately absent: permissions, edit
tool, compaction, streaming tokens, doom-loop detection, persistence. Each is
one fact variant, table row, or effect consumer later (per laziness-protocol,
one dep, thirteen small files, three hops CLI to provider).

## Synthesis decision

Filled by arena parent.

## Tradeoffs accepted

- We accept the fact/effect indirection on the simple text-only path in exchange
  for the whole loop, including interrupt, crash, and timeout branches, being
  pure table rows testable without processes.
- We accept that the loop is not readable as one recursive function in exchange
  for a transition table that is the single, explicit statement of the state
  machine.
- We accept MFA-only tools (test fakes need named modules, no inline closures)
  in exchange for purge-safe hot swap and a serializable tool table.
- We accept a `GenServer.call` held open for whole minutes on sync `ask` in
  exchange for the two-line script experience; the CLI uses the async path.
- We accept per-event output without token streaming in v1; the reserved
  `{:provider_delta, ref, chunk}` fact makes it additive.
- We accept in-memory history with `:temporary` restart (a crashed session is
  gone, not resurrected empty) in exchange for zero persistence machinery in v1;
  serializable core state keeps the file or DETS experiment additive.
- We accept one turn per session with `{:error, :busy}` instead of queueing asks
  in exchange for a single-writer invariant with no queue semantics to specify;
  parallel work is separate sessions.

## Alternatives considered

- Loop inside the GenServer (blocking `handle_call`, or chained
  `handle_continue`). Smallest public surface, but the blocking form freezes the
  mailbox, so no mid-turn events or interrupt, and the chained form scatters the
  machine across callbacks. Every branch needs a live process to test. Hides
  little, costs the two required behaviors. Rejected.
- Pure recursive `Turn.run(snapshot, provider, tools)` in a task, session merges
  at the end. The strongest rival and the most readable happy path. But the task
  executes effects itself, so mid-turn events need a side channel, history
  exists in two places during the turn, and interrupt means killing a task
  mid-tool, which leaves dangling tool_calls in history (breaks I2). Each fix
  re-derives a piece of the reducer. Rejected because its simplicity is confined
  to the path that was already easy.
- `gen_statem`. A real state machine, but callbacks couple every transition to a
  running process and Elixir lacks stdlib ergonomics for it. The pure reducer
  gives the same explicitness testable without a process. Rejected.
- Tools as a behaviour plus module registry. Conventional and compile-checked,
  but it costs a behaviour, three impl files, and a registry that duplicates
  each name, and the table it builds is not serializable data. Hides no
  additional complexity from callers. Rejected for the flat table.
- Events via `Registry` pub/sub or CLI polling. Registry adds a name scheme for
  one local subscriber; polling destroys the live experience. Monitored
  subscriber pids are ten shell lines and are the actor-model story stated
  literally. Rejected.

## Open questions and risks

- Should `HARNESS_MODEL` be required, or default to something? Required fails
  loud but adds a step to first run.
- Are `max_iterations: 12`, `tool_timeout_ms: 30_000`, and 16 KiB truncation the
  right defaults for a first repo session?
- Should `write` create parent directories (sketch says yes)? Agent-friendly but
  can mask path typos.
- On tool timeout the shell kills the task, but the OS process under
  `System.shell` may linger since nothing sends it a signal. Is that acceptable
  for v1, or do we owe a Port-based kill?
- Is `ask` returning only final text enough, or should it return the turn's
  appended messages too?

## Next implementation step

Write `Harness.Message` and `Harness.Session.Core` with `core_test.exs` covering
the transition table, before any process, provider, or CLI code exists.
