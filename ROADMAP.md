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
| SPLIT-2 | TODO     | Protocol v2: snapshot-on-attach and sequenced patches         | SPLIT-1          |
| SPLIT-3 | BLOCKED  | Streaming provider contract and content deltas                | SPLIT-2          |
| SPLIT-4 | BLOCKED  | Rust TUI as a protocol v2 projection client                   | SPLIT-3          |
| SPLIT-5 | BLOCKED  | Daily-driver checkpoint and recorded go/no-go                 | SPLIT-4          |

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

**Status:** TODO

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

## SPLIT-3 — Streaming provider contract and content deltas

**Status:** BLOCKED (SPLIT-2)

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

## SPLIT-4 — Rust TUI as a protocol v2 projection client

**Status:** BLOCKED (SPLIT-3)

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

## SPLIT-5 — Daily-driver checkpoint and recorded go/no-go

**Status:** BLOCKED (SPLIT-4)

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
