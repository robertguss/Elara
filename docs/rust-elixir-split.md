# Rust + Elixir split: decision and implementation plan

> **Status:** adopted 2026-09-02. `ROADMAP.md` holds the queue and status
> (SPLIT-1 … SPLIT-5); this file holds the decision, evidence, architecture, and
> reversal signals. Do not track status here.

## 1. Decision

**Elixir stays the single authority. Rust owns the edges, across process
boundaries.**

- Elixir owns the session (state, journal, replay, fork), the agent loop and its
  policy, provider adapters, plugins, supervision, remote-worker routing, and
  the durable-effects ledger and receipts.
- Rust owns two edge programs: the terminal UI (a pure projection of a session
  it never owns) and the execution stub (a bounded, cancellable worker that runs
  commands in its own process groups). Later Rust candidates: shell interpreter,
  search/walker, AST, VCS helpers.
- The boundary is a line protocol over a socket (TUI) or an Erlang Port (stub).
  No Rustler NIFs on this path.

Fallback if the split fails (§9): **Rust everything**. Explicitly rejected:
**Rust core + thin Elixir** (two runtimes, authority in the one that Elixir
would merely supervise — unstable) and **Elixir only** (gives up the verified
TUI ecosystem win and most of the architecture experiment).

This is a phase decision, not a language verdict. Elixir is the better home for
the session authority because it already exists as a pure reducer with a
persisted journal and reattachable cursors, and the session model is still
changing. A Rust actor with an enum reducer could model the same DOM more
precisely; that becomes attractive once the model stops moving (see §9).

## 2. Why this and not something else

Judged against the owner's priorities — explore novel harness architectures,
converge to a daily driver for one person, maybe open-source later:

| Alternative                      | Exploration value                                                                                          | Time to daily driver                                                   | Verdict      |
| -------------------------------- | ---------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- | ------------ |
| 1. Elixir authority + Rust edges | Tests the Harness Playbook shape directly (control plane vs dumb stub, views as projections)               | Shortest: both edges already worked as spikes with zero Elixir changes | **Adopt**    |
| 2. Rust core + thin Elixir       | Same boundary cost as 1, but moves the authority out of the runtime whose remaining job is to supervise it | Full rewrite first                                                     | Reject       |
| 3. Rust everything               | Clean single schema, strongest agent priors                                                                | Full rewrite before any product feedback                               | **Fallback** |
| 4. Elixir only                   | Weakest; Elixir + `erlexec`-style wrapper solves exec but not the TUI                                      | Medium; TUI ecosystem gap                                              | Reject       |

What the BEAM concretely buys this harness today (verified in code):

- Serialized session ownership around a pure reducer:
  `Elara.Session.Core.step/2` with the GenServer shell owning tasks, timers,
  subscribers.
- Monitors and fault isolation around provider and tool tasks
  (`lib/elara/session.ex`).
- Atomic plugin reload with generations, leases and state migration
  (`lib/elara/plugin/server.ex`: `checkout/2`, `:stale_generation`,
  `:stale_lease`).
- Natural ownership of many detached sessions with control/observe attachments.
- Ports give a process fault boundary and an EOF lifecycle signal.

What it does **not** buy, so do not romanticize it:

- Sessions are `restart: :temporary` (`lib/elara/session.ex:85`); a crashed
  session is not resurrected.
- Remote workers are plain TCP (`lib/elara/executor/router.ex`), not BEAM
  distribution. Rust could own that equally well.
- A Port does not kill grandchildren. Verified: killing the tool `Task` around
  `System.shell("sleep 299")` leaves `sleep` alive, and it survives BEAM exit.
- The provider contract is non-streaming (`Elara.Provider.chat/2` returns a
  whole `Assistant` message). That is an application gap, not a runtime one.
- No TUI ecosystem; weaker compile-time protocol guarantees than Rust; a smaller
  pool of agent priors when agents write most of the code.

## 3. Spike evidence (throwaway code, outside the repo)

Both spikes ran today against unmodified Elara at `bd56cd9`.

### Spike A — Rust TUI as a projection over the existing protocol

`/home/user/workspace/spikes/a/` — ratatui 0.29 + crossterm 0.28 + serde_json,
~450 lines. Host: `Elara.Server` on port 14048 with a slow scripted provider.

- Attach with `--fresh` replays every retained event from seq 0 and renders.
- Crash test: client `abort()`ed at seq 16 mid-turn. The Elixir session kept
  going — the `bash` tool ran with no client attached. Reattach with the saved
  cursor replayed exactly seqs 17–19 in ~2 ms, then streamed 20–21 live.
- Live `ask` → `turn_started` ≈ 85 ms, of which ≈ 42 ms is Elixir's `ok` ack
  (not the seam). Worth a look later; not blocking.
- Headless mode (`--headless --dump-events`) renders a 100×24 `TestBackend`
  frame to stdout — the seed of a TUI debug/verification protocol.
- Build: 30 s cold, 0.36 s incremental.
- **Design finding:** cursor replay yields _missed events_, not _state_. A fresh
  view must either replay from 0 (bounded by the 1 000-event ring) or receive a
  materialized snapshot on attach. Protocol v2 (§5) fixes this.

### Spike B — Rust execution stub driven from an Elixir Port

`/home/user/workspace/spikes/b/` — Rust, serde_json + libc, ~250 lines, 771 KB
release binary; Elixir driver is a Port-based GenServer.

JSON lines: `run {id, argv, cwd, max_bytes, timeout_ms}` / `cancel` / `ping` →
`started` / `chunk` /
`exit {code, signal, cancelled, timed_out, truncated, bytes_total, bytes_sent, elapsed_ms}`.
Every job runs in its own process group; SIGKILL of the group on cancel,
timeout, or byte cap; stdin EOF kills all groups and exits.

Results, 7/7:

- Flood (`yes`): `bytes_sent` 65 536 of `bytes_total` 114 688, producer killed
  at source, not drained.
- Cancel round-trip 5 ms. `bash -c 'sleep & sleep & wait'` grandchildren killed.
- Timeout enforced in the stub. stdout/stderr and exit code 3 propagated.
- BEAM `System.halt` mid-job: stub saw EOF, killed all groups, exited; nothing
  leaked.
- 50 sequential echo jobs avg 18 ms (5 ms poll-loop artifact); 50 concurrent in
  73 ms.

Honest caveat: this could be done in Elixir plus a small `setsid`/C wrapper.
Rust's value here is one typed, self-contained binary that later runs unchanged
inside a container, VM or over ssh as the "dumb sandbox stub".

## 4. What the Harness Playbook and oh-my-pi teach, and what Elara adopts

Source: Can Bölük, "The Harness Playbook" (stencil.so, 2026-09-02) and the
`can1357/oh-my-pi` repository (read locally, `/home/user/workspace/oh-my-pi`).

Five consequences, mapped to Elara:

| Consequence                                                 | Elara today                                                                                  | Plan                                                                                           |
| ----------------------------------------------------------- | -------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| One authoritative journaled session                         | Yes: `Core.step/2`, store, seq/incarnation                                                   | Keep. Add materialized snapshot + patch stream (§5).                                           |
| Trusted control plane on host, dumb bounded stub in sandbox | No: `bash` is `System.shell` in-process, no kill boundary                                    | Spike B stub becomes the built-in executor (§8 slice 2).                                       |
| Bounded, cancellable work                                   | Partly: `max_tool_output_bytes` truncates in Core after the fact; nothing kills the producer | Stub enforces cap/timeout/cancel at source; Core keeps the central truncation with an opt-out. |
| Explicit compatibility knowledge                            | Single provider (xAI / OpenAI-compatible)                                                    | Skip the KDL compiler; add versioned protocol/tool schemas only.                               |
| Views are projections                                       | Line UI is coupled to the session process                                                    | Rust TUI is a projection client only; Elixir line UI dropped at parity.                        |

Adopt now: snapshot-on-attach + sequenced patches; provider content deltas
(streaming); one stdio-shaped bounded job primitive; central truncation with
opt-out; headless TUI rendering for tests; small tool roster with an `i`
(intent) argument and tool versioning.

Adopt later: Director-style loop ownership (Pass/Continue/Yield/Push/Done/Fail)
as an evolution of `Core.step/2`; corrective inference and validate-and-repair
of tool arguments; speculative compaction.

Skip for now: KDL provider taxonomy/compat compiler (one provider), convars and
`cfg`/`bind`/`alias`, in-process bash interpreter and coreutils (omp's
`pi-shell`), embedded Python extensions, TLA+ models.

Lessons from omp v1 that shape the boundary choice:

- Its TS↔Rust cancellation seam across napi-rs (AbortSignal → napi → tokio →
  process group, plus a JS watchdog and quarantine) is among its most complex
  code; panics need manual containment (`panic = "unwind"`). A process boundary
  with EOF-kills-everything semantics (Spike B) removes that class.
- Byte truncation there is enforced above the boundary in TS; Elara enforces it
  in the stub (at source) and keeps Core's cap as the second line.
- Approval in omp is pre-execution string patterns; the interpreter-time
  capability approval it enables is deferred here with the interpreter.

## 5. Architecture

```diagram
┌──────────────────────────────────────────────────────────────────┐
│ Elixir authority (one BEAM, supervised)                          │
│                                                                  │
│  Elara.Session (GenServer)     Elara.Server (TCP, protocol v2)   │
│   ├─ Core.step/2 reducer        ├─ attach → {incarnation, head,  │
│   ├─ journal / store / fork     │           snapshot}            │
│   ├─ event ring (delivery cache)├─ sequenced patches             │
│   ├─ directors / policy (later) └─ provider deltas               │
│   ├─ provider adapters                                           │
│   ├─ plugins (generations/leases)                                │
│   └─ effect ledger + receipts                                    │
│                                                                  │
│  Elara.Exec (Port owner) ──JSON lines──▶ ┌──────────────────┐    │
│                                          │ Rust exec stub   │    │
└──────────────────────────────────────────│ process groups   │────┘
        ▲ socket, protocol v2              │ cap/timeout/kill │
        │                                  └──────────────────┘
┌───────┴──────────────┐                   same job protocol later
│ Rust TUI (ratatui)   │                   over socket → remote /
│ projection only;     │                   container / VM stub
│ no policy, no state  │
│ authority; headless  │
│ render for tests     │
└──────────────────────┘
```

### Protocol v2 (TUI ↔ Elixir)

- `attach {session, mode, cursor?}` → `attached {incarnation, head, snapshot}`.
  The snapshot is a materialized view of the session (messages, tool calls with
  status, turn state, usage), not the event log.
- Then `patch {seq, ops}` messages transform that snapshot. Ops are a small
  closed set (append message, set tool status, append content delta, set turn
  state, set usage). The client applies them blindly.
- `delta {seq, message_id, text}` for provider streaming once `Provider` gains a
  streaming callback.
- Gap, expired cursor, or changed incarnation → client requests a new snapshot.
  The 1 000-event ring is a delivery cache, never an authority.
- Commands stay as today: `create`, `ask`, `interrupt`, `inspect`. Disconnect
  never implies cancellation (verified behaviour, keep it).
- Versioned: `protocol: 2` on hello; v1 line clients keep working until the
  Elixir line UI is dropped.

### Job protocol (Elixir ↔ stub)

Spike B's protocol, hardened:
`run {id, argv, cwd, env?, max_bytes, timeout_ms}`, `cancel {id}`, `ping` →
`started`, `chunk {id, stream, bytes}`,
`exit {id, code, signal, cancelled, timed_out, truncated, bytes_total, bytes_sent, elapsed_ms}`.
One supervised long-lived Port per BEAM; stub death fails all in-flight jobs as
`indeterminate`, not as success.

## 6. Preserve, drop, defer

Preserve: `Core.step/2` as the transition kernel (evolve its state/events, do
not replace it); store tree/fork/clone and session identity; seq cursors,
incarnation ids, control/observe ownership, replay semantics; controller intent,
operation digest, executor ledger, receipts and truthful `indeterminate`
outcomes; capability and placement metadata.

Drop: `System.shell/2` in `lib/elara/tools.ex` and
`lib/elara/effect/opaque_shell.ex` as soon as the stub is integrated (SPLIT-1);
the Elixir line UI once the Rust TUI reaches parity (SPLIT-4). The nil-executor
bypass in `Elara.start_session/1` was already removed by PROD-1.

Defer: Rust shell interpreter/coreutils, AST, walker, VCS; a cross-language
plugin ABI; further remote-worker and durable-effects generalization; any Rust
rewrite of the session authority.

## 7. Durable effects: frozen at PROD-1

PROD-1 shipped on 2026-09-02 (`4d87900`, `dd8629b`): receipt-backed built-in
`write` through `Elara.start_session/1`, `mix elara.ask`, `mix elara.chat`, with
recovery via `--continue`; the sidecar depends on the shared
`Elara.Effect.Executor` contract and the nil-executor bypass is gone. Durable
effects are now **frozen** at that scope. PROD-2 (receipt-backed `edit`) was
canceled: it would re-prove the same authority-side invariant on a second tool
while widening the surface the execution stub must later sit beneath. The
question returns after execution crosses the Port as "receipts around Port
jobs", a different design.

## 8. Implementation plan — vertical slices

The queue lives in `ROADMAP.md` as SPLIT-1 … SPLIT-5; this is the rationale for
its order. Sequencing favors foundations over an early daily driver: each layer
is built and tested before the layer that depends on it, and the daily driver is
the outcome of the sequence rather than a shortcut through it.

1. **SPLIT-1 — Exec stub, `bash` routed through it.** Smallest slice, fully
   proven by Spike B, removes the one safety hole in current Elara. Goes first
   so every later slice runs on a bounded execution substrate.
2. **SPLIT-2 — Protocol v2: snapshot-on-attach + sequenced patches.** Settles
   the attach and projection model (Spike A's design finding) while only the
   Elixir line client exists, so the TUI later targets a stable contract.
   Exercised through `mix elara.attach` before any Rust client.
3. **SPLIT-3 — Streaming provider contract and content deltas.** Lands after v2
   so deltas arrive as one more patch op on an already-settled stream; visible
   in the line UI first.
4. **SPLIT-4 — Rust TUI as a v2 projection client.** Pure patch applier with
   headless tests; the Elixir line UI is removed only after demonstrated parity.
5. **SPLIT-5 — Daily-driver checkpoint.** No new code: a fixed period of use,
   the §9 measurements, and a recorded keep/reverse decision.

Then, gated on SPLIT-5: small tool roster with intent argument and versioned
schemas; Director-style loop ownership inside `Core.step/2`; receipts around
Port jobs; the job protocol over a socket for remote stubs.

## 9. Go / no-go and reversal signals

Switch to the fallback (Rust everything) if the split turns out to duplicate
authority instead of projecting it. Measure over the next five session/UI
features after slice 3:

- ≥ 3 of 5 require Rust to duplicate session policy or transition logic, or
- protocol/DTO synchronization (serialization, version adapters, mirrored types,
  resync, cross-runtime debugging) consumes > 30 % of implementation time.

Also reverse if, after a month of daily use, detached concurrent sessions,
plugin hot reload, remote workers and durable recovery are simply unused. In a
"one local interactive session" product shape the BEAM's concrete advantages
vanish and Rust's priors, TUI ecosystem and single-schema guarantees dominate.

Keep the split if the TUI remains a blind patch applier and the stub remains
policy-free.

## 10. Risks and unknowns

- Two toolchains: Rust must be installed to build Elara; distribution means
  shipping a Rust binary next to a BEAM release. Mitigation: prebuilt stub
  binaries, TUI as a separate install.
- Agent priors: agents produce weaker Elixir than Rust/TS. Mitigation is the
  split itself — the code most sensitive to this (terminal state, byte
  accounting, process groups) moves to Rust.
- The ~42 ms Elixir-side `ok` ack on `ask` is unexplained; profile before the
  TUI ships.
- Protocol v2 materialization: the snapshot shape will churn while the session
  model does. Keep the op set closed and versioned.
- The spikes tested one session, one client, local only. Multi-client
  control/observe under v2 and remote stubs are untested.

## 11. Provenance

Own conclusions: the decision, spike design and measurements, the mapping in §4,
slices in §8. An Oracle consult (one focused question, 2026-09-02) independently
recommended the same alternative and fallback, the Ports-not-NIFs default,
"finish PROD-1 then freeze", and proposed the 3-of-5 / 30 % reversal rule in §9;
its file-level claims were re-verified before inclusion. Its assertion that Rust
has stronger agent priors is plausible but unmeasured.
