# Elara roadmap

> **Canonical roadmap and status source** · **Updated:** 2026-09-05 (CTRL-1 and
> THREAD-1/THREAD-2/CTX-1 pushed; SPLIT-5 next) · **Owner:** solo development
> with AI collaborators

This file is the only current plan and status source for Elara. Completed work
and retired research remain available in Git history rather than as parallel
roadmaps or archived planning documents in the working tree.

## Progress at a glance

**CTX-1:** DONE and pushed to `main`. Implementation, offline checks and real
subscription continuation acceptance passed: 448 Mix tests, 112 Rust TUI tests,
and 6 execution-stub tests. SPLIT-5 is ready for the owner checkpoint, not
started.

**THREAD-2:** DONE and pushed on `thread-2`: 434 Mix tests, 111 Rust TUI tests
and 6 execution-stub tests pass. See its Result for the published commit,
evidence and limits.

**Previous checkpoint:** THREAD-1 is DONE and pushed; live subscription smoke passed. 422
Mix tests, 108 Rust TUI tests and 6 execution-stub tests pass. CTRL-1 is DONE
and pushed. TUI-6 is DONE and pushed. INST-1 is DONE and pushed, including the
shared-check cleanup repair. INPUT-1 is DONE and pushed. PROV-2 is pushed in
`fb7a6a3`. TUI-7 is pushed in `0c968dc`; its hands-on acceptance remains
owner-deferred. TUI-5 is pushed in `e7c67bf`; TUI-4 in `de46872`.
TUI-3/TUI-4/TUI-5/TUI-7 hands-on acceptance remains deferred while away and does
not block later implementation.

Update this handoff and each item's Result after verified milestones. Continue
available agent work autonomously, committing and pushing completed changes;
pause only for necessary owner input or an external blocker. End each session
with the next concrete action. Close test terminal windows after testing.

| Checkpoint                                                | State                   | Evidence or next action                                                                                                  |
| --------------------------------------------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| TUI-3 composer and multiline transcript                   | Implementation complete | 25 Rust tests; 6 TUI product tests; pushed `0e1cbda`                                                                     |
| TUI-3 Linux shared checks                                 | Complete                | 338/338 Mix tests; both Rust crates pass format/Clippy/tests offline                                                     |
| TUI-3 WezTerm rendering and live resize                   | Verified                | 80x24, 120x40, 180x45; draft/cursor/selection retained                                                                   |
| TUI-3 native clipboard actions and Ghostty modified Enter | Verified for API path   | Exact canonical text; physical shortcuts remain unverified                                                               |
| TUI-3 physical keys and Ghostty resize                    | Deferred by owner       | Revisit when owner returns; does not gate later implementation                                                           |
| TUI-4 anchored scrolling, focus, and follow-tail          | Implementation verified | Semantic anchors, cached wrapping, explicit follow-tail; 45 Rust tests                                                   |
| TUI-4 search, selection, and clipboard                    | Implementation verified | Search paste preserves draft; review fixes cover reverse/stale drags and focus                                           |
| TUI-4 actions, help, product checks                       | Complete                | 7 TUI product tests; 339 full Linux tests; both Rust crates pass checks                                                  |
| TUI-5 tool inspection                                     | Implementation verified | 59 Rust TUI tests; 8 product tests; 340 offline Linux tests                                                              |
| TUI-7 layouts, themes, and appearance                     | Implementation verified | 72 Rust TUI tests; 9 product tests; 341 offline Linux tests; all five review findings fixed                              |
| PROV-2 subscription visibility and controls               | Complete                | Pushed `fb7a6a3`; 365 offline Linux tests, 11 macOS product tests, 82 TUI tests; live tool/summary proof                 |
| INPUT-1 file references and image attachments             | Complete                | Pushed `57f930c`; 381 offline Linux tests, 12 macOS product tests, 95 TUI tests, 5 native helper tests; live image proof |

**Next action:** SPLIT-5 owner daily-driver checkpoint. It has not started;
physical-terminal acceptance requiring the absent owner stays deferred.

**Deferred hands-on exercise:** in both terminals, verify physical Ctrl-J,
Alt/Shift-Enter, Cmd-V, Alt-Up/Down history, and F2 safe paste. Resize Ghostty
through 80x24, 120x40, and 180x45 while editing selected Unicode text; confirm
cursor, draft, and selection remain usable. Record results when performed.

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
`INVALID`, and `DEFERRED` (implementation available; named acceptance postponed).

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
daily driver. TUI-3 implements the multiline composer and TUI-4 adds independent transcript
navigation. TUI-5 adds typed tool inspection; session selection is still CLI-oriented. Starting SPLIT-5 in that state would measure missing product basics
rather than the Elixir/Rust boundary.

[`xai-org/grok-build`](https://github.com/xai-org/grok-build) remains the
interaction north star, not a parity mandate. The owner approved three original
visual layouts, four independent dark themes, and the daily-driver requirements
below. Amp contributes the dark-green palette reference and persistent
communicating-thread ideas. These are product requirements, not claims that the
HTML prototypes or existing batch coordinator already implement them.

Build the TUI foundations first, then provider/input and session controls, then
persistent communicating threads and automatic handoff. Both the TUI and threads
must be usable before SPLIT-5. THREAD-2 is the next executable item;
TUI-3/TUI-4/TUI-5/TUI-7 manual acceptance is owner-deferred. Later slices are
bounded vertical deliveries; the expanded scope must not be hidden inside the
composer or session picker.

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

| ID       | Status   | Item                                                          | Depends on       |
| -------- | -------- | ------------------------------------------------------------- | ---------------- |
| PROD-1   | DONE     | Ship receipt-backed local declarative writes end-to-end       | ER-3 METHOD STOP |
| PROD-2   | CANCELED | Ship receipt-backed local literal edits end-to-end            | PROD-1           |
| SPLIT-1  | DONE     | Rust execution stub in-repo; route built-in `bash` through it | PROD-1           |
| SPLIT-2  | DONE     | Protocol v2: snapshot-on-attach and sequenced patches         | SPLIT-1          |
| SPLIT-3  | DONE     | Streaming provider contract and content deltas                | SPLIT-2          |
| SPLIT-4  | DONE     | Rust TUI as a protocol v2 projection client                   | SPLIT-3          |
| PROV-1   | DONE     | ChatGPT/Codex subscription provider                           | SPLIT-4          |
| TUI-1    | DONE     | One-command embedded server for new TUI sessions              | PROV-1           |
| MAC-1    | DONE     | Make the Rust exec stub build and retain cleanup on macOS     | TUI-1            |
| TUI-2    | DONE     | Render assistant Markdown in the Rust TUI                     | MAC-1            |
| TUI-3    | DEFERRED | Cursor-aware multiline daily-driver composer                  | TUI-2            |
| TUI-4    | DEFERRED | Navigable transcript controller                               | TUI-3            |
| TUI-5    | DEFERRED | Inspectable typed tool blocks                                 | TUI-4            |
| TUI-7    | DEFERRED | Three layouts and four independent dark themes                | TUI-5            |
| PROV-2   | DONE     | ChatGPT reasoning visibility, model controls, and usage       | TUI-7            |
| INPUT-1  | DONE     | File references and image attachments from disk               | PROV-2           |
| INST-1   | DONE     | Standard project instructions and Agent Skills                | INPUT-1          |
| TUI-6    | DONE     | In-TUI session lifecycle and action discovery                 | INST-1           |
| CTRL-1   | DONE     | Durable input queue, steering, and execution preferences      | TUI-6            |
| THREAD-1 | DONE     | Persistent delegated threads and preserved workspaces         | CTRL-1           |
| THREAD-2 | DONE     | Durable thread communication and TUI navigation               | THREAD-1         |
| CTX-1    | DONE     | Automatic handoff and uninterrupted continuation              | THREAD-2         |
| SPLIT-5  | TODO     | Daily-driver checkpoint and recorded go/no-go                 | CTX-1            |

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

**Status:** DEFERRED — remaining hands-on checks postponed by owner

### Outcome

Compose and revise realistic multiline prompts while a session streams, without
losing text, cursor, or selection.

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

**IMPLEMENTED; MANUAL ACCEPTANCE DEFERRED (2026-09-04).** Implementation commit `dd9d80b` and evidence
commit `bb5e3d9` were pushed to `origin/codex/tui-3-composer`. Native terminal
acceptance remains open. The approved six-file roadmap/research
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

- TUI Rust tests: 25 passed, including existing projection/Markdown goldens,
  Unicode editing, exact draft restoration, reply correlation, safe paste,
  resnapshot/interruption preservation, visible cursor at 80x24, and explicit
  empty/wrapped/selected/tall composer frames. Pending/uncertain acceptance
  remains visible in the fixed status bar even behind a long transcript.
  Regression tests cover LF/CRLF safe paste, repeated history replacement,
  no-op Delete during submission, and delayed/late acknowledgement. A follow-up
  frame regression reproduced flattened submitted prompts, then verified the fix:
  user transcript lines preserve blank lines, indentation, literal Markdown,
  combining characters, emoji, and four-column tab stops.
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
- Supported-host acceptance subsequently passed on Linux ARM64 against exact
  commit `7aa6bd5` (product code through `0e1cbda`): **338/338 Mix tests** in
  19.9 seconds, seed 422801. Mix format and warnings-as-errors compile passed.
  Both Rust crates passed format and all-target Clippy with `-D warnings`;
  TUI tests: 25 passed; exec-stub tests: 3 passed. Environment: OrbStack container
  using `hexpm/elixir:1.20.2-erlang-29.0.3-ubuntu-noble-20260610`, Elixir 1.20.2,
  OTP 29.0.3, Rust 1.98.1. Dependencies were fetched before disconnecting the
  container network; all verification then ran offline with no provider credentials.
  The first container run exposed fixture prerequisites: root bypasses the
  unreadable-file test and a plain source archive lacks Git history needed by
  coordinator worktrees. Importing the exact commit via a local Git bundle and
  running as an unprivileged user resolved both; the 25 affected tests passed
  before the full rerun. No product code or tests were changed or skipped.
  Logs: `/tmp/elara-tui3-check/linux-mix-final.log`, `linux-rust.log`, and
  `linux-targeted.log`. The disposable container was removed after verification.
- Installed terminal versions: Ghostty 1.3.1; WezTerm
  20240203-110809-5046fc22. Computer Use denied access to both apps, including
  a retry requested by the owner. The subsequently requested built-in shell
  route successfully launched both terminals. WezTerm's CLI verified bracketed
  Unicode paste without submission, exact canonical text after Enter, Ctrl-J,
  history restoration, selection replacement, and F2 LF/CRLF safe paste at 80x24.
  The rebuilt transcript fix passed native frame checks at 80x24, 120x40, and
  180x45 with completed scripted turns. A temporary isolated Lua configuration
  using WezTerm's documented `set_inner_size` API then exercised live resize
  from 80x24 through 120x40 and 180x45 back to 80x24: Unicode draft and visible
  cursor survived; replacing the selection proved selection also survived.
  Evidence is under `/tmp/elara-tui3-check/followup-wezterm-*.txt` and
  `live-resize-*.txt`. Tests used stock/isolated configuration, not the owner's
  keymap. CLI input injection does not verify physical modifier mappings or
  system clipboard paste. Subsequent native-API checks below add clipboard
  evidence. No subscription
  calls or screenshots were used for this item. A temporary scripted-provider
  stream/final-text mismatch was corrected before the follow-up checks.
- Ghostty's installed `Ghostty.sdef` provides `input text`, `send key`, and
  `perform action`. Native API tests confirmed multiline Unicode/tab paste
  stays unsubmitted, and Alt-Enter/Shift-Enter insert newlines in canonical
  submitted text. `paste_from_clipboard` also preserved exact system clipboard
  text until Enter. Synthetic Ctrl-J emitted no bytes in a separate raw-terminal
  capture, while Alt-Enter emitted CSI `13;3u` and Shift-Enter emitted LF; this
  leaves physical Ctrl-J unverified rather than establishing an Elara defect.
  Ghostty's API rejected the attempted arrow-key names, so its history check
  remains part of the physical-key exercise.
- WezTerm's native [clipboard action](https://wezterm.org/config/lua/keyassignment/PasteFrom.html)
  preserved exact multiline
  Unicode/tab text in canonical submission. Its temporary Lua driver initially
  repeated the paste because callback state did not persist as expected; a
  file guard and a fresh session corrected the fixture before the successful check. Clipboard
  action evidence is recorded in `/tmp/elara-tui3-check/clipboard-results.txt`.
  These API actions do not verify the physical Cmd-V shortcut in either app.

Remaining acceptance: Ghostty interaction/resize, physical modifier mappings
and clipboard shortcuts in both terminals. Supported-host full-suite evidence
is now complete; the existing macOS test portability limitation remains recorded
above. The owner explicitly deferred those checks on 2026-09-04 and authorized later
items to proceed. TUI-4 is unblocked; these checks are not claimed as passed.

Review: completed `ce-code-review` run `tui3-206f19d8`, including independent
Claude review and a fresh validator. No remaining actionable findings after
fixing reproduced safe-paste LF/CRLF, history-sentinel bounds, no-op Delete
revision, and unsent headless ask issues. Full local receipt is at
`/tmp/compound-engineering-501/ce-code-review/tui3-206f19d8/review.json`.
Additional uncertainty: lost/delayed acknowledgements have model-level coverage,
not fault-injected socket evidence. One local WezTerm 80x24 sample measured
84 ms from a 64 KiB CLI paste to a visible tail marker, including CLI overhead;
the draft remained unsubmitted and could be replaced. This is a smoke measurement,
not a latency distribution or a claim of complete native-terminal acceptance.

Boundary evidence: authority implementation unchanged; Rust implements editor,
input dispatch, layout, and connection-local acknowledgement tracking. Protocol
schema/DTO changes: none. Fixture work adds a Python-stdlib PTY driver to the
existing Mix product test. Debugging found missing terminal-query responses in
the initial fixture and confirmed the baseline `/proc` test limitation. Actual
authority/presentation/protocol/fixture/debugging time shares were not separately
tracked and remain unknown; no percentage is inferred from changed-line counts.

## TUI-4 — Navigable transcript controller

**Status:** DEFERRED — implementation verified; hands-on acceptance postponed by owner

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

### Result

**DEFERRED (2026-09-04): implementation verified and reviewed; hands-on
acceptance postponed by owner. Implementation pushed in `de46872`.** Semantic message/tool/stream entries now support
independent transcript focus, wrapped line/page/user-turn navigation, explicit
follow-tail, case-insensitive search, drag selection, and selection/entry copy.
A shared action registry supplies dispatch and help. Rendering and wrapping are
cached; same-head snapshot installs explicitly invalidate semantic content.
Search paste is bounded/sanitized and cannot change the composer. Ctrl-C still
detaches while searching; safe-paste mode retains precedence.

- Verification: 45 Rust TUI tests and 3 execution-stub tests; both crates pass
  format and all-target Clippy. All 7 interactive TUI product tests pass on macOS.
  An unprivileged, network-disconnected Linux ARM64 container passes all 339 Mix
  tests, formatting, warnings-as-errors compilation, and both Rust crate checks.
  The new product test failed against TUI-3 before implementation; a stronger
  pasted-search regression failed before the routing fix and now passes.
- Native WezTerm 20240203-110809-5046fc22 at 100x30 verified exact whole-entry Unicode/newline clipboard
  contents via pbcopy/pbpaste, search 1/2 to 2/2, a paused viewport surviving
  streamed completion, explicit return to follow-tail, and injected SGR drag
  selection copying `TOP `. This is terminal API/protocol evidence, not physical
  keyboard/mouse acceptance. A repeat after cache/search fixes stalled in the
  WezTerm CLI before starting the client; the test GUI was terminated and no
  WezTerm test windows remain. Automated final-source checks passed independently.
- The owner deferred physical keyboard/mouse acceptance while away; Ghostty's
  TUI-4 clipboard/selection/resize exercise is also still unverified. Earlier
  TUI-3 Ghostty clipboard results do not establish TUI-4 acceptance.
- Full retained tool text is navigable; compact/expanded typed views remain
  TUI-5. Offscreen row virtualization is deferred as a broader redesign: caching
  avoids rebuilds during navigation, but layout still retains the full history.
  Elixir canonical authority and the wire protocol are unchanged.
- Review completed (`20260904-193903-tui4`) with seven local lenses and an
  independent Claude Opus 5 pass. All five validated findings were fixed: reverse-drag endpoints,
  Ctrl-X in search, outside wheel focus, stale drag lifecycle, and a product
  search assertion that now requires navigation to a different entry. Four new
  input tests failed before the fixes and now pass. No actionable findings remain. Residual risks: clipboard helpers are synchronous with
  no timeout; long-history streaming layout cost is unmeasured; search Backspace
  removes a Unicode scalar, not a whole grapheme. Clipboard failure/fallback and
  terminal-initialization failure cleanup lack dedicated product coverage.

## TUI-5 — Inspectable typed tool blocks

**Status:** DEFERRED — implementation verified; hands-on acceptance postponed by owner

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

### Result

**DEFERRED (2026-09-04): implementation verified and reviewed; hands-on
acceptance postponed by owner. Implementation pushed in `e7c67bf`.** Tool blocks use canonical call IDs and states, with typed bash/
read/write/edit summaries and a generic fallback. Space or the left gutter
expands/collapses; `f` or right-click opens fullscreen; Esc or right-click restores
the transcript viewport. Expanded/viewer copies include retained JSON arguments
and sanitized result text. Successful edit replacement snippets use canonical
old/new arguments, never workspace rereads or invented full-file prior contents.

- Verification: 59 Rust TUI tests and 3 execution-stub tests; both crates pass
  format and all-target Clippy. All 8 macOS TUI product tests and all 340 Mix tests
  in the offline, unprivileged Linux ARM64 environment pass, with formatting and
  warnings-as-errors compilation.
- The new product test invokes the real read tool on a 60-line Unicode file,
  then exercises keyboard expansion/fullscreen, pasted search deep in the
  result, complete retained-output copying, 80x24 → 120x40 → 180x45 → 80x24 →
  120x40 PTY resize with fresh result-body assertions at each size, viewport
  restoration at a different size, gutter collapse, right-click open/close, and
  submission of the preserved draft. It failed against TUI-4 before the viewer
  existed and now passes. Clipboard commands use an isolated subprocess sink.
- Simplification found and fixed a canonical-call shadowing defect; the existing
  Linux interruption product test also reproduced the false pending state. A
  new normal-transcript regression verifies running/succeeded/failed/
  indeterminate outcomes. Borrowed canonical calls replace redundant cloned
  reconciliation, and compact previews process only the required characters.
- Truncation notices identify text markers; a trailing marker is explicitly
  source-unverified because the current protocol does not expose typed cap
  metadata or configured limits. No numeric session
  cap is fabricated. Broad fold-state pruning and offscreen virtualization were
  skipped as separate behavior/design work.
- Review completed (`20260904-202126-d305fa2f`) with six local lenses and an
  independent Claude Opus 5 pass. All seven validated findings were fixed:
  bounded generic JSON previews, visible viewer connection state, safe-paste
  composer visibility, lifecycle-stable selection, resize rendering assertions,
  non-tool right-click selection, and honest truncation-marker attribution.
  Argument/result sections now retain section-relative selection, anchor, and
  drag offsets across status/notice changes. Five behavioral regressions failed
  before the fixes and now pass; generic preview work is bounded for large
  strings, arrays, and keys. No actionable findings remain.
- Physical keyboard/mouse and actual Ghostty/WezTerm inspection/resize acceptance
  remain owner-deferred while away; PTY event injection is not physical
  acceptance. No new terminal GUI windows were opened for TUI-5.


## TUI-7 — Three layouts and four independent dark themes

**Status:** DEFERRED — implementation verified; physical terminal acceptance postponed by owner

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
  in PROV-2. The observed preflight and remaining live-adapter blockers are recorded below.
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

### Result

**IMPLEMENTED and pushed in `0c968dc`; hands-on acceptance deferred (2026-09-04).** The bounded [subscription capability preflight](docs/subscription-capability-preflight.md)
is complete, with sanitized request/response evidence. Existing Codex subscription
authentication worked without refresh, credential copying, or changing project
defaults. Four synthetic requests completed: gpt-5.5 low/high reasoning summaries,
gpt-5.4-mini image input, and combined gpt-5.5 image/reasoning input. Returned
usage and the authenticated catalog establish available fields and advertised
272,000-token limits for the tested models; exact occupancy/enforcement remains
unverified. Summary parts and final-answer phase must remain distinct.

The current default gpt-5.3-codex returned HTTP 400 unsupported. The unsupported
default and absent Elara-specific login block a claim of a working live Elara
subscription experience; PROV-2 owns migration/selection and credential
integration. They do not block fixture-backed TUI-7 presentation explicitly
specified above. Do not fabricate live reasoning or silently change billing.
The implementation now provides all three layouts/four themes, F3 appearance,
explicitly saved local defaults, and F4/F5/F6 thinking/turn controls. A real
session/PTY check passes all 12 combinations while preserving a Unicode draft
selection, historical search and source binding, and sticky hidden state; a
second client launch confirms saved defaults and excludes preview content.
The Rust matrix covers 216 state/size frames and theme-token contrast. Final
verification passes: 72 Rust TUI tests, 3 execution-stub tests,
9 macOS PTY product tests, and all 341 offline Linux Mix tests. Formatting,
Clippy, and compilation with warnings treated as errors pass. Simplification
applied three bounded changes (named overlay states, borrowed prompt summaries,
and conditional overlay layout); the shared color pass remains deliberately
centralized. Independent review completed (seven local lenses and a served
Claude Opus 5 peer; high effort requested, actual effort unverified). Review
run `20260904-211017-c3cf99a3` identified five fixes: bounded turn summaries,
short-terminal modal visibility, wrapped-row accessibility, F4 in the thinking
view, and fresh F6 scroll state. All five reproduced in regression tests and
were fixed before publication. Turn summaries occupy bounded single rows; full
prompt content and copy ranges remain in the transcript. Product coverage also exercises F6
navigation, CLI precedence, malformed preferences, failed-save recovery, and
isolation from personal defaults. Physical screenshots and keyboard/mouse
acceptance remain owner-deferred. No WezTerm test windows remain open. Live
reasoning remains explicitly unavailable until PROV-2; preview content is never
persisted as canonical conversation content.

## PROV-2 — ChatGPT reasoning visibility, model controls, and usage

**Status:** DONE — pushed in `fb7a6a3`

### Outcome

Use the ChatGPT/Codex subscription from Elara with honest visible reasoning
summaries, in-TUI model/effort selection, and usable context accounting.

### Scope and acceptance

- Resolve the observed unsupported gpt-5.3-codex default and Elara credential
  integration explicitly; the preflight used existing Codex authentication only
  in memory and did not change production settings.
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

### Result

**DONE (2026-09-04), pushed in `fb7a6a3`.** Implemented typed public summaries/commentary/final
answers, persisted request/served model metadata, interruption recovery, and the
negotiated `provider_visibility_v1` extension. F7 selects model/effort for the
next request while showing active settings separately. Resume and child settings
inheritance are covered. Usage is provider-reported; unknown occupancy stays
unknown and the conservative byte estimate is labeled with its basis.

The Codex-only default is now `gpt-5.5`/`low`; provider selection stays explicit.
`ELARA_CODEX_AUTH_SOURCE=codex` opts into read-only Codex login reuse. A real
subscription session selected `gpt-5.5`/`high`, invoked a synthetic tool, received
a public summary and returned 469; the credential file was unchanged. The
[sanitized proof](docs/fixtures/subscription-product-proof-2026-09-04.json)
records the public content and telemetry. All 11 macOS product tests passed,
including real local HTTP/SSE through Core and the Rust PTY, live/historical
summaries, all-layout sticky hiding, next-request changes, persistence/resume,
and interrupted partial-summary reload. Final offline Linux Mix checks passed
365/365; both Rust crates pass formatting, Clippy and tests on macOS and Linux
(80 TUI library tests, 2 parser tests, and 3 execution-stub tests). Compilation
passes with warnings treated as errors.

The completed code review covered nine local lenses plus independent Claude
Opus 5, with fresh finding validation. All seven actionable findings were fixed:
event metadata round trips, both resume paths and cross-provider settings,
stable body copying and Markdown, extension negotiation, and legacy streaming
without duplicate native rendering. F7 interrupt/detach and deterministic
settings-save failure also have regressions. The pre-existing leading-hyphen
session-ID parser failure was fixed as an early TUI-6 prerequisite, using
standard `--` and the exact failing ID rather than favorable random IDs.

Remaining limits: exact context occupancy is unknown, model/effort support is
the dated observed catalog, and large cumulative streams still need an
end-to-end latency measurement. Older builds reject the expanded saved-settings
header, as documented in README. Physical terminal acceptance remains
owner-deferred; no required PROV-2 implementation work remains.

## INPUT-1 — File references and image attachments from disk

**Status:** DONE — pushed `57f930c`

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

### Result

**DONE (2026-09-04; pushed `57f930c`).**
F8 and explicit `@path` selection discover workspace references; F9 ingests a
local PNG, including paths outside the workspace; F10 inspects/removes selected
items. Elixir owns bounded discovery, validation, immutable submission content,
persistence, and provider conversion. Rust owns selection, attachment RPCs,
metadata rendering, and draft preservation. The negotiated
`input_attachments_v1` extension keeps image content out of snapshots and
recordings; a remote client uploads bytes rather than requesting arbitrary
server-side image paths.

Limits are four selections, 64 KiB UTF-8 text per reference with visible clipping,
and 2 MiB per PNG. Supported PNGs are 8-bit non-interlaced grayscale, RGB,
gray-alpha, or RGBA, bounded to 4096 pixels per dimension and 16M pixels.
The initial client retains disconnected drafts but requires relaunch to reconnect.
Other image formats and clipboard image paste are outside this slice.

Verification: 381 offline Linux Mix tests; 95 Rust TUI tests; five exec-stub
tests; both crates' format/Clippy checks; Mix format and warnings-as-errors
compile. Twelve macOS product tests pass. The new real-PTY product flow covers
Unicode/spaced file selection by mouse, unchanged editor selection, image removal,
invalid input, all layouts, submission-time text, immutable image delivery,
and persisted restart with the original files changed/deleted. The actual
subscription returned `left=blue; right=yellow` for the synthetic PNG through
Elara's production adapter; credentials remained unchanged and snapshots omitted
image bytes. See the sanitized image proof in
`docs/fixtures/subscription-image-product-proof-2026-09-04.json`.

Simplification applied two small behavior-preserving cleanups. Independent review
completed with nine local lenses and a separate Claude Opus 5 pass. Four validated
findings were addressed: image-bearing context estimates are explicitly unknown
and avoid image reserialization; text ingestion uses a bounded native read with
regular-file verification; file discovery coalesces outstanding queries; provider
and attachment pickers have exclusive keyboard ownership. Final post-fix shared
checks and all twelve macOS product tests pass; implementation is pushed.
Physical terminal acceptance stays owner-deferred. Authority, Rust presentation, protocol,
fixtures, and cross-runtime debugging all required work; exact time shares were
not measured and remain unknown.

## INST-1 — Standard project instructions and Agent Skills

**Status:** DONE

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

### Result

**DONE (2026-09-05).** Implementation
[`da9a690`](https://github.com/robertguss/Elara/commit/da9a6903f7e00bcc4a22c49d91a41d67ffa1759d)
and shared-check repair
[`d19bfc5`](https://github.com/robertguss/Elara/commit/d19bfc5a88c84165dd3e8fbd7b9d1223acbbe47f)
are pushed to `origin/codex/tui-3-composer`. Nothing was merged to main.

Elixir now resolves outermost-to-nearest `AGENTS.md` guidance for the invocation
directory and explicit built-in file-tool targets. New/changed instructions
defer the affected call before execution, including later same-scope calls in
the same model batch. The model receives the scoped context and can reconsider
without the duplicate-call guard confusing deferral with prior execution.
Context refresh and deferral are recorded facts, preserving offline replay.
Source paths, scope, user precedence, and unreadable-file diagnostics are
exposed.

The session advertises metadata-only skills from explicit, project, and user
locations, with deterministic duplicate precedence. The `skill` tool selectively
rereads and validates YAML frontmatter using `yaml_elixir`/`yamerl`, returns the
resource base, and leaves reference reads and script execution to ordinary
tools. Symlinks require no copying or mutation. Unsupported fields and
compatibility requirements are diagnostic, never capability grants or implicit
vendor setup. Coordinator children inherit normalized explicit skill locations
and capability limits while resolving project context in their own directory.

Verification:

- `mix test test/elara/instructions_test.exs test/elara/skills_test.exs test/elara/provider/open_ai_codex_integration_test.exs test/elara/protocol_v2_test.exs test/elara/tui_test.exs`
  — 36 passed, including real file mutation, script execution, restrictions,
  missing dependencies, scoped deferral, replay, child resolution, and the
  provider continuation/resume and shipped TUI paths.
- `mix format --check-formatted` and `mix compile --warnings-as-errors` —
  exit 0. A clean dependency build emits upstream yamerl OTP-29 deprecation
  warnings; no warnings were suppressed.
- Both Rust crates: format and Clippy with `--all-targets -- -D warnings` pass;
  exec-stub has 6 passing tests and elara-tui has 95 (80 library, 2 binary, 13
  attachment integration tests).
- `mix test test/elara/attachment_test.exs test/elara/exec_integration_test.exs --seed 134706`
  — 21 passed, including timed-out caller cleanup and draft retry, interrupt,
  timeout, output cap, stub loss, and BEAM-death process cleanup.
- `mix test --seed 134706` — **395 passed**. The expected CrashTool
  `RuntimeError: boom` log remains intentional.

The first full run exposed a pre-existing attachment-timeout cleanup bug, also
reproduced on the untouched starting commit. A cancellation already queued when
the Rust guardian started was treated as manager loss: it exited silently,
leaving Elixir's submitted job registered. The guardian now reports `rejected`
with stage `cancel` for proven pre-spawn cancellation, while actual manager loss
stays silent. A deterministic native regression failed on the missing reply
before the repair and passes afterward. No timeout was increased and no failing
test was skipped or weakened.

Deviations/limits: instructions use lexical absolute path scopes, not a sandbox
or shell parser; shell/plugin/remote targets require model-directed guidance
reads. Skill metadata refreshes on new session creation, and selected bodies
obey the existing tool-result byte cap. `system:` now overrides the base prompt,
not project/skill context. Existing coordinator paths are tested; future
THREAD/CTX handoff paths remain subject to their own integration acceptance. No
Rust presentation, protocol DTO, MCP transport, or approval UI was added.

Decision: unblock TUI-6. The shared-check gate is clear and INST-1 is published.

## TUI-6 — In-TUI session lifecycle and action discovery

**Status:** DONE

### Prerequisite repaired during PROV-2 verification

TUI-5 verification exposed an existing CLI parsing bug: URL-safe session IDs
starting with `-` are rejected as unknown options by `Args::parse`. Reproduced
with `-XRyHg3MnKDpFahPkoG7BA` during the macOS product suite and
`-cs4HS4nJbLUqcYi8LhWHw` during PROV-2 Linux verification. The parser now supports
standard `--` end-of-options handling, and native test launchers pass options
before `-- SESSION`. The exact failing ID has a deterministic regression;
unknown flags still fail. This prerequisite was advanced to unblock shared
verification; the remaining lifecycle scope below is unchanged.

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

### Result

**DONE locally (2026-09-05).** Elixir owns workspace-scoped live/saved
discovery, stable-ID hydration, naming, controlled clone/fork, and locked
deletion. Rust provides F11 fuzzy discovery, exact-ID confirmation, slash
actions and branch selection. Switching closes the old socket, installs a fresh
snapshot, and retains separate drafts, attachments (images re-ingested), and
view state. Observers remain read-only. Current-session deletion requires
switching away; running work must stop and another controller must detach before
removal.

Saved startup starts an embedded server when necessary; the footer identifies
embedded versus long-lived lifetime. `/reload` refreshes the snapshot and `/why`
shows scrollable diagnostics. Legacy chat saved-session ordering and explicit
live-ID attachment from another cwd remain compatible.

Verification: 401 Mix tests; 101 Rust TUI tests; 6 native execution-helper
tests; Mix format/compile and both Rust format/Clippy gates pass. Actual
scripted TUI interaction at 120x40 created/named two sessions, switched during
provider work, restored separate drafts, restarted the server and resumed the
transcript. Inspected captures cover picker metadata, exact-ID deletion
confirmation, and 80x24 observe mode. Regression tests cover saved resume,
clone/fork source invariance, observer rejection, busy deletion, socket closure,
and draft/image restoration. Earlier owner-deferred physical-terminal acceptance
stays deferred.

## CTRL-1 — Durable input queue, steering, and execution preferences

**Status:** DONE

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
  across detach, server restart, and model errors. A disconnected
  acknowledgement is resolved by submission ID, not resending under a fresh ID.
- Default to trusted local execution with no per-command/file-edit approval
  prompts. Keep effective restrictions visible and enforce existing capability
  limits. A read-only preset may be added later; this item must not grow into a
  broad approval-policy engine. Queue/handoff never invent new approval gates.
- Test FIFO, multiple steers, deletion/consumption race, input during a long
  tool, stop with pending entries, reconnect/restart, provider failure, and
  observers' rejected mutation commands through the real protocol and TUI.
  Shared checks.

### Result

Pushed in [`3219bf7`](https://github.com/robertguss/Elara/commit/3219bf7) on
`codex/tui-3-composer`. Stable submission and sender/session IDs, atomic
inbox/User persistence, FIFO normal inputs, FIFO priority steers, cancellation
receipts, explicit stop/pause/resume, immutable attachments, and capability
visibility ship through negotiated `input_queue_v1`. Legacy clients do not
receive inbox projection operations. Rust retains pending identity privately,
resolves uncertain acceptance by ID after reconnect/restart, and preserves
edited drafts. F12 and `/queue` inspect/cancel inputs; Ctrl-S and `/steer TEXT`
steer; Ctrl-X stops; inbox `r` and `/resume-inputs` resume.

Steering waits for dispatched tool results and suppresses unstarted sibling
calls. Durable executor receipts also gate subsequent queued work after a live
timeout or restart, including already-persisted indeterminate results. This is
input-delivery deduplication, not exactly-once external execution; receipt
wiring beyond the existing durable-effect scope remains deferred. Unresolved
executor evidence deliberately blocks draining rather than guessing that effects
stopped.

Verification: 411 Mix tests, 106 Rust TUI tests, 6 execution-stub tests; Mix
format/warnings-as-errors compilation and both Rust format/Clippy checks pass.
Real PTY coverage exercises queued Unicode input, pause/resume and draft
editing. Actual terminal renders of queued, paused, cancelled, and steered
states were inspected. No live provider credentials were needed.
Physical-terminal acceptance previously deferred by the owner remains deferred.

## THREAD-1 — Persistent delegated threads and preserved workspaces

**Status:** DONE

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

### Result

Implemented using ordinary persisted Sessions/Store and the existing model loop.
Durable child records retain parent identity, assignment, provider/model/effort,
canonical capability limits, actual cwd, base revision and lifecycle. Coding
children use managed committed-base worktrees; research shares read-only tools.
Model `start_child` and TUI delegation support selected assignment context or
explicit history. The child picker shows the four-active-turn bound, inspection
and independent open/resume. Explicit subtree interruption retains work.

Integration uses a clean-parent precondition, Git conflict checks and immutable
binary patch receipts; cleanup is separate, non-forced and refuses unintegrated
or ignored work. Restart never resubmits the assignment automatically. Canonical
restrictions survive generic saved startup; uncertain effects and integration
acknowledgements require explicit recovery. Embedded VM exit remains
interruption, not background execution. Read-only tools are trusted-local
limits, not an OS sandbox. Thread messaging/richer navigation remain THREAD-2.

Verified locally: format, warnings-as-errors compile, **422 Mix tests**, both
native crates' format/Clippy checks, **108 TUI Rust tests** and **6 exec-stub
tests**. Eleven new API/server/product tests include real PTY delegation of two
children, inspect/open, server restart/resume, sibling failure survival, parent
exit, clean/dirty/conflicting integration, nested parent cwd and a separate-BEAM
abrupt exit/restart without replay. Inspected real tmux captures at 80x24 and
120x40 cover child states, resource limit, workspace/base and full metadata.
Live ChatGPT subscription smoke **passed on 2026-09-05**, using the production
`openai-codex` adapter with `gpt-5.5` and low effort, not an API-key substitute.
In an isolated temporary Git repository, coding and read-only research children
completed while the parent remained usable. The coding child performed an actual
write/read in its separate worktree; research read the expected marker. Recorded
integration applied the expected bytes to the parent. A second BEAM process
resumed the same coding child with a paused inbox and preserved files, performed
another successful live read, and retained exactly one original assignment.
Credentials were saved privately with mode 0600 and were not copied into the
repo. Implementation
[`bd4fa99`](https://github.com/robertguss/Elara/commit/bd4fa99) and smoke
evidence [`99482a2`](https://github.com/robertguss/Elara/commit/99482a2) are
pushed on `codex/tui-3-composer`. Previously owner-deferred physical-terminal
acceptance remains deferred.

## THREAD-2 — Durable thread communication and TUI navigation

**Status:** DONE

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

### Result

Implemented and pushed on `thread-2` with owner authorization:
[`a4f0651`](https://github.com/robertguss/Elara/commit/a4f0651a491320a55beee547bb0fc74238fff2ab).
Based on the requested pushed feature branch; not merged. CTX-1 is now the next
TODO item; its implementation remains untouched.

Durable related-thread transport uses the existing Session inbox and model loop.
Stable IDs and acceptance-order receipts deduplicate retries and survive
restart. Assignments and messages preserve typed agent provenance; receiver
capability limits and owner control remain authoritative. Model
send/read/status/wait tools support existing children in both directions. Event
waits have no ordinary tool deadline, remain interruptible, and settle on target
loss without replay. Reports never interrupt active parents; stopped inputs
remain stopped, even when the stop preceded the first queued message. Eight
automatic agent turns, 64 pending transport entries per recipient and three
delegation levels bound wakeups/spawning; report responses cannot recursively
wake ancestors.

Full completion results, workspace, tool/test/file-operation source references
and uncertainty are retained separately from the labeled inbox preview. Bounded
original-message/report reads expose IDs, branch membership and later entries;
they exclude private provider continuation state and attachment image bytes. The
compact all-layout tree has parent/child open/return, completion/error states,
local unread notifications independent of model consumption, and existing
per-thread transcript/tool/queue/model/reasoning inspection. Notification
acknowledgements are local to the TUI process and survive
reattachment/switching.

Verification: `mix format --check-formatted` and
`mix compile --warnings-as-errors` pass; `mix test`: **434 passed**. Both native
crates pass `cargo fmt --check` and `cargo clippy --all-targets -- -D warnings`;
`cargo test`: **111 TUI tests and 6 execution-stub tests passed**. Real PTY tests
exercise child open/return and restart. Inspected actual tmux captures show all
three layouts at 120x40 plus Workbench at 80x24, control/observation, child
transcript/tools, a stopped queue, and parent return. Review images are in
`.amp/in/artifacts/thread2-*.png`.
Coverage includes real-tool delivery, reordered/duplicate retries, offline
acceptance, transport/session/fresh-BEAM restart, full-result pagination,
original owner revisions, wait cancellation/target loss, wake/depth limits,
report-loop suppression and child owner takeover. Fresh-BEAM verification caught
and fixed a Store decoder dependency on session-state atoms already being
loaded.

Limits: no new live-provider smoke is claimed; verification uses offline
providers and actual tools/terminals. THREAD-1's earlier subscription proof is
not relabeled as evidence for this change. File-operation references are not
independent proof of workspace mutations or test success. Interrupted work is
not automatically replayed after VM loss, and pending offline messages await
explicit session hydration. Earlier owner-deferred physical-terminal acceptance
remains deferred. Next: CTX-1.

## CTX-1 — Automatic handoff and uninterrupted continuation

**Status:** DONE

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

### Result (2026-09-05, implementation and subscription acceptance passed)

Implemented in
[`e25058e`](https://github.com/robertguss/Elara/commit/e25058e8480da9d19dc9f71d9abfd55f1ec051d0),
fast-forwarded from `ctx-1` into `main` and pushed with owner approval.
Pre-request accounting uses catalog limits, conservative UTF-8/image estimates,
a reported-usage floor, and explicit output/tool/handoff/uncertainty reserves.
The non-modal warning is labeled as an estimate; the 16 MiB protocol budget
remains separate.

The existing Session loop freezes source model work at a safe boundary, saves a
fixed successor identity, creates it paused, transfers delivery ownership, and
durably activates one logical continuation. Current instructions and skill
discovery reload; canonical settings/capabilities are independent of text.
Handoff text is a deterministic assistant-authored evidence index, not a lossy
replacement history or an invented completion narrative. Original IDs, roles,
attachments, owner corrections, tool outcomes, queued inputs, and child records
remain retrievable. Repeated handoffs reread originals. Child waits, completion
recovery, navigation and late delivery follow continuation ownership while
historical parentage stays unchanged.

The controlling Rust TUI explicitly attaches a fresh snapshot, retaining its
unsent Unicode draft, attachments and appearance. Observers do not auto-control;
failed attachments retain the draft and surface a retry path. Paused inputs and
deliberate stop are preserved. Failed generation/validation keeps the source;
impossible fresh contexts and eight-handoff chains are bounded. A consumed
continuation interrupted by VM loss is failed/paused rather than replayed.

Offline evidence: 448 Mix tests pass, including 14 CTX tests covering streaming,
real read-tool settlement, queued input ownership, immutable images, late child
reports, child rollover waits, malicious instruction claims, repeated owner
corrections, and impossible budgets. Separate BEAMs halt at prepared, created,
transferred, activation-persisted, activated and started stages, proving one
successor and no consumed-request replay. The actual TUI/PTY submits its
retained draft after observing successor-only output; this is not just a frame
fixture. `mix format --check-formatted`, `mix compile --warnings-as-errors`, and
`mix test` pass. Both Rust crates pass `cargo fmt --check`,
`cargo clippy --all-targets -- -D warnings`, and `cargo test`: 112 TUI tests (94
library, 2 binary, 13 attachment, 3 lifecycle) and 6 execution-stub tests.
Inspected actual-terminal captures under `.amp/in/artifacts/ctx-warning.png` and
`.amp/in/artifacts/ctx-continuation.png` show the non-modal estimate and
automatic successor with retained Unicode draft. These are rasterized terminal
captures, not physical-terminal color/keyboard acceptance.

Real subscription acceptance passed after owner device login: gpt-5.5 source
`hX2KvmNB3ODfZcOGGTDc2w` read the ORBIT brief and computed 17 × 23 = 391. A
second owner message corrected red to BLUE and included explicitly nonsemantic
padding to force the configured 100,000-token preflight budget (not the
provider's actual context limit). Automatic successor `_My_P8YzHkQ1JzCvKXfEiQ`
retrieved original source evidence with `thread_read`, wrote `report.txt`, and
read it back. The verified report retained ORBIT, `cedar-417`, 17 seats, unit
price 23, total 391, and BLUE. Exactly one handoff inbox entry was consumed; no
approval or manual continuation send occurred. The successor made 14 real
provider requests, with reported input usage from 2,132 to 5,028 tokens. Its
initial read used a transport message ID instead of a source-message selector;
it recovered using bounded transcript offsets. Final answer: "Created and
verified `report.txt` with corrected color BLUE and total 391." The sanitized
call/usage/result record is `.amp/in/artifacts/ctx-live-subscription.json`;
original sessions remain in the session store. This is live-provider evidence,
separate from the offline PTY rendering evidence above.

Limits: this bounded live task is not a long-running daily-driver trial. The
legacy synchronous ask returns `:interrupted` for the frozen source while the
successor continues through its own event stream. No generic exactly-once model
request/external effect guarantee is claimed. Physical-terminal owner acceptance
remains deferred. CTX-1 is DONE and published; SPLIT-5 is unblocked for the
owner checkpoint. No daily-driver go/no-go decision is made here.

## SPLIT-5 — Daily-driver checkpoint and recorded go/no-go

**Status:** TODO (owner checkpoint; CTX-1 published, trial not started)

### Result (2026-09-05, prerequisite publication)

CTX-1 is published on `main`, so this item is no longer blocked on feature
implementation. The owner trial has not started; physical-terminal entry checks
and the daily-driver go/no-go decision remain outstanding.

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
