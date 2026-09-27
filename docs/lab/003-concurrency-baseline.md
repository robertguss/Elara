# 003 — Concurrency baseline on unchanged code

- **Question:** RQ-2. How far does one VM scale under a fixed reference
  workload, on unchanged code?
- **Hypothesis (RQ-2, unchanged):** at 500 concurrent sessions, p95
  runtime-added delta latency stays under 50 ms, memory stays under 5 MB per
  session, and throughput tracks the intended delta rate. These are provisional
  budgets, not predictions.
- **Queue item:** LAB-3 · **Date:** 2026-09-26 · **Base:** `c807be3` ·
  **Measurement commit:** `97311a1`
- **Status:** the sessions curve has been measured: the timing and count sweeps
  ran on 2026-09-27. The child-thread variant and attribution are still to be
  pre-registered and run.

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
- Every turn returned `{:ok, _}` and every persisted tool result succeeded, in a
  stopped run too: entry timestamps are wall-clock and cannot place a result
  relative to the cutoff.
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
- **Commands:** the timing curve, then the count runs:

      mix elara.lab sweep concurrency --over sessions=10,50,200,500,1000 --n 3 --seed 42
      mix elara.lab sweep concurrency --over sessions=10,50,200,500,1000 --n 1 --seed 42 --set trace=counts

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

Sessions curve, measured 2026-09-27 at `97311a1`. All 15 timing repetitions and
all 5 count runs are clean: exit 0, every check passed, complete, nothing
retained, and every result line records `97311a1` with a clean tree. Each
repetition's largest session history reached 200,100–200,260 bytes. The median
session's history was far smaller at high N: 2 bytes in all three N = 1,000
repetitions.

**Table A:** timing runs, one row per repetition. Latency is in ms and memory in
MiB per session. "Mem max" is the governing peak and "Mem adj" is the
client-adjusted peak. L/M/T are the latency, memory and throughput verdicts
(h = holds, f = fails).

| N | Seed | p50 | p95 | p99 | Cohort | Ratio | Mem max | Mem adj | Turns | L/M/T |
| --: | --: | --: | --: | --: | --: | --: | --: | --: | --: | :-: |
| 10 | 42 | 3 | 5 | 7 | 219,809 | 0.990 | 20.84 | 20.77 | 960 | h/f/h |
| 10 | 43 | 3 | 6 | 9 | 219,491 | 0.989 | 20.02 | 19.93 | 954 | h/f/h |
| 10 | 44 | 3 | 5 | 7 | 219,635 | 0.989 | 21.80 | 21.72 | 961 | h/f/h |
| 50 | 42 | 2 | 6 | 13 | 1,090,023 | 0.982 | 18.76 | 18.69 | 4,758 | h/f/h |
| 50 | 43 | 2 | 8 | 31 | 1,075,223 | 0.968 | 18.46 | 18.37 | 4,660 | h/f/h |
| 50 | 44 | 2 | 54 | 811 | 1,023,406 | 0.922 | 22.30 | 22.22 | 4,510 | f/f/f |
| 200 | 42 | 873 | 3,591 | 7,501 | 2,044,229 | 0.458 | 18.56 | 18.48 | 9,140 | f/f/f |
| 200 | 43 | 856 | 3,655 | 4,697 | 1,977,913 | 0.445 | 18.45 | 18.37 | 8,928 | f/f/f |
| 200 | 44 | 847 | 3,346 | 4,202 | 1,933,088 | 0.435 | 18.82 | 18.75 | 8,744 | f/f/f |
| 500 | 42 | 513 | 2,402 | 3,042 | 2,064,250 | 0.186 | 10.21 | 10.16 | 9,385 | f/f/f |
| 500 | 43 | 638 | 2,654 | 3,388 | 2,062,546 | 0.186 | 10.90 | 10.84 | 9,306 | f/f/f |
| 500 | 44 | 1,033 | 3,687 | 5,539 | 1,897,515 | 0.171 | 11.28 | 11.23 | 8,745 | f/f/f |
| 1,000 | 42 | 973 | 3,311 | 4,397 | 2,011,700 | 0.091 | 6.02 | 5.99 | 9,220 | f/f/f |
| 1,000 | 43 | 1,012 | 3,410 | 4,297 | 1,998,528 | 0.091 | 6.16 | 6.13 | 9,192 | f/f/f |
| 1,000 | 44 | 823 | 3,957 | 6,332 | 1,856,505 | 0.084 | 5.60 | 5.58 | 8,187 | f/f/f |

**Verdicts at N = 500:**

- **Latency: fails.** p95 is 2,402, 2,654 and 3,687 ms (seeds 42–44), each in a
  complete, compliant repetition, against a bound of under 50 ms.
- **Memory: fails.** Peak per-session memory is 10.21–11.28 MiB, over 5 MiB in
  every repetition.
- **Throughput: fails.** Ratios are 0.186, 0.186 and 0.171, all under 0.95.
- **Lowest N below 0.95:** 50. It comes from one repetition (seed 44, ratio
  0.922); seeds 42 and 43 stayed at 0.982 and 0.968. Every repetition at
  N ≥ 200 is below 0.95.
- **Saturation value:** 50, from the same repetition, which is clean.
- **Per point:** latency holds only at N = 10, memory fails at every N, and
  throughput holds only at N = 10.

**Table B:** descriptive, min–max over the three repetitions (`report.tsv`).
Mailbox lengths are in messages and bash excess is in ms.

| Measure                          | 10          | 50          | 200         | 500         | 1,000       |
| -------------------------------- | ----------: | ----------: | ----------: | ----------: | ----------: |
| Session mailbox max / p99        | 2–3 / 0     | 5–117 / 1–37 | 151–191 / 118–136 | 130–155 / 82–108 | 132–161 / 93–98 |
| Connection mailbox max / p99     | 1 / 0       | 1 / 0       | 1–2 / 0     | 1–2 / 0     | 1 / 0       |
| Exec mailbox max / p99           | 0 / 0       | 0–1 / 0     | 0–1 / 0     | 0–1 / 0     | 0 / 0       |
| Bash excess p50                  | 18–22       | 17–19       | 236–242     | 391–443     | 374–483     |
| Bash excess p95                  | 26–35       | 26–94       | 2,239–3,551 | 6,161–9,287 | 3,369–9,133 |
| Bash excess p99                  | 30–44       | 49–765      | 4,715–6,306 | 7,891–>10 s | 7,296–>10 s |
| Normal schedulers                | 0.032–0.037 | 0.149–0.166 | 0.456–0.484 | 0.418–0.453 | 0.444–0.458 |
| Dirty CPU schedulers             | 0.007–0.008 | 0.035–0.038 | 0.105–0.109 | 0.095–0.108 | 0.092–0.101 |
| Dirty IO schedulers              | 0.037–0.039 | 0.194–0.209 | 0.648–0.681 | 0.687–0.724 | 0.665–0.708 |
| Memory, window mean (MiB)        | 11.37–11.39 | 11.49–11.72 | 11.78–11.96 | 5.82–5.95   | 2.97–3.16   |
| Arrivals in window (millions)    | 0.22        | 1.02–1.09   | 1.93–2.03   | 1.90–2.07   | 1.86–2.01   |
| Cumulative sessions              | 50          | 250         | 600         | 841–857     | 1,325–1,335 |
| Sessions-root files              | 200         | 1,000       | 2,340–2,390 | 3,050–3,107 | 4,498–4,550 |

Other measurements, in every repetition:

- The stub port's queue was 0 bytes at max and p99.
- Expected-but-unemitted, emitted-but-unreceived, unreceived-in-cohort and tool
  failures were all 0.
- No run stopped early; every window was 540 s.
- Latency overflow was 0, except N = 200, seed 42: 3,525 deltas arrived more
  than 10 s late, counted rather than clipped.
- "> 10 s" in Table B marks a bash-excess histogram overflow.

**Table C:** count runs (seed 42). Calls per second · calls per delivered delta.

| Function | 10 | 50 | 200 | 500 | 1,000 |
| --- | --: | --: | --: | --: | --: |
| `:file.sync/1` | 417 · 1.0240 | 2,076 · 1.0240 | 3,882 · 1.0236 | 3,937 · 1.0238 | 3,887 · 1.0239 |
| `Store.save/1` | 9.84 · 0.0242 | 49 · 0.0242 | 90.8 · 0.0239 | 92.1 · 0.0240 | 91.6 · 0.0241 |
| `Context.budget/2` | 14.7 · 0.0362 | 73.3 · 0.0362 | 135 · 0.0357 | 138 · 0.0358 | 137 · 0.0361 |
| `Handoff.lineage/1` | 9.77 · 0.0240 | 48.7 · 0.0240 | 89.9 · 0.0237 | 91.4 · 0.0238 | 91.4 · 0.0241 |
| `FlightRecorder.complete_transition/4` | 417 · 1.0240 | 2,076 · 1.0240 | 3,882 · 1.0236 | 3,937 · 1.0239 | 3,887 · 1.0239 |
| `Exec.run/2` | 1.63 · 0.0040 | 8.1 · 0.0040 | 15 · 0.0039 | 15.3 · 0.0040 | 15 · 0.0040 |

**Table D:** tracing overhead. The untraced seed-42 timing run → the seed-42
count run, both clean. Latency is in ms.

| N     | p50         | p95           | p99           | Ratio                     |
| ----: | ----------: | ------------: | ------------: | ------------------------: |
| 10    | 3 → 3       | 5 → 5         | 7 → 7         | 0.9900 → 0.9896 (−0.0004) |
| 50    | 2 → 2       | 6 → 6         | 13 → 12       | 0.9818 → 0.9860 (+0.0042) |
| 200   | 873 → 1,087 | 3,591 → 3,246 | 7,501 → 4,722 | 0.4582 → 0.4612 (+0.0030) |
| 500   | 513 → 417   | 2,402 → 2,535 | 3,042 → 3,374 | 0.1862 → 0.1870 (+0.0009) |
| 1,000 | 973 → 481   | 3,311 → 2,624 | 4,397 → 3,788 | 0.0906 → 0.0923 (+0.0017) |

**Reproduce.** Run note 003's two sweep commands, then:

    mix elara.lab report TIMING_DIR
    mix elara.lab report COUNT_DIR
    mix elara.lab compare TIMING_DIR COUNT_DIR --seed 42 --fields latency_p50_ms,latency_p95_ms,latency_p99_ms,throughput_ratio

`TIMING_DIR` and `COUNT_DIR` are the timing and count sweep directories. Here
they were
`lab/results/concurrency/20260927T101541605186Z-sweep-sessions-seed42` (timing)
and `lab/results/concurrency/20260927T125116839454Z-sweep-sessions-seed42`
(count). Each holds `repetitions.jsonl`, `summary.json`, `report.tsv` and
`points.tsv`; the count directory also holds the comparison. Both sweeps ran
under `caffeinate -ims` with `MIX_ENV` unset (dev). Host samples are in
`lab/results/concurrency/lab3-host.log`.

## Interpretation

This covers the sessions curve only.

- **RQ-2's hypothesis is refuted at N = 500 on unchanged code,** on all three
  bounds and by wide margins:
  - p95 latency is 48–74 times the budget;
  - peak memory is about twice the ceiling;
  - throughput is under a fifth of the intended rate.

  That is a finding. Fixes belong to LAB-7.
- **The knee lies between 50 and 200 sessions on this host.** The registered
  rule puts saturation at 50, but on a single repetition that overlapped heavy
  external load (see Limits). The other two N = 50 repetitions stayed above
  0.95, and every repetition at N ≥ 200 is far below.
- **Above the knee, the VM's aggregate output is roughly constant.** From
  N = 200 to 1,000, each run delivers 1.86–2.07 million arrivals and completes
  8,187–9,385 turns. Normal-scheduler utilization stays at 0.42–0.48 and
  dirty-IO utilization at 0.65–0.72.
- **Durable writes plateau with output.** The count runs show 1.024
  `:file.sync/1` calls and 1.024 recorder transitions per delivered delta, and
  both plateau near 3,900 per second from N = 200. This is consistent with a
  serialized per-delta durable path, but it does not attribute the ceiling; the
  attribution profile does that.
- **Memory is over the ceiling at every N.** It is 18.4–22.3 MiB per session
  up to N = 200 and still 5.6–6.2 MiB at N = 1,000. What holds it is also for
  attribution.
- **Tracing comparisons were mixed, and overhead was not isolated.**
  - At N ≤ 50, the count runs match the untraced run within 1 ms at every
    percentile and within 0.005 in ratio.
  - At N ≥ 200, their ratios are 0.001–0.003 above the untraced seed-42 run,
    and above all three timing repetitions.
  - Their latency percentiles differ from the untraced seed-42 run by
    −2,779 to +332 ms. Of the nine percentiles, one is above every timing
    repetition at its N, three are within the timing spread, and five are
    below it.
  - There is one count run per N, so differences of this size cannot be
    attributed to tracing. No overhead threshold was registered.
- **What this does not show:** which cost dominates, the child-thread variant,
  or anything about the BEAM as such. There is no comparison, so these are
  Elara properties under the attribution rule.

## Limits

- **Shared schedulers.** The clients run in the VM and share its schedulers. The
  claim covers attached in-VM clients, their cost included, not an external
  client or the TUI. Subtracting client memory does not remove their scheduling
  cost or shared allocation effects.
- **One laptop.** Timings are one machine's, at millisecond resolution (the
  simulator's unit).
- **Growing file population.** The sessions root grows through the run, so
  file-scanning costs (`Handoff.lineage/1`) grow with turnover as well as N.
- **Host not quiet.** The owner chose to run without quieting the laptop.
  Five-minute host samples (`lab3-host.log`) show heavy external activity during
  both sweeps:
  - Timing sweep: Spotlight's knowledge indexer at up to 99% CPU, at or above
    20% in 13 samples; `node` up to 114%; FPCKService 94%; XProtect 89%;
    CodexBar 85%; `rustc` up to 59%.
  - Count sweep: a WebKit content process at 121%; `node` up to 101%;
    Spotlight's indexer up to 99%; CodexBar 88%; `mds` 53%; OrbStack up to 32%.

  The N = 50, seed 44 repetition (12:09–12:20 UTC) overlapped `node` at 114%,
  Spotlight at 99%, XProtect at 89% and two `rustc` processes at 44.5% and
  42.1%. That repetition alone sets the saturation value, and the owner declined
  a supplementary rerun. The overlap establishes a confound, not its effect.
  The N = 500 verdicts don't depend on it, since all three repetitions fail
  every bound by wide margins. The samples can miss shorter bursts.
- **Dev build.** The runs used `MIX_ENV=dev`, the default, with the native
  stub's debug build.
