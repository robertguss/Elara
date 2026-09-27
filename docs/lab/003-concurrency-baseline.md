# 003 — Concurrency baseline on unchanged code

- **Question:** RQ-2. How far does one VM scale under a fixed reference
  workload, on unchanged code?
- **Hypothesis (RQ-2, unchanged):** at 500 concurrent sessions, p95
  runtime-added delta latency stays under 50 ms, memory stays under 5 MB per
  session, and throughput tracks the intended delta rate. These are provisional
  budgets, not predictions.
- **Queue item:** LAB-3 · **Date:** 2026-09-26 · **Base:** `c807be3` ·
  **Measurement commit:** pending
- **Status:** pre-registered; no measurement has run. The harness and sweep
  command arrive in later commits, and the results replace "pending" below.

## Reference workload

RQ-2's initial values don't fit together. Twenty turns with a 4 KB read and a
short answer neither reach 200 KB of history nor last 10 minutes; they take
about 2 minutes. So answers are longer and each simulated user cycles through
sessions. This is a **cycling** workload whose history grows toward ~200 KB per
session, not sustained operation at 200 KB. ROADMAP.md keeps the initial values.

| Value                  | RQ-2 initial                | Fixed for LAB-3                                                                                                                                |
| ---------------------- | --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| Turns per session      | 20                          | 20; then the user stops that session and opens a fresh one, until the load ends                                                                |
| Tool calls per turn    | 2: 4 KB read, 200 ms cmd    | `read` of a 4,096-byte fixture, then `bash` `sleep 0.2` through the stub                                                                       |
| Time to first token    | 300 ms                      | 300 ms on every provider request, tool-call requests included                                                                                  |
| Deltas                 | 50/s, ~20 B                 | 50/s, 20 B                                                                                                                                     |
| Answer length          | unstated                    | 250 deltas (5,000 B, ~5 s), so 20 turns reach ~200 KB of JSON history; the end-of-session size is measured                                     |
| Think time             | unstated                    | 0: closed loop, each turn is sent when the previous one ends                                                                                   |
| Concurrency N          | 10, 50, 200, 500, 1,000     | N simulated users, so N live sessions                                                                                                          |
| Start and duration     | 10 minutes                  | `t = 0` when load starts; users start at seeded offsets drawn uniformly from [0, 30 s); no turn starts after 600 s; in-flight turns then drain |
| Measurement window     | unstated                    | [60 s, 600 s)                                                                                                                                  |
| Injected errors        | unstated                    | none                                                                                                                                           |
| Context                | limit 1,000,000, no handoff | unchanged; a check asserts no handoff fired                                                                                                    |
| Persistence            | default on                  | unchanged (store, recorder, journal); completed sessions' records stay until the repetition's cleanup                                          |
| Tools, plugins, skills | unstated                    | `read` and `bash` only, `plugins: []`, an empty isolated skills home                                                                           |
| Client                 | attached protocol v2        | one TCP v2 client per session in the same VM, via an embedded `Elara.Server` on 127.0.0.1, in observe mode, with the fixed extensions below    |
| Driving                | unstated                    | turns are submitted with `Elara.ask/2` in the VM; each session's first turn waits for its client's attach acknowledgement                      |

Clients negotiate exactly these extensions, frozen from the TUI's set on this
date: `provider_visibility_v1`, `input_attachments_v1`, `input_queue_v1`,
`thread_communication_v1` and `plugin_reload_v1`.

The ideal turn cycle, with zero runtime overhead, is 3 × 300 ms (time to first
token) + 200 ms (bash) + 249 × 20 ms (stream) = 6.08 s. That is
`r_ideal = 250 / 6.08 ≈ 41.12` deltas per second per user.

## Metrics

- **Latency** (runtime-added): a delta's arrival at its client (monotonic ms,
  when the client process receives the line with its `append_content_delta` op)
  minus its intended emission time. The simulator stamps each delta with its
  request and index and records each request's start in a ledger, so both
  times are the VM's monotonic clock. Reported as p50, p95 and p99 from
  merged per-client histograms with 1 ms buckets through 10 s; overflow is
  counted, never clipped.
- **Throughput:** client arrivals during [60 s, 600 s) ÷ (540 s × N ×
  `r_ideal`). Intended times are anchored at request start, so in a closed loop
  provider-side lag lowers throughput rather than latency.
- **Memory per session:** (`:erlang.memory(:total)` + stub RSS − idle baseline)
  ÷ N, sampled every second. The idle baseline is the mean of 10 one-second
  samples after the app, embedded server and sampler start, before any session.
  The in-VM clients' memory counts in the governing figure. A client-adjusted
  figure and the window mean are descriptive.
- **Queues:** each second, the mailbox length of every session process, server
  connection process and `Elara.Exec`, and the stub Port's
  `:erlang.port_info(port, :queue_size)`, the bytes queued in the driver toward
  the stub and nothing more. Each is reported as the maximum and p99 per process
  class.
- **Bash excess latency:** client-observed `bash` duration minus 200 ms. This is
  end-to-end, not Exec queueing.
- **Scheduler utilization:** `:erlang.statistics(:scheduler_wall_time_all)` over
  the window, with normal, dirty CPU and dirty IO schedulers reported
  separately.
- **Counts,** from separate count runs only: calls to `:file.sync/1` and to the
  suspects `Store.save/1`, `Context.budget/2`, `Handoff.lineage/1`,
  `FlightRecorder.complete_transition/4` and `Elara.Exec.run/2`. Each is
  reported per second and per delivered delta.
- **Turnover:** live N, cumulative sessions opened, and the sessions root's file
  count at the end.

## Accounting and checks

Deltas are accounted as expected → emitted → received:

- **Expected:** the ledger records each request's start time. An answer
  request expects deltas at `start + 300 + round(i × 20)` ms for i in 0..249,
  from the fixed profile and independent of emission. The **latency cohort** is
  the expected deltas whose intended time lies in [60 s, 600 s).
- **Emitted:** the ledger's per-request emitted count and completion state. A
  completed answer with other than 250 deltas is non-compliant; an interrupted
  one is censored.
- **Received:** client arrivals.

A repetition's checks fail the run and keep its evidence directory:

- Every client's attach was acknowledged before its session's first turn.
- Every turn returned `{:ok, _}` and every tool call succeeded.
- Every completed answer had exactly 250 received deltas, and its persisted
  message is exactly 5,000 bytes (checked from the transcript after the run).
- Per session, expected = emitted = received once drained.
- No handoff fired, the guard didn't trip, and the drain completed.

**Drain:** in-flight turns get at most 120 s after the load ends, and a watchdog
stops the drain after 30 s with no delta or turn event on any client. **Guard:**
a repetition stops early if VM memory exceeds 32 GB, a delta is 60 s late, or a
session mailbox exceeds 100,000 messages. After a guard stop or a drain timeout,
the result reports expected-but-unemitted and emitted-but-unreceived deltas
separately.

## Verdict rules

Every repetition's values are reported per point.

- **Latency** is judged at N = 500. Unreceived and out-of-range deltas count as
  +∞ in the nearest-rank percentiles. The bound holds only if p95 ≤ 49 ms in all
  three repetitions. A **proven failure** is a received delta at ≥ 50 ms, or an
  unreceived one whose run stopped ≥ 50 ms after its intended time.
- **Memory** is judged at N = 500. LAB-3 reads RQ-2's "5 MB" as 5 MiB (5,242,880
  bytes). The bound holds only if every one-second sample is under that per
  session, in all three repetitions. One sample at or above it establishes
  failure.
- **Throughput** tracks the intended rate at N if the ratio is ≥ 0.95 in all
  three repetitions. It is judged at N = 500, and the curve reports the lowest N
  where any repetition falls below 0.95.
- **Incomplete repetitions.** A repetition that tripped the guard or failed to
  drain stays marked incomplete. It establishes a failed bound only by that
  bound's own evidence: a memory sample at or above the ceiling, or, for
  latency, a known complete cohort size C and B proven failures with
  `20 × B > C`. An early stop before 600 s leaves C unknown, so latency is
  undetermined there. A bound neither established as failed nor holding in all
  three repetitions is **undetermined**, never "holds".

## Runs

- **Timing runs:** 3 repetitions per N, seeds 42–44. Each (N, seed) runs in a
  fresh OS process with its own idle baseline. Timing runs are untraced.
- **Count runs:** seed 42, one per N, the same workload with call-count tracing.
  Their latency and throughput are compared with the untraced seed-42 run, as
  the tracing-overhead check.
- **Command:** arrives with the sweep step.
- **Host:** Apple M3 Max, 14 cores (14 schedulers, 10 dirty IO), 96 GB, macOS
  (Darwin 25.6), OTP 29.1, Elixir 1.20.4. Every result line records its host,
  versions, commit and dirty-tree flag.

**Still to pre-register,** each in its own step before its measurement:

- **The child-thread variant** (K = 4, 16, 64, 256 children of one parent) needs
  plumbing first:
  - Children don't inherit the `context_limit` override (`Elara.child_config/1`
    and the Threads start options omit it).
  - Each child needs its own provider identity and collector.
  - Creation launches the assignment before a client can attach, so attach and
    start need coordinating. This also decides whether the assignment is turn 1.
  - Children need to cycle like top-level sessions.
  - A `thread_limit` knob (default 4) must cover admission, slot acquisition and
    the reported limit.
- **Attribution** runs at the lowest N that breaks a bound (500 if none does).
  It profiles one full 600 s run over [480 s, 600 s) with `tprof` call_time,
  scoped explicitly to the existing sessions, their tasks, server connections
  and `Elara.Exec`. CPU cost and waiting evidence (dirty IO, fsync counts,
  queues, latency) are reported separately. Unit cost × call rate figures are
  labeled estimates, at the history and directory sizes observed in the run.

## Results

Pending.

## Limits

- **Shared schedulers.** The clients run in the VM and share its schedulers. The
  claim covers attached in-VM clients, their cost included, not an external
  client or the TUI. Subtracting client memory does not remove their scheduling
  cost or shared allocation effects.
- **One laptop.** Timings are one machine's, at millisecond resolution (the
  simulator's unit).
- **Growing file population.** The sessions root grows through the run, so
  file-scanning costs (`Handoff.lineage/1`) grow with turnover as well as N.
