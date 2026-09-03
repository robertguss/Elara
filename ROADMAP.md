# Elara roadmap

> **Canonical roadmap and status source** · **Updated:** 2026-09-02 (split
> adopted) · **Owner:** solo development with AI collaborators

This file is the only current plan and status source for Elara. Completed work
and retired research remain available in Git history rather than as parallel
roadmaps or archived planning documents in the working tree.

## Working rules

- Keep at most one item `IN PROGRESS`. Normally exactly one item is executable
  as either `TODO` or `IN PROGRESS`; later items remain `BLOCKED`.
- Mark an item `DONE` only after its Result records the pushed commit, checks,
  deviations, and remaining uncertainty.
- Exercise features through the public product path. Test-only infrastructure
  does not establish user-visible behavior.
- Prefer one complete vertical slice over additional research harnesses or
  speculative infrastructure.
- Fail uncertain mutations closed. Workspace bytes may prove a current
  postcondition, but not causal job completion.
- Commit and push each completed item before starting its successor.

Statuses are `TODO`, `IN PROGRESS`, `BLOCKED`, `DONE`, `CANCELED`, and
`INVALID`.

## Current direction

Elara has supervised session actors, a pure session reducer, persisted and
detachable conversations, capability-routed local and remote workers,
deterministic replay, live plugins, and a durable-effects subsystem whose
receipt-backed local `write` now runs through the public product path (PROD-1).

ER-3 is closed as a **METHOD STOP**; V9 is not planned. Durable effects are
**frozen at PROD-1's scope**: no further receipt wiring for `edit`, `bash`,
plugins, or remote workers until execution crosses the process boundary below.

The direction is now the **Rust + Elixir split** decided in
[`docs/rust-elixir-split.md`](docs/rust-elixir-split.md) after two throwaway
spikes (2026-09-02). Elixir remains the single authority: session reducer,
journal and replay, loop policy, providers, plugins, supervision, and the effect
ledger. Rust owns two edge programs running as separate processes: an execution
stub behind an Erlang Port and a terminal UI behind a socket. The boundary is a
versioned line protocol; no NIFs. That document holds the architecture,
evidence, and reversal signals; this file holds the queue and status.

Sequencing favors foundations over an early daily driver: kill boundary first,
then the attach/patch protocol, then streaming, then the TUI, then a recorded
go/no-go checkpoint. A daily driver is the outcome of the sequence, not a
shortcut through it.

## Execution queue

| ID      | Status   | Item                                                          | Depends on       |
| ------- | -------- | ------------------------------------------------------------- | ---------------- |
| PROD-1  | DONE     | Ship receipt-backed local declarative writes end-to-end       | ER-3 METHOD STOP |
| PROD-2  | CANCELED | Ship receipt-backed local literal edits end-to-end            | PROD-1           |
| SPLIT-1 | DONE     | Rust execution stub in-repo; route built-in `bash` through it | PROD-1           |
| SPLIT-2 | DONE     | Protocol v2: snapshot-on-attach and sequenced patches         | SPLIT-1          |
| SPLIT-3 | DONE     | Streaming provider contract and content deltas                | SPLIT-2          |
| SPLIT-4 | DONE     | Rust TUI as a protocol v2 projection client                   | SPLIT-3          |
| PROV-1  | DONE     | ChatGPT/Codex subscription provider                           | SPLIT-4          |
| TUI-1   | DONE     | One-command embedded server for new TUI sessions              | PROV-1           |
| SPLIT-5 | TODO     | Daily-driver checkpoint and recorded go/no-go                 | TUI-1            |

Blocked on SPLIT-5's decision, not yet queued: small tool roster with an intent
argument and versioned tool schemas; Director-style loop ownership inside
`Core.step/2`; receipts around Port jobs (the PROD-2 question re-asked at the
right boundary); the same job protocol over a socket for remote stubs; Rust
shell interpreter, search, or AST only if profiling or usage demands them.

Explicitly not planned: a provider compatibility compiler, convars, embedded
Python extensions, TLA+ models, a cross-language plugin ABI, or any Rust rewrite
of the session authority.

## PROD-1 — Ship receipt-backed local declarative writes end-to-end

**Status:** DONE

### Outcome

Make the built-in local `write` tool use the durable receipt protocol by default
through `Elara.start_session/1`, `mix elara.ask`, and `mix elara.chat`,
including recovery through `mix elara.chat --continue`. A user-visible write
must either have durable causal completion evidence or report truthful
uncertainty; it must never silently fall back to an unreceipted mutation.

### Scope

- Replace `Elara.Effect.Sidecar`'s hard-coded dependency on the research-only
  `Elara.Effect.TestExecutor` with the smallest explicit executor contract for
  its existing submit, query, and continue lifecycle. Keep `TestExecutor` as a
  test implementation of that contract.
- Add a supervised local executor that owns and reopens its durable
  `ExecutorLedger`, so controller or session loss does not destroy the mutation
  record. A resumed persisted session must address the same logical executor and
  ledger rather than creating an empty substitute.
- Route the built-in local `write` tool through `Elara.Effect.DeclarativeWrite`
  and the receipt sidecar. Preserve its public arguments and normal result shape
  while recording stable job identity, operation digest, controller intent,
  acceptance, callback attempt, and terminal evidence.
- Remove the silent `effect_executor == nil` direct-execution bypass for this
  write path. Executor startup, identity, ledger, or reconciliation failure must
  fail closed with an actionable error or an `indeterminate` result, never by
  rerunning the write outside the protocol.
- Reconcile unresolved writes during normal persisted-session continuation.
  Surface recovered terminal outcomes and truthful indeterminacy through the
  existing tool-result and CLI rendering paths.
- Exercise the vertical slice through the public session API with the scripted
  provider. Cover the existing crash boundaries, same-ID/different-digest
  rejection, terminal recovery without re-execution, and
  callback-attempted-without-terminal indeterminacy.

### Non-goals

No literal-patch, opaque-shell, plugin-mutation, or remote-worker production
wiring; no remote durable ledger; no generic exactly-once claim; no broad
session or router rewrite; no new confirmatory experiment; and no
BEAM-superiority claim. Patch, shell, and remote durability require separate
decisions after this local write slice is running through the product path.

### Acceptance criteria

- Default public session and CLI construction provides the production local
  executor. Built-in writes cannot reach `Router.execute/4` through the current
  nil-executor bypass.
- The executor contract is exercised by both the production executor and test
  executor; its durable ledger rejects a reused job ID with a different digest
  and preserves callback-attempt and terminal state across owner restart.
- Persisted-session continuation reconciles each unresolved write once: terminal
  evidence is returned without mutation re-execution, accepted but unattempted
  work may continue only under the original durable identity, and an attempted
  write without causal terminal evidence is reported as `indeterminate` rather
  than retried.
- Targeted integration tests drive the write through `Elara.start_session/1` and
  the same configuration used by `ask` and `chat`.
- User documentation explains receipt-backed write and continuation behavior.
  `mix format --check-formatted`, `mix compile --warnings-as-errors`, targeted
  effect/session/CLI tests, and full `mix test` pass.
- The Result records the pushed commit, exact checks, deviations, remaining
  uncertainty, and the evidence-based decision for the next product slice.

### Result

**DONE (2026-09-02).** Pushed implementation commit
[`4d87900`](https://github.com/robertguss/elixir-harness/commit/4d879006d1795001b8b1282116ee6bf5227e0c7e)
to `origin/main` from a checkout synchronized at
`bd56cd9611da4f8c305ad5e4114da8d3540e03ea`.

The exact built-in local `write` now provisions a stable workspace executor,
commits a typed declarative-write intent, records acceptance and callback
attempt before mutation, performs same-directory atomic replacement, records a
terminal receipt, and preserves the existing successful `wrote N bytes to path`
tool result. `Elara.Effect.Sidecar` depends on the shared
`Elara.Effect.Executor` contract rather than `TestExecutor`; production and test
facades use the same ledger-owning server. The supervised production executor
reopens one ledger and executor identity for the same cwd/workspace pair.

Public `Elara.start_session/1` tests proved the write path without a usable
router, terminal continuation without rewriting, accepted/unattempted
continuation exactly once under the original identity, and attempted/nonterminal
continuation as `indeterminate` without retry. Contract tests proved durable
terminal and callback-attempt state across executor restart and
same-ID/different-digest rejection. A separate product-path test proved the
default production executor does not receipt `edit`.

Exact verification:

- `mix test test/elara/effect/production_write_test.exs` — 6 passed.
- `mix test test/elara/effect/production_write_test.exs test/elara/executor/protocol_test.exs test/elara/effect/job_test.exs test/elara/effect/marker_integration_test.exs test/elara/effect/write_reconciliation_test.exs test/elara/effect/crash_matrix_test.exs test/elara/session_test.exs test/elara/chat_test.exs`
  — 87 passed.
- `mix format --check-formatted` — exit 0.
- `mix compile --warnings-as-errors` — exit 0.
- `mix test` — 290 passed. The documented `CrashTool` `RuntimeError: boom` line
  was the only expected error log.
- `git diff --check` — exit 0 before commit; `git push origin main` advanced
  `origin/main` from `bd56cd9` to `4d87900`.

Deviations: the successful argument and result shapes are unchanged, but local
`write` is now intentionally workspace-confined: it rejects absolute/traversal
paths, symlink components, and non-file targets so the declarative preimage is
meaningful. This is a product safety change required by the frozen write
protocol, and is documented. No `edit`, `bash`, plugin, or remote receipt wiring
was added. The shared executor implementation was extracted rather than
duplicated behind two wrappers.

Remaining uncertainty: this establishes the local built-in write path and
process/owner restart behavior, not power-loss guarantees beyond SQLite's
configured WAL/FULL durability, generic exactly-once effects, remote durability,
or receipt-backed edit/shell behavior. One-shot `mix elara.ask` uses the durable
executor but intentionally has no persisted conversation to continue after its
process exits.

Decision: proceed to PROD-2 for the exact built-in local `edit`, using the
existing operation-aware literal-patch protocol and the same production
executor. It is the next smallest user-visible mutation slice and tests whether
the production boundary generalizes beyond whole-file replacement. Opaque shell
and remote-worker durability remain blocked on separate designs.

## PROD-2 — Ship receipt-backed local literal edits end-to-end

**Status:** CANCELED

### Result

**CANCELED (2026-09-02)** before any implementation. Superseded by the Rust +
Elixir split. PROD-1 already proved the authority-side invariant (committed
intent before mutation, stable job identity, durable observation, no unsafe
retry); repeating it for `edit` would teach the architecture nothing new while
widening the receipt surface that the execution stub (SPLIT-1) must later sit
beneath. The question of receipt-backed `edit` and `bash` is re-asked after
execution crosses the Port boundary, where it becomes "receipts around Port
jobs", a different design than the one below. The original scope is kept for
reference.

### Outcome

Route the exact built-in local `edit` tool through `Elara.Effect.LiteralPatch`
and the production executor by default. Preserve its public arguments and normal
result shape while removing unreceipted fallback and reconciling unresolved
edits through normal persisted-session continuation.

### Scope and acceptance

- Derive and durably bind the expected preimage, exact one-match replacement,
  and postimage before dispatch; fail closed on invalid, missing, ambiguous,
  symlinked, or concurrently changed targets.
- Reuse the PROD-1 executor contract, stable local executor, controller journal,
  and truthful terminal/indeterminate rendering. Do not add shell, plugin, or
  remote receipt behavior.
- Drive no-fault and continuation states through `Elara.start_session/1`, prove
  the exact built-in edit cannot reach the router fallback, and prove `bash`
  remains outside production receipts.
- Update user documentation and pass targeted tests, format, warnings-as-errors
  compile, and the full test suite before recording and pushing the Result.

## SPLIT-1 — Rust execution stub in-repo; route built-in `bash` through it

**Status:** DONE

### Outcome

Every built-in shell command runs inside a Rust execution stub that Elara owns
through a supervised Erlang Port. Interrupting a turn, hitting a timeout,
exceeding the output byte cap, or losing the BEAM leaves no descendant OS
process alive. `System.shell/2` disappears from the product path.

Baseline defect this fixes (verified at `bd56cd9`): killing the tool `Task`
around `System.shell("sleep 299")` leaves `sleep` running, and it survives BEAM
exit. Spike B (see the design document) demonstrated the fix outside the repo.

### Scope

- Add the stub crate under `native/exec-stub/` (Rust, `serde_json` + `libc`
  only). Build it from Mix so `mix compile` and `mix test` produce and locate
  the binary; fail compilation with an actionable message when `cargo` is
  absent.
- Job protocol over JSON lines on the Port:
  `run {id, argv, cwd, env?, max_bytes, timeout_ms}`, `cancel {id}`, `ping`;
  replies `started`, `chunk {id, stream, bytes}`,
  `exit {id, code, signal, cancelled, timed_out, truncated, bytes_total, bytes_sent, elapsed_ms}`.
  Each job runs in its own process group; the group receives SIGKILL on cancel,
  timeout, or byte cap; stdin EOF kills every group and exits.
- Add `Elara.Exec`, a supervised GenServer owning one long-lived Port per BEAM,
  correlating jobs by id and monitoring callers so an abandoned job is
  cancelled.
- Route `Elara.Tools.bash/2` and `Elara.Effect.OpaqueShell` through
  `Elara.Exec`. Keep `Core`'s `max_tool_output_bytes` as the second line of
  truncation; the stub enforces the cap at source.
- Stub death or Port closure marks in-flight jobs `indeterminate`, never
  successful, and the supervisor restarts the stub.

### Non-goals

No shell interpreter, coreutils, or command approval; no remote stub; no
receipts for `bash`; no change to the tool's public arguments or result text on
the success path; no NIFs.

### Acceptance criteria

- Tests through `Elara.start_session/1` with the scripted provider: interrupt
  during `sleep`, tool timeout, `yes` flood, and
  `bash -c 'sleep & sleep & wait'` each leave zero descendant processes (checked
  with `pgrep` against a unique marker) and report `cancelled`, `timed_out`, or
  `truncated` truthfully.
- Flood test shows `bytes_sent == max_bytes` and `bytes_total > bytes_sent`.
- Killing the stub mid-job renders the tool result `indeterminate` and a
  following command succeeds after supervisor restart.
- A BEAM-death test (`mix run` child that `System.halt`s mid-job) leaves no
  descendants.
- `rg System.shell lib/` returns nothing. `mix format --check-formatted`,
  `mix compile --warnings-as-errors`, `cargo fmt --check` and `cargo clippy` in
  the crate, and full `mix test` pass.
- The Result records the pushed commit, exact checks, cold and incremental build
  times, deviations, and remaining uncertainty.

### Result

**DONE (2026-09-02).** Pushed implementation commit
[`ff8bcb2`](https://github.com/robertguss/elixir-harness/commit/ff8bcb27c6a17894c76f16b7a583fb023c1835a8)
to `origin/main` from the required clean base
`79ded4849d629ac0a050deaaf7bc25ce9019eae2`.

`Elara.Exec` now supervises one long-lived, handshaken Port per BEAM, correlates
jobs and monitors their calling tool Tasks, cancels abandoned jobs, validates
the stub's terminal accounting, and fails every in-flight caller `indeterminate`
before replacing a dead Port. The Mix compiler builds the locked crate into the
application's `priv/native/exec-stub` path. Built-in local and remote-worker
`bash` and the research `OpaqueShell` path all use this boundary; the worker
envelope is version 2 so the session's source byte cap travels with remote
requests. Core retains its independent output cap.

The Rust manager forks one guardian per job. Each guardian owns a process group,
merged output pipe, timeout and byte accounting, and a manager-liveness pipe.
Cancel, timeout, overflow, normal leader exit, manager `SIGKILL`, and Port EOF
all kill and reap the group. This guardian layer was added after the required
Oracle consult identified that a manager-only process-group design cannot clean
up after the manager itself receives `SIGKILL`.

Exact verification:

- `mix test test/elara/exec_integration_test.exs test/elara/tools_test.exs test/elara/executor_test.exs test/elara/effect/opaque_shell_test.exs`
  — 35 passed.
- `mix format --check-formatted` — exit 0.
- `mix compile --warnings-as-errors` — exit 0; Cargo's incremental build
  finished in 0.01 s.
- `cargo fmt --check --manifest-path native/exec-stub/Cargo.toml` — exit 0.
- `cargo clippy --manifest-path native/exec-stub/Cargo.toml` — exit 0, finished
  in 0.17 s.
- `cargo test --manifest-path native/exec-stub/Cargo.toml` — 2 passed.
- `mix test` — 296 passed. The documented `CrashTool` `RuntimeError: boom` line
  was the only expected error log.
- `rg 'System\.shell' lib/` — no matches; `git diff --check` — exit 0.
- With Cargo removed from `PATH`, `mix compile.exec_stub` exited 1 with
  `cannot build native/exec-stub because cargo is not available` and install
  guidance.
- After removing the Mix Cargo target and packaged binary,
  `mix compile.exec_stub` took 3.98 s cold; the immediate incremental run took
  0.52 s (Cargo itself reported 3.48 s and 0.01 s respectively).

Deviations: the protocol adds a versioned `ready` handshake and explicit
`rejected`/`pong` replies needed to distinguish proven non-start from uncertain
submission and to reject incompatible binaries. Chunk bytes are JSON byte arrays
on one `combined` stream, preserving the prior merged stdout/stderr contract for
arbitrary bytes. The existing command-string API is preserved by invoking
`/bin/sh -c`; Rust does not implement a shell interpreter. The guardian process
is additional hardening beyond the original manager-only spike. No bash receipt,
approval, NIF, direct remote-stub protocol, or Rust shell implementation was
added.

Remaining uncertainty: the stub currently targets Unix/Linux primitives
(`pipe2`, `prctl`, process groups, signals); release packaging and prebuilt
binaries for other platforms remain future distribution work. The zero-process
claim covers ordinary descendants that remain in the assigned group, including
the accepted background-grandchild case; a deliberately hostile command can
escape with `setsid` or an external privileged supervisor. `bytes_total` is the
number of bytes observed before source termination, not hypothetical output the
producer would have emitted afterward.

Decision: proceed to SPLIT-2. The execution boundary now fails uncertain work
closed and all product-path lifecycle tests leave zero ordinary descendants, so
the snapshot/patch protocol can be built on the bounded substrate without
widening durable effects.

## SPLIT-2 — Protocol v2: snapshot-on-attach and sequenced patches

**Status:** DONE

### Outcome

A client can attach to a session and render its full current state without
replaying the event log from seq 0, then stay current by applying an ordered
stream of small patches. Views become projections of one Elixir-owned
materialized state; the 1 000-event ring is a delivery cache, not an authority.

Spike A finding this addresses: cursor replay yields missed events, not state,
so a fresh client today must replay everything retained or sees nothing.

### Scope

- Add a materialized session view derived from `Core` state: messages, tool
  calls with status, turn state, usage, session metadata. Derive; do not store a
  second copy.
- Extend `Elara.Protocol` with `protocol: 2` on hello. `attach` replies
  `attached {incarnation, head, snapshot}`; subsequent `patch {seq, ops}`
  messages use a small closed op set (append message, set tool status, set turn
  state, set usage, append content delta reserved for SPLIT-3). Clients apply
  ops blindly.
- Gap in seq, expired cursor, or changed incarnation makes the server send a
  fresh snapshot; the client never reconstructs state itself.
- Keep protocol v1 working unchanged for the existing line client and
  `mix elara.attach`.
- Update `mix elara.attach` to negotiate v2 so the feature is exercised through
  the product path before the Rust TUI exists.

### Non-goals

No TUI, no streaming deltas yet, no change to session persistence or the
`Core.step/2` event vocabulary beyond what the view needs, no removal of v1.

### Acceptance criteria

- A v2 client attaching cold to a session with more than 1 000 retained events
  renders correctly from the snapshot alone.
- Property-style test: applying the patch stream to the attach snapshot equals
  the server's materialized view at every seq.
- Gap and incarnation-change tests trigger exactly one resnapshot.
- Two clients (one control, one observe) on the same session both converge;
  interrupt from the controller is visible to the observer.
- Protocol schema is versioned and documented in `docs/detached-and-remote.md`.
  Format, warnings-as-errors compile, and full `mix test` pass.

### Result

**DONE (2026-09-02).** Pushed implementation commits
[`ef43018`](https://github.com/robertguss/elixir-harness/commit/ef430184348005581844a5a6d0d01f832b1c596b)
and
[`54ea404`](https://github.com/robertguss/elixir-harness/commit/54ea404f62c8506365d56bd098f671c867066224)
to `origin/main`.

Protocol v2 now attaches with an atomic materialized snapshot derived directly
from `Core`, then sends incarnation-scoped, contiguous patches over a closed op
set. The snapshot carries session identity, complete messages, tool-call status
and outcome, turn state, usage, and the content-delta slot reserved for SPLIT-3.
`Session` stores only attachment protocol metadata, not a second projection.
Each patch idempotently reconciles all changes from its owning Core transition,
so applying any emitted sequence yields that sequence's complete Core-derived
view even when one transition emits several causal events. V1 retains cursor
validation, 1,000-event replay, event messages, and versioned command replies.

`mix elara.attach` now negotiates v2, renders the current snapshot, applies
patches blindly, ignores stale sequences, and asks for exactly one resnapshot
while a gap, malformed patch, or incarnation change is unresolved. Resnapshot
heads and snapshots come from one Session call, so queued patches at or below
the returned head are safely stale. A large-snapshot test exposed OTP line-mode
chunking at the socket buffer boundary; gateway and client now reassemble JSON
lines with a documented 16 MiB fail-closed limit.

Exact verification:

- `mix test test/elara/server_test.exs test/elara/protocol_v2_test.exs` — 9
  passed, including the real `Mix.Tasks.Elara.Attach` product path, a cold
  1,004-event attach with only 1,000 events retained, every-sequence Core-view
  equality across normal/rejected/interrupted tool transitions, v1 replay,
  one-shot resnapshot behavior, and two-client interrupt convergence.
- `mix format --check-formatted` — exit 0.
- `mix compile --warnings-as-errors` — exit 0; Cargo finished incrementally in
  0.01 s.
- `cargo fmt --check --manifest-path native/exec-stub/Cargo.toml` — exit 0.
- `cargo clippy --manifest-path native/exec-stub/Cargo.toml` — exit 0, finished
  in 0.04 s.
- `cargo test --manifest-path native/exec-stub/Cargo.toml` — 2 passed.
- `mix test` — 302 passed. The documented `CrashTool` `RuntimeError: boom` line
  was the only expected error log.
- `rg 'System\.shell' lib/` — no matches; `git diff --check` — exit 0; no
  `spike-*` files remain in the repository root.

Deviations: the wire keeps the existing `version` field (`2`) rather than
renaming the v1 handshake field to `protocol`, avoiding a second version
selector. `usage` is `null` because the current Provider contract does not
expose usage; `append_content_delta` is accepted and projected but is not
emitted before SPLIT-3. The explicit line-size bound and segmented line
reassembly were added when the required >1,000-event snapshot proved that a
single JSON line can exceed OTP's socket buffer. The follow-up implementation
commit tightened the initial settled-head convergence check to assert exact
Core-view equality after every emitted sequence.

Remaining uncertainty: a materialized snapshot over 16 MiB fails closed instead
of attaching; chunked snapshots or pagination remain future protocol work if
real sessions approach that size. Usage stays unknown until provider support
lands. The v2 line client is covered in captured-I/O integration tests; broader
interactive terminal behavior remains for SPLIT-4's TUI parity work.

Decision: proceed to SPLIT-3. Snapshot recovery no longer depends on the bounded
event ring, both attachment modes converge on one Elixir-owned view, and the
reserved content-delta op gives provider streaming a versioned product path
without moving session authority into a client.

## SPLIT-3 — Streaming provider contract and content deltas

**Status:** DONE

### Outcome

Assistant text appears as it is generated. The provider contract streams;
`Core.step/2` records content deltas as events; protocol v2 carries them as
patch ops; the Elixir line UI prints them so the feature is user-visible before
any TUI.

### Scope

- Add a streaming callback to `Elara.Provider` (delta sink plus final
  `Assistant` message). The xAI adapter implements it over SSE; `Scripted` emits
  scripted deltas so tests stay offline.
- `Core` gains a content-delta event and a final `message_appended` that
  supersedes the deltas; replay and fork produce identical final messages with
  or without deltas.
- Protocol v2 `append content delta` op; `mix elara.chat` and `mix elara.attach`
  print deltas incrementally.

### Non-goals

No token-usage streaming beyond what the provider returns, no speculative
compaction, no corrective inference.

### Acceptance criteria

- With the scripted provider, `mix elara.chat` shows at least two deltas before
  the final message in a captured terminal run.
- Replaying a persisted session with deltas yields the same `Core` state as one
  without.
- Interrupt mid-stream truncates truthfully (partial message marked as
  interrupted, not presented as complete).
- Format, warnings-as-errors compile, and full `mix test` pass.

### Result

**DONE (2026-09-02).** Pushed implementation commit
[`7c99e7d`](https://github.com/robertguss/elixir-harness/commit/7c99e7d5c0b708d429119c14a16ffd53758e6466)
to `origin/main`.

`Elara.Provider` now has an optional `stream/3` callback: it emits ordered text
chunks through a sink and returns the final `Assistant`, while providers that
only implement `chat/2` continue to work. The xAI/Grok path delegates to an
OpenAI-compatible SSE adapter that reassembles arbitrary byte and SSE-frame
boundaries, emits content incrementally, assembles fragmented tool-call
arguments by index, disables request retry, and fails malformed, incomplete, or
mismatched final streams closed. `Scripted` supports offline delta and sleep
steps for deterministic ordering and interrupt tests.

Provider tasks send deltas with their pid and Core ref. `Session` accepts them
only while that exact task is tracked, so interrupt kills the provider and drops
queued stale deltas. `Core` owns the transient content, records each delta as a
fact/event, rejects a final Assistant that disagrees with already-rendered text,
and emits one durable final message that supersedes the delta. Partial text ends
with an explicit streamed interrupted/error event and is never stored or
presented as a complete Assistant.

Protocol v2 derives live content from Core, applies `append_content_delta`, and
clears the content idempotently through `supersedes` metadata when a final
message or terminal turn replaces it. V1 remains decodable and explicitly
encodes the new event variants. Both `Elara.Chat` and the v2 attach renderer
print chunks immediately and suppress duplicate final text. Flight recordings
include delta facts and causal events; Store persistence and forks continue to
contain only the same final messages as non-streamed turns.

Exact verification:

- `mix test test/elara/provider/open_ai_test.exs test/elara/session/core_test.exs test/elara/session_test.exs test/elara/protocol_v2_test.exs test/elara/chat/core_test.exs test/elara/chat_test.exs test/elara/cli_test.exs test/elara/flight_recorder_test.exs`
  — 135 passed. This includes byte-at-a-time SSE parsing with fragmented tool
  calls, captured incremental Chat output, mid-stream interrupt truth, live v2
  attach patches, every-sequence Core/projection equality, persisted replay, and
  Store/fork equivalence.
- `mix format --check-formatted` — exit 0.
- `mix compile --warnings-as-errors` — exit 0; Cargo finished incrementally in
  0.02 s.
- `cargo fmt --check --manifest-path native/exec-stub/Cargo.toml` — exit 0.
- `cargo clippy --manifest-path native/exec-stub/Cargo.toml` — exit 0, finished
  in 0.11 s.
- `cargo test --manifest-path native/exec-stub/Cargo.toml` — 2 passed.
- `mix test` — 316 passed. The documented `CrashTool` `RuntimeError: boom` line
  was the only expected error log.
- `rg 'System\.shell' lib/` — no matches; `git diff --check` — exit 0; no
  `spike-*` files are present in the repository root.

Deviations: streaming is optional at the behavior boundary so existing custom
providers keep the established `chat/2` fallback. The captured scripted Chat run
exercises `Elara.Chat.run/3`, the public runtime path behind `mix elara.chat`;
the Mix entrypoint itself resolves credential-backed providers and therefore
cannot inject `Scripted`. The live attach check drives protocol v2 through
`Elara.Server` and the exact `Protocol.patch_events/1` plus `CLI.render/1` path
used by `mix elara.attach`; the existing Mix attach test continues to cover
entrypoint negotiation and snapshot rendering. No usage or speculative state was
added.

Remaining uncertainty: the SSE parser is covered against OpenAI-compatible
frames split at every byte, but not a live xAI stream in the credential-free
suite; an undocumented vendor event shape would fail closed as `bad_response`. A
line client that prints a partial stream and later resnapshots may print the
materialized partial text again because terminal output cannot retract prior
bytes. Interrupted partial text is intentionally event/view state rather than
durable message history, preserving replay and fork equivalence.

Decision: proceed to SPLIT-4. Streaming now crosses the settled provider, Core,
protocol, and line-client boundaries without moving session policy into a view;
the Rust client can remain a blind snapshot/patch projection.

## SPLIT-4 — Rust TUI as a protocol v2 projection client

**Status:** DONE

### Outcome

A `ratatui` terminal client, in-repo under `native/elara-tui/`, that is a pure
projection of an Elixir-owned session: it applies snapshots and patches, sends
commands, and holds no session policy. It reaches feature parity with the Elixir
line UI, after which the line UI is removed.

### Scope

- Commands: create, attach (with saved cursor), ask, explicit interrupt, detach
  without cancel, session list. Streaming deltas rendered live.
- Headless mode with `TestBackend` frame dumps and an event dump flag, so
  behavior is testable without a terminal.
- Resnapshot on gap or incarnation change handled by the protocol, not the UI.
- Distribution: a `mix elara.tui` task that locates or builds the binary.

### Non-goals

No policy in Rust (approval, retries, tool routing), no direct file or process
access from the TUI, no RichText pipeline or theming system yet.

### Acceptance criteria

- Spike A scenarios as headless tests: cold attach renders from snapshot; client
  killed mid-turn while the session keeps executing; reattach replays exactly
  the missed patches; live turn latency recorded.
- Frame-dump golden tests for the main states: idle, streaming, tool running,
  interrupted, detached.
- `cargo fmt --check`, `cargo clippy`, `cargo test`, and full `mix test` pass;
  Elixir line UI removed only after parity is demonstrated in the Result.

### Result

**DONE (2026-09-02).** Pushed implementation commit
[`80a65cd`](https://github.com/robertguss/elixir-harness/commit/80a65cd49abfff5c81d306f87d4b9acbabecefae)
to `origin/main`.

`native/elara-tui/` now contains a `ratatui` protocol-v2 projection client. It
creates or attaches to server-owned sessions, sends asks and explicit
interrupts, detaches without cancellation, observes read-only, lists live
sessions, and redraws streaming content deltas from the materialized view. The
closed Rust patch applier atomically handles all five v2 operations, ignores
already-applied sequences, and requests exactly one resnapshot while a gap,
incarnation change, or malformed patch remains unresolved. Snapshot and frame
session identities must agree before installation, and the JSON-lines reader
reassembles arbitrary socket chunks under the protocol's 16 MiB fail-closed
bound.

The TUI saves each session's incarnation and head under
`~/.elara/tui/cursors.json`. `--headless` renders deterministic off-screen
frames, `--event-dump` records timestamped raw protocol frames, and optional
headless ask/interrupt controls exercise complete turns without a terminal.
`mix elara.tui` hashes the crate sources, builds a locked debug or production
binary only when needed, installs it under the Mix application, and launches it
with inherited terminal file descriptors. Protocol v2 gained a read-only initial
`list` request backed by a dedicated lightweight Session listing call; it does
not invoke worker health or other failure-prone status dependencies.

Parity is demonstrated through the shipped Rust binary: a cold snapshot renders
prior history; create and live-list commands work; a client hard-killed after
its first streamed delta releases control while the Elixir session finishes;
reattachment loads the saved cursor and installs the exact completed snapshot
once; a subsequent streamed turn records ask-to-active and ask-to-first-delta
latency; and an explicit client interrupt terminates a running tool turn as
interrupted. `TestBackend` goldens cover idle, streaming, tool-running,
interrupted, and detached frames. On that evidence, `mix elara.attach` and its
Elixir line renderer were removed. The policy-free `Elara.Protocol.Projector`
remains as the Elixir protocol-convergence oracle in contract tests; the Rust
TUI is the only attachment UI.

Exact verification:

- `mix test test/elara/protocol_v2_test.exs test/elara/tui_test.exs` — 10
  passed, including cold attach, create/list, killed-client continuation,
  saved-cursor reattach, live latency, explicit interrupt, sequence convergence,
  and one-shot resnapshot behavior.
- `mix format --check-formatted` — exit 0.
- `mix compile --warnings-as-errors` — exit 0; Cargo finished incrementally in
  0.01 s.
- `cd native/exec-stub && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`
  — exit 0; 2 tests passed.
- `cd native/elara-tui && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`
  — exit 0; 5 tests passed plus empty binary/doc test targets.
- `mix test` — 318 passed in 18.5 s. The documented `CrashTool`
  `RuntimeError: boom` line was the only expected error log.
- `rg 'System\.shell' lib/` — no matches; `git diff --check` — exit 0; no
  `spike-*` files are present in the repository root.

Deviations: because protocol v2 deliberately starts every attachment from an
atomic current snapshot, killed-client reattachment does not replay missed
patches over the wire as the Spike A wording implied. The test instead proves
the stronger settled contract: the client sends its saved cursor, installs the
completed head exactly once, and renders neither missing nor duplicate content.
Session listing required one new read-only initial v2 command; it returns only
live server-owned sessions because persisted chat files are not attachable until
an Elixir session owns them. Latency evidence uses the offline `Scripted`
provider and loopback server rather than a credential-backed xAI request.

Remaining uncertainty: automated coverage exercises the real Rust binary and all
rendered states through `TestBackend`, but it does not synthesize keystrokes
inside a real alternate-screen terminal; terminal-specific input/display quirks
remain daily-driver evidence for SPLIT-5. The TUI is built from source on first
use rather than distributed as a prebuilt release artifact. Sessions whose
atomic snapshot exceeds 16 MiB still fail closed as established in SPLIT-2.

Decision: unblock SPLIT-5, but do not make its go/no-go decision. The owner must
use this TUI for the stated period and record the reversal-signal measurements.

## PROV-1 — ChatGPT/Codex subscription provider

**Status:** DONE

### Outcome

The owner can use an eligible ChatGPT Plus/Pro Codex subscription as Elara's
model provider while Elara retains authority over sessions, tools, execution,
and the agent loop.

### Scope and acceptance

- Add an explicit OpenAI Codex device-code login and securely persist and
  refresh its OAuth credentials without reading another harness's credential
  files.
- Add a dedicated provider for the subscription-backed Codex Responses stream,
  identifying itself truthfully as Elara and mapping Elara messages, tools, tool
  results, text deltas, and errors without embedding Codex's agent loop.
- Persist the provider-native function-call IDs and encrypted reasoning items
  needed for `store: false` continuation. Keep that metadata out of protocol-v2
  snapshots and the Rust TUI.
- Preserve API-key and Grok login behavior. Select subscription auth explicitly
  with `ELARA_PROVIDER=openai-codex`; keep its model configurable.
- Exercise login, refresh, request conversion, arbitrary-chunk SSE parsing,
  multi-turn tool continuation, persistence/resume, and the public session path
  without live credentials. Document the login and daily-driver path.
- Pass focused tests, `mix format --check-formatted`,
  `mix compile --warnings-as-errors`, both Rust crates' format/Clippy/tests, the
  full `mix test`, and `rg 'System\.shell' lib/` before recording the Result.

### Non-goals

No OpenAI Platform API billing changes, browser callback flow, WebSocket or zstd
transport, model catalog, hosted tools, connector scopes, Codex runtime, or
change to Elara's session/tool authority. A credential-backed request remains
owner validation because automated tests do not use network credentials.

### Result

**DONE (2026-09-02).** Pushed implementation commit
[`b440861`](https://github.com/robertguss/elixir-harness/commit/b4408614284df3bcf102566c3ad78cec768391fb)
to `origin/main`.

Elara now has an explicit ChatGPT/Codex subscription path.
`mix elara.login openai` performs OpenAI's device-code flow and saves private,
atomically replaced credentials under `~/.elara/openai-codex-auth.json`;
refreshes serialize within the BEAM and retain rotated refresh tokens.
`ELARA_PROVIDER=openai-codex` selects a dedicated streamed Responses adapter
that sends truthful `originator: elara` and the ChatGPT account claim while
leaving Elara's reducer, tool loop, execution, and persistence authoritative.
Existing API-key and Grok resolution remain the default when that explicit
selector is absent.

The adapter maps Elara's tools to flat Responses function definitions, streams
arbitrarily chunked SSE text, rejects malformed or non-terminal responses, and
threads refreshed provider configuration back through the session. Complete
native output items—including encrypted reasoning, assistant message IDs, and
both function item and call IDs—are stored with assistant history and replayed
for `store: false` continuation. Session JSONL and flight recordings preserve
that state; protocol snapshots deliberately omit it so it never crosses the Rust
TUI boundary. A loopback HTTP test exercises the actual Req/Finch and public
`Elara.start_session`/`Elara.ask` path through a tool call, a second model turn,
process shutdown, persisted reopen, and another model turn.

Exact verification:

- `mix test test/elara/auth/open_ai_codex_test.exs test/elara/provider/open_ai_codex_test.exs test/elara/provider/open_ai_codex_integration_test.exs test/elara/config_test.exs test/elara/session/store_test.exs test/elara/protocol_v2_test.exs test/elara/flight_recorder_test.exs`
  — 47 passed in 1.6 s.
- `mix format --check-formatted` — exit 0.
- `mix compile --warnings-as-errors` — exit 0; Cargo finished incrementally in
  0.01 s.
- `cd native/exec-stub && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`
  — exit 0; 2 tests passed.
- `cd native/elara-tui && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`
  — exit 0; 5 tests passed plus empty binary/doc test targets.
- `mix test` — 334 passed in 15.6 s. The documented `CrashTool`
  `RuntimeError: boom` line was the only expected error log.
- `rg 'System\.shell' lib/` — no matches; `git diff --check` — exit 0.

Deviations: PROV-1 was inserted after SPLIT-4 when the owner requested
subscription support, temporarily blocking the already-unblocked owner
checkpoint. The credential-free product-path test uses a protocol-faithful
loopback endpoint rather than another provider abstraction. No non-goal was
added.

Remaining uncertainty: automated tests cannot establish this owner's ChatGPT
plan entitlement or catch a future private-backend contract change. The current
`gpt-5.3-codex` default may also age; `ELARA_MODEL` is the explicit override.
The owner must complete device login and one credential-backed turn during the
daily-driver checkpoint.

Decision: unblock SPLIT-5. Provider work does not make the split go/no-go
decision; the owner must now collect the stated daily-use evidence.

## TUI-1 — One-command embedded server for new TUI sessions

**Status:** DONE

### Outcome

The normal `mix elara.tui new` path needs one terminal and one command. An
explicit long-lived server remains available when the session must outlive the
TUI command.

### Scope and acceptance

- Before launching the Rust client for a `new` target, the Mix task starts an
  Elixir server on the TUI's selected `--port` or `ELARA_SERVER_PORT` when that
  port is free.
- If the port already has an Elara server, use it without replacing or stopping
  it. Keep attach-by-ID, observe, and list commands dependent on that existing
  server because an embedded server has no live session to attach to.
- The embedded server lives in the same Mix VM as the client and ends with that
  command. Document that `mix elara.server` is still required for turns to
  continue after the TUI exits and for later live reattachment.
- Exercise both automatic startup and existing-server reuse through the shipped
  Rust binary. Pass focused tests, both languages' format/lint/tests, full
  `mix test`, and `rg 'System\.shell' lib/` before recording the Result.

### Non-goals

No background daemon, service manager, persisted-session auto-hydration,
protocol change, or change to session ownership and detach semantics.

### Result

**DONE (2026-09-03).** Pushed implementation commit
[`131fc52`](https://github.com/robertguss/elixir-harness/commit/131fc52c0650b84cf35fc38cc30266ee9679e5b3)
to `origin/main`.

`mix elara.tui new` now parses the same relevant client switches and starts an
embedded `Elara.Server` on the selected `--port`, `ELARA_SERVER_PORT`, or port
4048 before launching the shipped Rust binary. A bound port is treated as an
existing server and left untouched. Other targets still require an existing
server because a fresh embedded VM cannot contain the live session named by an
attach, observe, or list command.

The embedded server uses an unlinked start so a normal `eaddrinuse` result does
not terminate the Mix task before the Rust client can connect to the existing
server. Existing supervised callers retain `start_link`. README and the
detached-session guide now distinguish the one-command lifetime from the
explicit long-lived mode.

Exact verification:

- `mix test test/elara/tui_test.exs` — 4 passed in 1.1 s, including embedded
  startup from `ELARA_SERVER_PORT` and reuse of an existing server through the
  shipped Rust binary.
- `mix format --check-formatted` — exit 0.
- `mix compile --warnings-as-errors` — exit 0; Cargo finished incrementally in
  0.01 s.
- `cd native/exec-stub && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`
  — exit 0; 2 tests passed.
- `cd native/elara-tui && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`
  — exit 0; 5 tests passed plus empty binary/doc test targets.
- `mix test` — 335 passed in 15.6 s. The documented `CrashTool`
  `RuntimeError: boom` line was the only expected error log.
- `rg 'System\.shell' lib/` — no matches; `git diff --check` — exit 0.

Deviations: none from scope. Automatic startup is deliberately limited to `new`;
implementing a durable daemon or persisted-session hydration would change the
stated lifetime and protocol scope.

Remaining uncertainty: headless tests exercise the real binary and launch path,
but ordinary alternate-screen terminal behavior remains daily-driver evidence. A
non-Elara process occupying the selected port is left for the Rust client's
protocol/connection error rather than being replaced.

Decision: unblock SPLIT-5. Everyday new sessions need one command; users opt
into a separate server only when they want its longer lifetime.

## SPLIT-5 — Daily-driver checkpoint and recorded go/no-go

**Status:** TODO (owner checkpoint)

### Outcome

A recorded decision, not new code. The owner uses the Rust TUI as the primary
client for a fixed period, then the reversal signals from the design document
are measured and the split is either kept or reversed to Rust-everything.

### Scope and acceptance

- Period: two weeks of daily use, or the next five session/UI features,
  whichever comes first.
- Record per feature: did Rust have to duplicate session policy or transition
  logic; share of implementation time spent on protocol/DTO synchronization.
- Record whether detached sessions, plugin reload, remote workers, and durable
  recovery were actually used.
- Decision rule (from `docs/rust-elixir-split.md` §9): reverse if 3 of 5
  features duplicated policy, or boundary work exceeded 30 % of implementation
  time, or the BEAM-specific features went unused. Otherwise keep the split and
  queue the next items from "Blocked on SPLIT-5's decision".
- The Result records the measurements, the decision, and the next queue.
