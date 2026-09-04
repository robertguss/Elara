# Elara roadmap

> **Canonical roadmap and status source** · **Updated:** 2026-09-04
> (daily-driver product contract expanded) · **Owner:** solo development with AI
> collaborators

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

ER-3 is closed as a **METHOD STOP**; V9 is not planned. Durable effects remain
**frozen at PROD-1's scope**. SPLIT-1 has crossed the execution process boundary,
but receipt wiring for `edit`, `bash`, plugins, and remote workers is still
deferred until the post-checkpoint decision. Durable message delivery in the
items below does not imply exactly-once external commands or edits.

The direction is now the **Rust + Elixir split** decided in
[`docs/rust-elixir-split.md`](docs/rust-elixir-split.md) after two throwaway
spikes (2026-09-02). Elixir remains the single authority: session reducer,
journal and replay, loop policy, providers, plugins, supervision, and the effect
ledger. Rust owns two edge programs running as separate processes: an execution
stub behind an Erlang Port and a terminal UI behind a socket. The boundary is a
versioned line protocol; no NIFs. That document holds the architecture,
evidence, and reversal signals; this file holds the queue and status.

The foundations are shipped, but the current Rust client is not yet a credible
daily driver. TUI-3 is implementing the multiline composer; the transcript is still
always-following, tool output is truncated, and session selection is CLI-oriented. Starting SPLIT-5 in that state would measure missing product basics
rather than the Elixir/Rust boundary.

[`xai-org/grok-build`](https://github.com/xai-org/grok-build) remains the
interaction north star, not a parity mandate. The owner approved three original
visual layouts, four independent dark themes, and the daily-driver requirements
below. Amp contributes the dark-green palette reference and persistent
communicating-thread ideas. These are product requirements, not claims that the
HTML prototypes or existing batch coordinator already implement them.

Build the TUI foundations first, then provider/input and session controls, then
persistent communicating threads and automatic handoff. Both the TUI and threads
must be usable before SPLIT-5. TUI-3 remains the next executable item. Later
slices are bounded vertical deliveries; the expanded scope must not be hidden
inside the composer or session picker.

Rust owns presentation and interaction state; Elixir owns canonical content,
provider configuration, input delivery, thread relationships, and continuation.
Protocol v2's snapshot/patch foundation is retained, with explicit versioned
extensions where authoritative facts are missing. Layouts and themes do not
require a second session implementation. Do not add wire-level render blocks.

## Daily-driver product contract

The following decisions were settled with the owner on 2026-09-04. They
supersede earlier non-goals only where explicitly mapped here. Historical DONE
Results remain evidence of what shipped at that time, not present queue advice.

| Requirement | Settled behavior | Delivery |
| --- | --- | --- |
| Terminal target | Dark appearance; Ghostty and WezTerm on macOS | All TUI items |
| Layouts | Ember: inline thinking; Observatory: side thinking pane; Workbench: turn navigation and thinking strip | TUI-7 |
| Themes | Ember charcoal/amber, Observatory blue-black/teal, Workbench violet/lavender, Forest dark-green/sage; any layout with any theme | TUI-7 |
| Appearance selection | Choose before starting, save defaults, switch mid-session without restarting work | TUI-7 |
| Thinking visibility | Provider-exposed reasoning summaries/text expanded by default, remain open after completion, user can hide/show; readable and distinct from answers and tool activity | PROV-2, TUI-7 |
| Provider | ChatGPT/Codex subscription is the initial daily-driver target; in-TUI model and reasoning-effort selection | PROV-2 |
| Prompt and transcript | Multiline editor, reliable text paste, history, independent scrolling/search, mouse scrolling, clickable tools, drag selection and copy | TUI-3, TUI-4, TUI-5 |
| References and attachments | `@path` completion and real file references; attach images from disk and deliver image content to the model | INPUT-1 |
| Queue and steer | Queue follow-ups until the turn ends; delete pending messages; steer at the next safe boundary; explicit interrupt remains available | CTRL-1 |
| Instructions and skills | Standard `AGENTS.md` and Agent Skills `SKILL.md`, including existing owner-selected skill directories | INST-1 |
| Approvals | Trusted local execution without per-command or file-edit approval prompts by default; no repeated approval on child work or handoff | CTRL-1 |
| Session lifecycle | Find, create, name, switch, resume, inspect, fork/clone, and safely remove sessions within the TUI | TUI-6 |
| Communicating threads | Persistent children, parent/child messages, results and follow-ups; open a child to inspect or guide it | THREAD-1, THREAD-2 |
| Context continuity | Early context warning; automatically prepare a handoff and continue in a linked fresh thread, without owner approval | CTX-1 |
| Trial scope | All three layouts, all four themes, and all requirements above precede primary-use evaluation | SPLIT-5 |

Out of scope for this trial: clipboard image paste, queued-message editing,
MCP (future plugin), cloud/orb infrastructure, extensive approval policy,
multiplayer, foreign thread import, and copying all Grok Build features.
Plan/read-only mode is a nice-to-have, not a prerequisite. Existing capability
restrictions remain enforceable; no-approval does not mean ignoring execution
errors, filesystem confinement, or truthful indeterminate results. Existing
non-ChatGPT providers are preserved, but new feature parity is not required.

### Evidence and unresolved implementation facts

- The current ChatGPT adapter encodes text-only user messages, ignores
  reasoning-summary stream events, and does not request reasoning effort or
  summaries. Provider-native encrypted reasoning is continuation data, not
  displayable thinking. PROV-2 must verify capabilities on the actual
  subscription route; public Responses API documentation is not proof of
  entitlement or support there.
- `Elara.Prompt.system/1` loads only cwd `AGENTS.md`; standard skills discovery
  and nested instruction handling are not implemented by that behavior.
- The existing coordinator supports bounded parallel children and temporary
  coding worktrees, but forces `persist: false` and disables child plugins.
  THREAD-1 must replace those lifecycle assumptions for persistent work.
- The default embedded server ends when the TUI command exits. TUI-6/THREAD-1
  must distinguish that lifetime from explicit long-lived server operation.
- Tool output has source and Core limits, and protocol lines are capped at
  16 MiB. An expanded viewer cannot recover bytes already discarded upstream.
  INPUT-1 and CTX-1 must budget attachments and serialized snapshots as well as
  model context.
- The screenshots and approved prototypes establish design direction, not
  terminal rendering or provider acceptance evidence. The detailed reference
  analysis is in [Grok Build TUI research](docs/grok-build-tui-research.md) and
  [Amp thread research](docs/amp-thread-research.md); neither is another queue.

### Shared completion contract for new items

- Exercise the shipped interactive path with scripted/loopback fixtures and
  appropriate direct tests. Headless goldens alone do not prove key, paste,
  mouse, clipboard, focus, resize, or alternate-screen behavior.
- Record terminal versions, dimensions, actions, and observed results for real
  Ghostty/WezTerm checks. Cover 80x24, 120x40, and a wide window; no inaccessible
  actions at narrow sizes. Only relevant features need repetition per item.
- Code changes pass both Rust crates' format/Clippy/tests, Mix format,
  warnings-as-errors compile, relevant tests, and full `mix test`. Keep offline
  tests offline; separately record credential-backed subscription checks for
  provider-dependent acceptance.
- Record the pushed commit, checks, deviations, remaining uncertainty, and
  actual authority work, Rust presentation work, protocol/DTO/fixture work, and
  cross-runtime debugging effort. Unknown effort stays unknown, never 0%.
- Preserve protocol ordering, control/observe ownership, old persisted-session
  readability, terminal cleanup, and receipt-backed write behavior. New request
  kinds must negotiate compatibility and fail explicitly on unsupported peers.
- A `DONE` label requires the item's behavior, not a prototype or a claimed
  future fallback. Unavailable provider functionality remains a named blocker;
  do not substitute invented thinking, usage, images, or model capabilities.

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
| MAC-1   | DONE     | Make the Rust exec stub build and retain cleanup on macOS     | TUI-1            |
| TUI-2   | DONE     | Render assistant Markdown in the Rust TUI                     | MAC-1            |
| TUI-3   | IN PROGRESS | Cursor-aware multiline daily-driver composer                  | TUI-2            |
| TUI-4   | BLOCKED  | Navigable transcript controller                               | TUI-3            |
| TUI-5   | BLOCKED  | Inspectable typed tool blocks                                 | TUI-4            |
| TUI-7   | BLOCKED  | Three layouts and four independent dark themes               | TUI-5            |
| PROV-2  | BLOCKED  | ChatGPT reasoning visibility, model controls, and usage       | TUI-7            |
| INPUT-1 | BLOCKED  | File references and image attachments from disk               | PROV-2           |
| INST-1  | BLOCKED  | Standard project instructions and Agent Skills               | INPUT-1          |
| TUI-6   | BLOCKED  | In-TUI session lifecycle and action discovery                 | INST-1           |
| CTRL-1  | BLOCKED  | Durable input queue, steering, and execution preferences      | TUI-6            |
| THREAD-1 | BLOCKED | Persistent delegated threads and preserved workspaces        | CTRL-1           |
| THREAD-2 | BLOCKED | Durable thread communication and TUI navigation              | THREAD-1         |
| CTX-1   | BLOCKED  | Automatic handoff and uninterrupted continuation              | THREAD-2         |
| SPLIT-5 | BLOCKED  | Daily-driver checkpoint and recorded go/no-go                 | CTX-1            |

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

## MAC-1 — Build and retain execution cleanup on macOS

**Status:** DONE

### Outcome

The owner can build and start Elara on Apple Silicon without removing the Rust
execution boundary or weakening its process-group cleanup contract.

### Scope and acceptance

- Compile Linux-only `prctl` use only on Linux. macOS retains the guardian,
  process group, kill-on-cancel/timeout/cap/manager-loss behavior, but relies on
  the OS reaper for orphan collection because Darwin has no child-subreaper
  equivalent.
- Replace Linux-only `pipe2(O_CLOEXEC)` with portable `pipe` plus fail-closed
  `fcntl(FD_CLOEXEC)` on both descriptors.
- Cross-check the exec stub for `aarch64-apple-darwin`; run the full Linux
  execution lifecycle suite to ensure the portable path does not regress
  zero-descendant behavior.
- Pass both Rust crates' format, Clippy, and tests; Mix format,
  warnings-as-errors compile, full tests, and `rg 'System\.shell' lib/`.

### Result

**DONE (2026-09-03).** Pushed implementation commit
[`991f2b4`](https://github.com/robertguss/Elara/commit/991f2b48a0eac997cbe9ed0e2d7e2053f31d10bc)
to `origin/main`.

The exec stub now compiles Linux's `prctl(PR_SET_CHILD_SUBREAPER)` hardening
only on Linux. Darwin keeps the same guardian and process-group kill behavior;
its init process reaps orphaned grandchildren because Darwin has no
child-subreaper facility. The output/control/event pipes now use portable `pipe`
followed by fail-closed `fcntl(FD_CLOEXEC)` on both descriptors. A unit test
verifies the close-on-exec flags, while the existing lifecycle suite confirms
the portable implementation retains interrupt, timeout, byte-cap, stub-loss, and
BEAM-death cleanup behavior on Linux.

Exact verification:

- `cargo check --all-targets --target aarch64-apple-darwin --manifest-path native/exec-stub/Cargo.toml`
  — exit 0; the owner's three missing-symbol compile failures are absent.
- `cargo fmt --check --manifest-path native/exec-stub/Cargo.toml` — exit 0.
- `cargo clippy --all-targets --manifest-path native/exec-stub/Cargo.toml -- -D warnings`
  — exit 0.
- `cargo test --manifest-path native/exec-stub/Cargo.toml` — 3 passed.
- `mix test test/elara/exec_integration_test.exs` — 6 passed, including zero
  ordinary descendants after interrupt, timeout, stub loss, and BEAM death.
- `mix format --check-formatted` — exit 0.
- `mix compile --warnings-as-errors` — exit 0.
- `cargo fmt --check --manifest-path native/elara-tui/Cargo.toml` — exit 0.
- `cargo clippy --all-targets --manifest-path native/elara-tui/Cargo.toml -- -D warnings`
  — exit 0.
- `cargo test --manifest-path native/elara-tui/Cargo.toml` — 5 passed plus empty
  binary/doc targets.
- `mix test` — 335 passed in 15.2 seconds. The documented `CrashTool`
  `RuntimeError: boom` line was the only expected error log.
- `rg 'System\.shell' lib/` — no matches; `git diff --check` — exit 0 before the
  implementation commit.

Deviations: no new dependency or platform-specific compatibility shim was
needed. `pipe` plus `fcntl` is safe here because each guardian is
single-threaded and cannot race another exec between descriptor creation and
flagging.

The owner subsequently confirmed with a screenshot that `mix elara.tui new`
builds, starts, and completes multiple turns on Apple Silicon. Process-group
interrupt/exit behavior remains daily-use evidence. macOS retains the
zero-ordinary-descendant process-group kill contract, but Linux alone gets
guardian-side orphan reaping; Darwin delegates that reaping to the OS.

Decision: unblock SPLIT-5. The Apple Silicon compile blocker is removed without
changing the Elixir/Rust boundary or moving policy into Rust.

## TUI-2 — Render assistant Markdown in the Rust TUI

**Status:** DONE

### Outcome

Assistant responses render as readable terminal Markdown instead of exposing
source markers such as `**bold**` and inline-code backticks.

### Scope and acceptance

- Parse final assistant messages and in-progress content deltas entirely in the
  Rust presentation layer. User prompts and tool output remain literal.
- Render headings, paragraphs, emphasis, strong and strikethrough text, inline
  and block code, ordered/unordered/task lists, blockquotes and alerts, links,
  image fallbacks, tables, rules, HTML, math, definitions, and footnotes using
  terminal-safe text and ratatui styles.
- Preserve the `ai` speaker label and streaming cursor across multiline output.
- Cover semantic text output and span/line styling directly, plus a headless
  transcript frame through the shipped renderer.
- Do not change protocol v2, Elixir DTOs, session policy, or persistence. Syntax
  highlighting and browser/image rendering are non-goals.

### Result

**DONE (2026-09-03).** Pushed implementation commit
[`220c18c`](https://github.com/robertguss/Elara/commit/220c18cb1943a5977a8bcb78c89ef50fc153de9e)
to `origin/main`.

Final and streaming assistant content now passes through `tui-markdown` in the
Rust transcript renderer. It produces terminal-safe headings, emphasis, code,
lists, quotes, links, image fallbacks, tables, and the library's other supported
CommonMark/GFM blocks while preserving the `ai` label on the first line,
continuation indentation, and streaming cursor. User prompts and tool output
remain literal. Direct semantic/style tests and a headless golden cover the
shipped rendering path.

Exact verification:

- `cargo fmt --check --manifest-path native/elara-tui/Cargo.toml` — exit 0.
- `cargo clippy --all-targets --manifest-path native/elara-tui/Cargo.toml -- -D warnings`
  — exit 0.
- `cargo test --manifest-path native/elara-tui/Cargo.toml` — 7 passed plus empty
  binary/doc targets.
- `cargo check --all-targets --target aarch64-apple-darwin --manifest-path native/elara-tui/Cargo.toml`
  — exit 0.
- `cargo fmt --check --manifest-path native/exec-stub/Cargo.toml` — exit 0.
- `cargo clippy --all-targets --manifest-path native/exec-stub/Cargo.toml -- -D warnings`
  — exit 0.
- `cargo test --manifest-path native/exec-stub/Cargo.toml` — 3 passed.
- `mix format --check-formatted` — exit 0.
- `mix compile --warnings-as-errors` — exit 0.
- `mix test test/elara/protocol_v2_test.exs test/elara/tui_test.exs` — 12
  passed.
- `mix test` — 335 passed in 15.6 seconds. The documented `CrashTool`
  `RuntimeError: boom` line was the only expected error log.
- `rg 'System\.shell' lib/` — no matches; `git diff --check` — exit 0 before the
  implementation commit.

Deviations: none from product scope. Ratatui moved from 0.29 to 0.30 and
crossterm from 0.28 to 0.29 to use the current `tui-markdown` release. Syntax
highlighting remains deliberately disabled, avoiding its heavier dependency
tree; fenced code still renders with terminal styling.

Remaining uncertainty: the owner still needs to judge styles, colors, and
streaming behavior in the actual macOS terminal. Streaming reparses the
accumulated Markdown on each redraw; this could need optimization for unusually
large in-progress responses.

Original decision: unblock SPLIT-5. This is checkpoint feature 1 of 5: Rust
duplicated no session policy or transition logic, and protocol/DTO
synchronization was 0% of the implementation because the change remained
presentation-only. The 2026-09-04 daily-driver review superseded the immediate
checkpoint handoff: TUI-2 proved Markdown rendering, not that the client had the
interaction baseline required for primary use. Proceed to TUI-3.

## TUI-3 — Cursor-aware multiline daily-driver composer

**Status:** IN PROGRESS

### Outcome

Compose and revise realistic multiline prompts while a session streams, without
losing text, cursor, or selection. This is the next executable item.

### Scope and acceptance

- Introduce one Rust editor state for text, cursor, selection, and history.
  Support insertion/replacement, grapheme-aware movement and deletion, word
  movement/deletion, Home/End, wrapped-line navigation, and bounded growth.
- Enter submits; Alt-Enter inserts a newline; accept Shift-Enter when distinct.
  Show the actual available bindings. Detect terminal keyboard support and
  retain a working fallback in Ghostty and WezTerm rather than assuming every
  modified Enter is distinguishable.
- Enable bracketed paste so normal clipboard paste preserves multiline content
  without submitting it. If framing is unavailable, offer an explicit safe paste
  mode; unframed pasted newlines cannot reliably be distinguished from Enter.
  Include Unicode, combining characters, emoji, tabs, and escape-like text;
  terminal control bytes cannot execute. Verify the actual terminal bindings.
- Recall canonical user prompts without mutating history. Returning to the
  newest history position restores the original draft. Patches, resnapshot,
  interruption, and resize preserve local editor state.
- Clear the submitted buffer only on authoritative acceptance. Busy/rejected
  submission keeps it; uncertain acknowledgement remains visible rather than
  encouraging a blind retry. CTRL-1 adds durable request identity and queues.
- Keep the cursor visible and a useful transcript viewport at 80x24. Test the
  exact submitted text plus empty, wrapped, selected, and tall editor frames.
- Complete the shared checks and real-terminal typing/paste exercise.

### Boundaries

`@path` and image disk attachment ship in INPUT-1, and queue/steer in CTRL-1;
these are required later slices, not post-trial deferrals. External editor,
Vim mode, configurable keymaps, and fuzzy prompt-history search remain deferred.

### Result

**IN PROGRESS (2026-09-04).** Implementation commit `dd9d80b` is saved locally
on `codex/tui-3-composer`; native terminal acceptance remains open. The branch
has not been pushed. The approved six-file roadmap/research
revision was imported byte-for-byte from the owner's original checkout before
implementation. That checkout and historical DONE Results were not modified.

Rust now owns one grapheme-aware editor for text, cursor, selection, wrapped
navigation, and bounded canonical prompt history with original-draft restoration.
The composer grows to at most one third of screen height, keeps its cursor in
view, accepts bracketed multiline paste, and has F1 help and F2 explicit safe
paste. Ctrl-J is the unconditional newline fallback; modified Enter is accepted
when distinct and keyboard-protocol detection controls the advertised hint.
CRLF/CR normalize to LF, tabs are retained, other C0/C1 controls are removed,
and inserts over 64 KiB are rejected atomically. Drafts remain local to the
client window and are not persisted after exit.

The client correlates existing protocol-v2 command replies in connection order.
Only an ask's successful reply clears an unchanged submitted editor revision;
busy/rejected sends and edits made while waiting are retained. A pending/uncertain
ask cannot be resent, including after disconnection; the window remains open
for inspection. Patches, resnapshot, interruption, and resize preserve local
editing state. No new wire commands, Elixir session policy, durable queues,
submission deduplication, file attachments, or later roadmap slices were added.

Verification recorded so far:

- TUI Rust tests: 24 passed, including existing projection/Markdown goldens,
  Unicode editing, exact draft restoration, reply correlation, safe paste,
  resnapshot/interruption preservation, visible cursor at 80x24, and explicit
  empty/wrapped/selected/tall composer frames. Pending/uncertain acceptance
  remains visible in the fixed status bar even behind a long transcript.
  Regression tests cover LF/CRLF safe paste, repeated history replacement,
  no-op Delete during submission, and delayed/late acknowledgement.
- Targeted TUI product tests: 6 passed, including prompt-validation failure and
  the interactive PTY product test
  against a real Elara server using the scripted provider. It checks exact
  Unicode multiline submission, selection, streaming/busy retention, interrupt,
  history, safe paste with LF/CR/CRLF, 80x24/120x40/180x45 resize, and alternate-screen/paste
  cleanup. PTY emulation is not native-terminal or clipboard evidence.
- Both Rust crates: format and all-target Clippy with `-D warnings` passed;
  exec-stub tests: 3 passed. Mix format and warnings-as-errors compile passed.
- Full `mix test`: 335/338 passed. Three opaque-shell process-lifetime tests
  fail because the existing helper reads Linux `/proc/<pid>/stat` on macOS.
  Isolated rerun and an unchanged archive of baseline
  `cc6e778fd3f1951fe7fcdc68fc3a2c1f79b094ae` both reproduced 17/20 passing with
  the same three failures. No effect code or assertions were altered.
- Installed terminal versions: Ghostty 1.3.1; WezTerm
  20240203-110809-5046fc22. Computer Use denied access to both apps, including
  a retry requested by the owner. Native typing, modifier mappings, clipboard,
  and resize evidence in those terminals remains unavailable. No subscription
  calls or screenshots were used for this item.

Remaining acceptance: native Ghostty/WezTerm checks at the required dimensions,
full-suite passing evidence on a supported host (or a separately scoped fix for
the baseline macOS tests), and publication of the reviewed branch. Keep TUI-4
BLOCKED.

Review: completed `ce-code-review` run `tui3-206f19d8`, including independent
Claude review and a fresh validator. No remaining actionable findings after
fixing reproduced safe-paste LF/CRLF, history-sentinel bounds, no-op Delete
revision, and unsent headless ask issues. Full local receipt is at
`/tmp/compound-engineering-501/ce-code-review/tui3-206f19d8/review.json`.
Additional uncertainty: lost/delayed acknowledgements have model-level coverage,
not fault-injected socket evidence; responsiveness at the 64 KiB limit is not
measured. These are not claims of native-terminal acceptance.

Boundary evidence: authority implementation unchanged; Rust implements editor,
input dispatch, layout, and connection-local acknowledgement tracking. Protocol
schema/DTO changes: none. Fixture work adds a Python-stdlib PTY driver to the
existing Mix product test. Debugging found missing terminal-query responses in
the initial fixture and confirmed the baseline `/proc` test limitation. Actual
authority/presentation/protocol/fixture/debugging time shares were not separately
tracked and remain unknown; no percentage is inferred from changed-line counts.

## TUI-4 — Navigable transcript controller

**Status:** BLOCKED on TUI-3

### Outcome

Inspect, select, search, and copy earlier work while streaming continues,
without jumping to the tail or attaching focus to the wrong entry.

### Scope and acceptance

- Derive semantic entries from canonical messages, streams, tool IDs, and
  outcomes. Keep prompt/transcript focus, scroll offsets, selected entry, and
  visible follow-tail state in Rust. Scroll by line/page/top/bottom and user
  turn; new output follows only in follow mode.
- Support mouse wheel scrolling and drag text selection, with keyboard copy
  and terminal-native copy/paste coexistence. Copy selected text without UI
  chrome or injected wrap newlines; document the newline policy for real lines.
  Provide whole-entry copy as well as selection copy.
- Use an explicit clipboard strategy verified in both target terminals. Show
  failure/fallback honestly when clipboard delivery is unavailable; the required
  macOS path must actually put text on the clipboard. Mouse capture must not
  make native terminal selection impossible; document the escape/modifier.
- Add case-insensitive transcript search, next/previous match, and match count.
  Preserve anchors and selection through streaming, tool completion, resize,
  duplicate patches, and resnapshot, or use a documented surviving-entry fallback.
- Keep dispatch, help, and footer hints derived from one small Rust action
  registry now; TUI-6 extends it rather than inventing another registry.
- Test long wrapped Unicode content, selection across entry boundaries, search,
  copying, focus changes, and leave-tail/return-tail behavior. Real mouse and
  clipboard checks are mandatory alongside headless frames and shared checks.

### Identity trigger

Use message position while history is append-only, stable tool-call IDs, and
stream IDs for transient content. Add authoritative message IDs only when a
reproducible test shows resnapshot/finalization cannot retain focus, history
becomes non-append-only, or an authority operation must target a message.
Existing store IDs are not automatically a stable wire contract. Renderer block
IDs and fold state stay Rust-owned. Session switching always namespaces anchors.

### Non-goals

No persisted bookmarks, raw-Markdown mode, Vim navigation, or asynchronous search
unless profiling shows synchronous search stalls interaction.

## TUI-5 — Inspectable typed tool blocks

**Status:** BLOCKED on TUI-4

### Outcome

Keep tool activity concise without hiding the command, arguments, available
result, failure, or reported mutation needed to understand the work.

### Scope and acceptance

- Replace unconditional six-line display clipping with compact, expanded, and
  fullscreen views keyed by tool-call ID. Keyboard and mouse can expand/collapse
  a block or enter/leave its viewer without losing transcript position.
- Show name, useful argument summary, and canonical pending/running/succeeded/
  failed/indeterminate state. Include cancellation, timeout, and truncation
  details when reported; never infer success from output text.
- Tailor views for bash/read/write/edit, with a lossless generic fallback.
  Expanded/fullscreen views expose all retained arguments and result text,
  scrolling, wrapping, search, selection, and copy.
- Distinguish display folding from upstream truncation. Show all retained bytes
  subject to documented terminal sanitization, and label source/Core caps.
  Never promise the full original process output after it has been discarded.
- Derive edit diffs only when canonical arguments/outcomes justify the shown
  before/after content. A failed edit is not a successful diff. Identify missing
  authority facts rather than silently reading current files as prior evidence.
- Preserve fold/viewer state across lifecycle patches and resnapshots. Test all
  four built-ins, a plugin fallback, long output, diff, failed and indeterminate
  cases; exercise real mouse/keyboard inspection and complete shared checks.

### Non-goals

No streamed shell-output protocol, syntax-aware full-file highlighting, custom
renderer for every plugin, or removal of source byte limits.

## TUI-7 — Three layouts and four independent dark themes

**Status:** BLOCKED on TUI-5

### Outcome

Choose among the approved visual directions without changing session behavior:
three layouts multiplied by four themes, all available before daily use.
The [approved visual reference](docs/elara-tui-visual-reference.md) identifies
the preserved prototype, original screenshots, and limits of that evidence.

### Scope and acceptance

- Before starting this item, complete the bounded PROV-2 subscription capability
  preflight: verify reasoning summaries, model/effort controls, disk image input,
  usage, and context-limit evidence. Record unsupported or unknown capabilities
  as blockers before building dependent presentation; full adapter work remains
  in PROV-2. This preflight does not change TUI-3 as the next executable item.
- Layouts: **Ember**, inline thinking in a restrained single-column conversation;
  **Observatory**, conversation beside a dedicated thinking pane; **Workbench**,
  turn navigation plus a thinking strip and inspectable work.
- Themes: **Ember** charcoal/amber, **Observatory** blue-black/teal,
  **Workbench** violet/lavender, **Forest** near-black green/sage inspired by
  the owner's Amp screenshot. Use semantic color tokens independent of layout.
- Provide a pre-session appearance picker, saved user defaults, and an in-session
  layout/theme action. Local preference writes and clipboard access are explicit
  presentation exceptions to the original TUI's no-file-access non-goal; Rust
  still must not parse session persistence or own workspace mutations.
- One projection, editor, transcript controller, and action registry serve all
  layouts. Changing layout/theme never asks, interrupts, reattaches, or changes
  provider settings. Preserve draft/cursor, semantic selection/anchor, folds,
  search, and thinking visibility; visible panes may reflow without exact pixel
  preservation. Session-specific state stays scoped to its session.
- Thinking starts expanded and stays open after completion. A user hide action
  remains in force through new chunks, completion, resize, and layout changes
  until the user shows it again. Model content comes from PROV-2; use labeled
  fixtures for this slice, never fabricate live provider reasoning.
- A separate thinking pane/strip identifies its source turn and whether it is
  live or historical. Follow-tail shows the active turn; inspecting a historical
  turn binds thinking to that turn until the user returns to live work. Preserve
  that identity in narrow overlays and restore focus on close. Test historical
  selection while live reasoning streams, including resize and layout changes.
- Define concrete theme tokens and reference frames in-repo during this item:
  background, surfaces, text, secondary text, focus, selection, reasoning, tool
  status, and diff colors. Essential and secondary text remain readable;
  target at least 4.5:1 contrast for text, and distinguish state with text/symbols
  as well as color. No forced animations or low-contrast thinking text.
- At 80x24, optional rails/panes collapse into accessible views. Test all 12
  combinations for idle, composing, streaming, reasoning hidden/open, tool
  failure, and narrow/wide resize. Both target terminals must support the actual
  layouts, focus, mouse selection, clipboard, and restoration of terminal state.
- Capture terminal screenshots for comparison with the approved visual studies
  and complete the shared checks. Prototypes are reference material, not code
  to transplant into ratatui.

## PROV-2 — ChatGPT reasoning visibility, model controls, and usage

**Status:** BLOCKED on TUI-7

### Outcome

Use the ChatGPT/Codex subscription from Elara with honest visible reasoning
summaries, in-TUI model/effort selection, and usable context accounting.

### Scope and acceptance

- Use the capability preflight recorded before TUI-7; refresh it if the route or
  model contract has changed. Verify the actual subscription route for visible reasoning summaries,
  model/effort options, image-input support, usage fields, and model context
  limits. Pin the observed contract/date and representative sanitized fixtures.
  Public OpenAI API guides inform the adapter but do not establish support on
  this private subscription route. Do not change provider or billing silently.
- Request supported reasoning summaries and deliver typed public content through
  provider events, Core, persistence, snapshot/patch, and the TUI. Distinguish
  reasoning summary, assistant progress/commentary, and final answer. Keep
  encrypted reasoning and auth tokens out of display DTOs and diagnostics.
- Preserve ordering and identities across interleaved reasoning/text/tool events,
  streaming finalization, interruption, persistence/resume, and resnapshot.
  Absent summaries are visibly unavailable, not an endless thinking indicator.
  All layouts show the same content and honor manual visibility state.
- Add authority-owned model/effort discovery or a small versioned supported
  catalog with source provenance. Handle unsupported settings explicitly.
  Active requests keep their original settings; accepted changes apply at the
  next request boundary and show current versus pending values truthfully.
  Resume and child creation inherit explicit effective settings.
- Expose input/output/cached/reasoning usage only when provided, distinguishing
  request usage, session totals, and context occupancy. Show a labeled estimate
  if exact occupancy is unavailable. CTX-1 needs a conservative preflight budget
  for instructions, history, tools, pending input, attachments, and output reserve.
- Test arbitrary SSE boundaries, no-summary responses, errors, settings rejected
  by the server, and state recovery. Record a real subscription turn with tool
  use, visible reasoning summaries where supported, and model/effort selection.
  Confirm image capability here before INPUT-1 depends on it. Shared checks pass.

### Boundaries

No hidden-reasoning reconstruction and no promise of raw internal thoughts.
Support is conditional on what the provider exposes. If a required capability
cannot be verified, report it as a blocker with evidence rather than treating a
placeholder as completion. Existing provider behavior remains compatible.

## INPUT-1 — File references and image attachments from disk

**Status:** BLOCKED on PROV-2

### Outcome

Reference project files with `@path` and attach disk images that the ChatGPT
model actually receives, while keeping input inspectable and recoverable.

### Scope and acceptance

- Provide responsive `@path` discovery with fuzzy/path matching, keyboard and
  mouse choice, spaces/Unicode, empty/error states, and visible selected items.
  Elixir owns workspace discovery and attachment ingestion; Rust owns the picker
  and draft attachment state. Standard file references remain distinct from
  images and ordinary typed text.
- Resolve chosen text files to a deterministic submission-time representation
  with path/source metadata and clear size limits. Do not read arbitrary files
  merely because the model sees an `@` in prose. Explain any clipped/omitted
  content; a filename alone must not masquerade as included file content.
- Accept explicit disk image selection, including absolute paths outside the
  repository (for example Downloads). Validate readable file, supported format,
  decoded type and size before submission. Deliver supported image content to
  the provider, not only a filename. No clipboard image paste is required.
- Store immutable attachment content or owned durable references sufficient for
  queued delivery, resume, and handoff if the original disk file moves/changes.
  The submitted attachment identity and preview metadata must agree. Support
  removal before send; missing/unsupported/too-large files keep the draft intact.
- Bound ingestion and rendering so large trees/images cannot freeze typing.
  Do not inline image blobs into every snapshot or violate the 16 MiB wire
  limit. Define chunking/reference retrieval or a smaller explicit attachment
  cap; never let local disk paths become arbitrary remote-client file reads.
- Test text/image round trips through persistence and actual provider conversion,
  queue-ready payloads, cancellation, restart, and bad paths. Record one real
  subscription image-understanding turn. Terminal thumbnail rendering is
  optional; selectable name/type/size plus verified model delivery is required.
  Complete shared checks in all layouts.

## INST-1 — Standard project instructions and Agent Skills

**Status:** BLOCKED on INPUT-1

### Outcome

Existing standard project instructions and skills influence actual Elara work,
including delegated children and fresh handoff sessions.

### Scope and acceptance

- Implement documented `AGENTS.md` scope and precedence for the repository root,
  invocation directory, and nested paths used by tools. Load applicable ancestor
  instructions deterministically; nearest scoped instructions specialize parent
  guidance and explicit user directions take precedence. Expose the loaded
  paths so the owner can diagnose missing instructions.
- Implement the portable Agent Skills directory/frontmatter contract: discover
  metadata, load selected `SKILL.md` instructions on demand, resolve supporting
  references/scripts relative to that skill, and support explicit skill use.
  Avoid loading every skill body into the context at startup.
- Support project and user skill locations plus explicitly configured existing
  directories/symlinks, without copying or mutating other harness installations.
  Define deterministic duplicate-name precedence and display source identity.
- Validate malformed/unreadable skills with actionable diagnostics. Distinguish
  portable skills from instructions that require unavailable vendor tools,
  plugins, or unsupported experimental fields. Standard format compatibility
  does not promise every harness-specific skill workflow will execute.
- Skills do not silently override an explicitly restricted capability set.
  Skill scripts execute through the normal Elara execution path, with the same
  no-approval default and outcome reporting as other authorized local work.
- Test root/nested precedence, explicit user override, duplicate skills, relative
  resources, missing dependencies, and selective loading. Verify inherited
  instruction/skill resolution in child and handoff paths when those ship.
  Complete shared checks; no MCP transport or Claude-specific format required.

Sources: [AGENTS.md](https://agents.md/) and
[Agent Skills specification](https://agentskills.io/specification).

## TUI-6 — In-TUI session lifecycle and action discovery

**Status:** BLOCKED on INST-1

### Outcome

Find, create, resume, name, switch, and safely remove sessions without copying
IDs or escaping to another shell UI.

### Scope and acceptance

- Extend Elixir-owned discovery/hydration for live and persisted resumable
  sessions in the current workspace: stable ID, name, update time, cwd,
  live/idle/running state, and effective provider/model where known.
- Rust owns picker layout, fuzzy name/ID filtering, selection, loading/empty/
  error states, and delete confirmation. Elixir validates create/resume/name/
  delete operations. Observers cannot gain control through a picker action.
- Switching detaches and attaches explicitly; no socket silently changes session
  identity. A running session remains server-owned. Preserve separate drafts,
  attachments, editor position, viewport, search, folds, and reasoning visibility.
- Extend TUI-4's action registry with new, sessions, name, tree, fork, clone,
  reload, why, interrupt, detach, help, appearance, and model/effort controls.
  Available actions, help, footer hints, and slash/action discovery agree.
- Support saved-session startup when no server is running, not just `new`.
  Document embedded versus long-lived server lifetime and show which is in use.
  Exiting an embedded VM is not background continuation; a persistent server is
  required for work to continue with no TUI. Do not silently change that contract.
- From one TUI create/name two sessions, switch while one runs, observe it,
  detach, restart the server, and resume correct transcripts. Delete confirmation
  binds the exact selected identity even if filtering/list updates occur.
- Reject deletion of active work with a clear stop-first path. Preserve old
  session-file readability, fork/clone behavior, and hydration/patch ordering.
  Incompatible clients fail explicitly. Complete shared checks.

### Non-goals

No imported foreign histories, generated titles, cloud session hosting,
multiplayer, or dynamic backend command marketplace. Thread references and
parent/child navigation follow in THREAD-2; model controls ship in PROV-2.

## CTRL-1 — Durable input queue, steering, and execution preferences

**Status:** BLOCKED on TUI-6

### Outcome

Send follow-ups while work continues, delete pending input, or steer the agent
without losing the message or confusing interruption with completion.

### Scope and acceptance

- Add an Elixir-owned durable inbox with stable submission IDs and canonical
  queued/accepted/consumed/cancelled/failed states. Define acknowledgements so a
  lost reply and reconnect cannot duplicate a logical submission. Keep sender
  and target identity available for future thread messages.
- While busy, ordinary submit queues FIFO for the next turn; show queue count
  and content. Each entry is delivered once in order when the prior turn ends.
  Deleting an entry races atomically with consumption: either cancelled or
  already consumed, never silently both. Editing queued messages is not required.
- Provide a discoverable steer action that prioritizes the selected instruction
  after the current safe model/tool boundary without waiting for the full turn.
  This means cancel/settle an active provider request as appropriate and let
  already-dispatched tool effects settle; do not dispatch further stale calls.
  Keep a separate immediate interrupt for explicit stop/cancel. Advertise
  different bindings for queue, steer, and stop with terminal fallbacks.
- Specify remaining-queue behavior after steer and stop: steer overtakes normal
  queued inputs but does not delete them; explicit stop pauses automatic queue
  draining until the owner resumes/sends again. Tool failures and cancellation
  remain truthful; a steering message does not prove a command was undone.
- Preserve draft/attachments until authoritative acceptance, and inbox entries
  across detach, server restart, and model errors. A disconnected acknowledgement
  is resolved by submission ID, not resending under a fresh ID.
- Default to trusted local execution with no per-command/file-edit approval
  prompts. Keep effective restrictions visible and enforce existing capability
  limits. A read-only preset may be added later; this item must not grow into
  a broad approval-policy engine. Queue/handoff never invent new approval gates.
- Test FIFO, multiple steers, deletion/consumption race, input during a long tool,
  stop with pending entries, reconnect/restart, provider failure, and observers'
  rejected mutation commands through the real protocol and TUI. Shared checks.

## THREAD-1 — Persistent delegated threads and preserved workspaces

**Status:** BLOCKED on CTRL-1

### Outcome

A parent can start independent child work that remains inspectable and resumable
instead of disappearing with a batch coordinator or temporary checkout.

### Scope and acceptance

- Build on sessions, Store, and existing coordinator primitives; do not add a
  parallel model loop. Persist child identity, parent/delegation relationship,
  assignment, effective provider/model/effort, workspace, and lifecycle state.
  Parentage is a product relationship, not a requirement to link crash fate.
- Add a model-callable start-child operation and user action. Give each child
  selected task context by default, with an explicit fork/history option rather
  than cloning the entire parent for every task. Load applicable instructions
  and skills in the child's actual workspace. Preserve explicit tool limits.
- Keep bounded concurrency and visible resource limits. Existing prompt/answer
  byte-derived token estimates are not total subscription usage accounting;
  use PROV-2 telemetry where available and label estimates honestly.
- Children can run concurrently while the parent continues. Completion/failure
  preserves their transcript and results; no automatic restart may replay
  uncertain mutations. Recovery reports interrupted/indeterminate state and
  reconciles already-recorded outcomes before issuing further work.
- Independent coding children get managed durable worktrees with a recorded
  base revision. Uncommitted parent changes are not silently included: transfer
  selected inputs explicitly when needed. Research may share a checkout with
  read-only capabilities. Process isolation alone is not edit isolation.
- Preserve child changes through completion, parent failure, coordinator stop,
  and server restart. Integrate selected child results through a recorded patch/
  commit operation that detects conflicts and never overwrites parent changes.
  Cleanup is separate from stopping and refuses to discard unintegrated work.
- Long-lived server operation supports children with no attached TUI. The
  embedded mode still ends with its VM; persisted recovery is not uninterrupted
  background execution. Parent stop does not implicitly stop children; provide
  an explicit stop-subtree operation with honest outcomes.
- Test two children (including coding), one child failure with sibling survival,
  parent exit, full restart, child resume, result integration/conflict, and
  preservation of uncommitted work. Shared checks plus real subscription smoke.

## THREAD-2 — Durable thread communication and TUI navigation

**Status:** BLOCKED on THREAD-1

### Outcome

Parents and children exchange instructions and completion reports, and the
owner can open, inspect, guide, and return from any child inside the TUI.

### Scope and acceptance

- Extend CTRL-1's inbox with sender/recipient thread IDs, message IDs, durable
  acceptance, deduplication, ordering, and delivery status. Completion reports
  include result, changed-file/workspace references, tests, failure/uncertainty,
  and a link to full evidence. Do not silently clip the only retained result.
- Provide model-callable send/read/status/wait operations and follow-up on an
  existing child. Parent and child can communicate both ways. A wait yields
  without repeated model polling; completion can wake an idle parent while an
  active parent receives the report at a safe boundary. No automatic interruption
  of active work just because a child finishes.
- Separate UI notifications from model-visible inbox entries. Reattach and
  resnapshot do not create duplicate reports or duplicate model turns. Respect
  paused/stopped parents, bound automatic wakeups, and prevent empty-message
  ping-pong or unbounded recursive spawning.
- Add a compact thread tree/list, parent/child links, unread/completion/error
  indicators, and open/return actions in all layouts. Show the child's transcript,
  tools, queue, effective model, and available reasoning summaries. Preserve each
  thread's local state and distinguish control from observation.
- Support referencing a known thread ID and bounded reading/search for relevant
  original messages. Return source message references and identify later
  revisions; a handoff summary is an index into evidence, not the only truth.
  No hosted URLs, vector database, or cross-project administration required.
- Keep foreign threads, observers, and thread text from impersonating the owner
  or changing unrelated threads. Agent messages have explicit provenance and
  respect the receiving thread's current authority and restrictions.
- Verify messages arriving during tools, duplicate/reordered transport, server
  restart, parent paused/resumed, child completion while the parent works, and
  user takeover of a child. Shared checks and real-terminal tree navigation.

## CTX-1 — Automatic handoff and uninterrupted continuation

**Status:** BLOCKED on THREAD-2

### Outcome

Warn before context runs out, then automatically hand off to a linked fresh
thread and keep working. No approval or manual send is required. Keep original
threads available for reference; do not silently compact the same history.

### Scope and acceptance

- Use PROV-2 usage/model limits plus conservative request-size estimates to show
  context occupancy, estimate confidence, and an early non-modal warning.
  Reserve room for pending tool outcomes, attachments, handoff generation, and
  response output. Check before each provider request, not only after responses.
  Model context and the 16 MiB snapshot limit are separate budgets.
- Trigger before the reserved budget is consumed. At a safe boundary stop new
  old-thread model work, settle active tool results, and produce a structured
  handoff: goal, owner decisions/preferences, active instructions, completed
  changes, exact verification evidence, unresolved problems, file/attachment
  references, next action, queued instructions, and child assignments/status.
- Create the successor with a fresh context, selected settings, workspace, and
  source-thread relationship. Retain access to original messages and durable
  attachments. Reload applicable instructions/skills; don't copy a stale system
  prompt or the entire old history into the new request.
- Preserve instruction provenance: transfer effective execution settings and
  capabilities from canonical Elixir state, never infer them from a generated
  summary. Retain source IDs and roles for owner instructions; treat the handoff
  summary as assistant-authored context. Tool output, retrieved files, and child
  reports cannot become owner instructions merely by appearing in a handoff.
- Persist handoff identity and stages before switching: source preparation,
  successor creation, delivery-owner transfer, and continuation start. Make
  recovery idempotent: one successor and one logical continuation for a handoff,
  even after crash or lost acknowledgements. An uncertain external command is
  reconciled/reported, not automatically re-executed to make progress.
- Transfer unconsumed queued inputs exactly once and route child reports to the
  current continuation owner without changing historical parentage. Late child
  completion during transfer is neither dropped nor delivered to both agents.
  Keep manually paused inputs paused. Explicit owner stop cancels automatic
  continuation; automatic handoff must never override a deliberate stop.
- The controlling TUI follows the successor by explicit attach/snapshot, retaining
  the owner's unsent draft/attachments and appearance. Preserve useful semantic
  navigation where entries survive; show a quiet source/successor breadcrumb.
  Observers receive the link without gaining control. Do not mislabel a network
  disconnection as successful handoff.
- If the provider limit is uncertain, use a conservative reserve. Bound handoff
  retries; if generation/validation fails, preserve the source and surface the
  failure rather than creating an empty successor or looping. Normal successful
  handoffs require no approval; unrecoverable errors may need user attention.
- Deterministic tests force low budgets while streaming, queued input, image
  attachments, active/late child work, and lost acknowledgements. Kill/restart
  between every transfer stage and prove no lost input, duplicate continuation,
  or replayed mutation. Include a too-large single input/tool-result case and
  prevent immediate successor-to-successor rollover loops.
- Test malicious instruction claims in tool/child content without authority
  promotion. Across repeated handoffs, seed a later owner correction, unfinished
  work, and completed verification evidence; verify correction precedence,
  retained obligations, and retrieval of original evidence without summary drift.
- Record one real subscription continuation across a handoff, showing useful
  retained context and ongoing work, plus shared checks. No generic exactly-once
  model-request or external-effect guarantee is claimed.

## SPLIT-5 — Daily-driver checkpoint and recorded go/no-go

**Status:** BLOCKED on CTX-1 (owner checkpoint)

### Outcome

Judge the complete daily-driver experience and the Rust/Elixir boundary using
actual work. This checkpoint cannot substitute for unfinished prerequisites.

### Entry criteria

- Every new queue item through CTX-1 is DONE with pushed commits, shared checks,
  terminal evidence, and item-specific acceptance. All three layouts and four
  themes, mouse/copy/paste, file/images, model controls, reasoning visibility,
  instructions/skills, queue/steer, persistent threads, and automatic handoff
  are usable. Provider limitations are resolved or remain explicit blockers.
- A representative coding task succeeds on the actual ChatGPT subscription in
  Ghostty and WezTerm, including tool execution, an image reference, child work,
  and continuation. Known provider limits cannot be replaced with mock evidence.
- Forced resnapshot, server restart, interruption, session/layout switching,
  and handoff neither corrupt history nor silently discard drafts, accepted
  prompts, attachments, or child results. Claims of seamless continuation apply
  to successful operation, not unhandled crashes or missing credentials.

### Scope and acceptance

- Use Elara as the primary client for two weeks including five real working
  days. Record usability defects separately from boundary costs; continue the
  architecture observation through a full month unless an early reversal signal
  is met. Do not require the owner to exercise unused features to justify BEAM.
- Preserve the original five-feature measurement cohort, TUI-2 through TUI-6,
  despite the inserted items. Record all added items separately and show total
  authority/presentation/protocol/fixture/debugging effort as well; do not dilute
  a costly boundary by reclassifying it as feature work or a theme change.
- Original code-based signal: reverse if at least 3 of that cohort's 5 features
  duplicated session policy, or its aggregate protocol/DTO synchronization
  exceeded 30% of implementation time. Report missing measurements as unknown,
  not passing. Report the expanded workload's costs beside this baseline.
- For the one-month usefulness signal, evaluate detached concurrent work,
  persistent parent/child communication, plugin reload, remote workers, and
  durable recovery. These are alternative benefits, not a requirement to use
  every feature. If the product is effectively one local interactive session
  and none of those advantages proves useful, retain the original reversal
  signal. Intent to build threads alone is not usage evidence.
- Record the keep/reverse recommendation, evidence, usability gaps, and next
  executable queue. A rewrite is a separately scoped implementation decision,
  not an automatic mutation performed by this checkpoint. Without an early
  signal SPLIT-5 stays open until the month of usage is observable.

### Feature evidence

| Baseline feature | Rust duplicated policy / transitions | Protocol/DTO share |
| --- | --- | --- |
| TUI-2 assistant Markdown | No; presentation only | 0%; no protocol or DTO changes |
| TUI-3 composer | Pending | Pending |
| TUI-4 transcript controller | Pending | Pending |
| TUI-5 typed tool blocks | Pending | Pending |
| TUI-6 session lifecycle | Pending | Pending |

Also record TUI-7, PROV-2, INPUT-1, INST-1, CTRL-1, THREAD-1, THREAD-2, and
CTX-1 costs and outcomes without changing the baseline denominator.

### Result

**BLOCKED (2026-09-04).** The owner expanded the daily-driver contract after
reviewing Grok screenshots and three visual prototypes, adding independent
layouts/themes, provider reasoning and controls, file/image input, standard
instructions/skills, mouse interaction, durable queue/steer, communicating
threads, and automatic handoff with no approval. The queue now delivers those
requirements before primary-use measurement. No implementation completion or
architecture keep/reverse decision is claimed by this roadmap revision.
