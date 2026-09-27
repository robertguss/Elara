# Elara roadmap

> **Canonical roadmap and status source** · **Updated:** 2026-09-26 (lab pivot)
> · **Owner:** solo development with AI collaborators

This file is the only current plan and status source for Elara. Full Results for
completed and retired work stay in Git history; the pre-pivot roadmap is
`git show 6ac8343:ROADMAP.md`.

## Direction

Elara is primarily a **BEAM harness research lab**. It asks which properties of
an agent runtime become easier, safer or cheaper when sessions, tools, jobs and
child agents are supervised BEAM processes around a pure reducer. Daily use is
secondary: build product features only when an experiment needs them.

The architecture stays as built: Elixir is the single authority, and Rust owns
two edge programs (the execution stub and the TUI) across process boundaries,
with no NIFs. See [`docs/rust-elixir-split.md`](docs/rust-elixir-split.md). The
split works; its daily-use reversal measurement is retired with SPLIT-5.

## Status at a glance

**2026-09-26 — lab pivot.** The owner chose research as the primary goal.
SPLIT-5 (daily-driver go/no-go) is canceled. The JOB experiment series is
closed.

**2026-09-26 — LAB-0 done, agenda revised.** The suite is hermetic. An
independent Codex review sharpened the hypotheses, added the isolation
question (RQ-3), turned offline policy replay into parked infrastructure, and
reordered the queue so Core properties and measurement come before code removal.

**2026-09-26 — LAB-1 done.** Core properties hold. Interrupted, timed-out or
crashed running mutations, and stub-killed `bash` commands, now fail closed as
`indeterminate`. See [`docs/lab/001-core-properties.md`](docs/lab/001-core-properties.md).

**2026-09-26 — LAB-2 done.** The lab bench runs seeded scenarios with scripted
faults and fails on broken invariants. JOB-era drivers became three lab
scenarios, and protocol v1 is retired. See
[`docs/lab/002-lab-bench.md`](docs/lab/002-lab-bench.md).

**Next action:** LAB-3.

## Research agenda

Each question has a hypothesis that an experiment can refute. A result against a
hypothesis is a finding, not a failure.

**Attribution rule.** An experiment establishes a property of Elara. Crediting
that property to the BEAM needs a comparison: a controlled variation inside
Elara (for example a shared process versus isolated ones), or a documented
baseline from another runtime. Without one, report it as an Elara property.

### RQ-1 — Do safety and progress hold under a defined fault model?

**Fault model:** abrupt exit of a session process, a provider task, a tool task,
the execution stub, a client connection, or the whole VM, at named points in
the turn lifecycle. Disk corruption, torn writes and full disks are out of
scope until a later revision names them.

**Hypothesis (safety):** under any schedule of these faults:
- Accepted input is consumed at most once.
- No mutation re-executes after its callback started.
- Uncertain outcomes are reported as `indeterminate`.
- Every session file remains openable.

**Hypothesis (progress):** within 5 seconds of the affected session being
reopened (simulated provider), every accepted input and every job slot is in
either a terminal state or a *recoverable* one:
- **Inputs:** a terminal input's turn ended, or it failed with a durable
  receipt. Recorded consumption alone is not terminal, because it happens
  before execution finishes (`lib/elara/session.ex:2313`). A recoverable input
  is queued or paused and visible through `input_status`.
- **Job slots:** a terminal slot is released. A recoverable one is held for an
  `indeterminate` job and reported as awaiting operator acknowledgement.

Recovery must also advance. Once the session is resumed and any held job is
acknowledged, every recoverable input reaches a terminal state, and none stays
queued indefinitely. Inputs run one at a time (`lib/elara/session.ex:2283`), so
this deadline scales: 5 seconds plus the recovered backlog times its per-input
simulated work. LAB-5 bounds both the backlog and the simulated work.

**Against:** any counterexample. A known one exists: an interrupted or
timed-out _running_ mutating call is recorded as `{:error, "interrupted"}` or
`{:error, "timed out"}`, not `indeterminate` (`lib/elara/session/core.ex:274-289`).

**Experiments:** LAB-1 (Core properties), LAB-5 (chaos against the shell).

### RQ-2 — How far does one VM scale under a fixed workload?

**Reference workload** (initial values; LAB-3 records them in its note before
measuring):
- **Turns:** 20 per session, each with 2 tool calls. One is `read` of a 4 KB
  file; the other runs a 200 ms command through the stub.
- **Provider:** the simulated provider has a 300 ms time to first token, then
  streams 50 deltas per second of about 20 bytes each. Each delta carries its
  *intended* emission timestamp.
- **History and context:** history grows to about 200 KB. The simulated provider
  is started with `context_limit: 1_000_000` (context accounting ignores provider
  advertisement, `lib/elara/session/context.ex:12`), so no handoff fires. Handoff
  lineages are a separate, labeled variant.
- **Persistence:** default persistence is on (store, recorder, journal).
- **Duration:** a 10-minute run on the owner's laptop, with the hardware
  recorded.

**Measures:**
- **Latency:** from a delta's intended emission time to its arrival at an
  attached protocol-v2 client. Measuring from intended rather than actual send
  time keeps the simulator's own scheduling delay inside the number.
- **Memory:** `:erlang.memory(:total)` plus the stub's resident set size, minus
  an idle-VM baseline, divided by sessions.

**Hypothesis:** at 500 concurrent sessions, p95 latency stays under 50 ms above
the provider's intended timing, and memory stays under 5 MB per session.
Throughput tracks the intended delta rate. These are provisional budgets, not
predictions.

**Against:** either ceiling is exceeded, or throughput flattens before the
intended rate.

**Suspected costs:**
- Whole-history JSON encoding on every streamed delta (provider visibility and
  context budget).
- A full JSONL rewrite on every append.
- A session-file scan by `Handoff.lineage` on every provider dispatch.
- Full-state hashing plus an fsync per recorder transition.
- One `Elara.Exec` GenServer and one stub Port shared by the whole VM.

**Experiments:** LAB-3 (baseline on unchanged code), LAB-7 (fixes, same
workload).

### RQ-3 — Does process isolation protect healthy sessions?

**Hypothesis:** while one session misbehaves, healthy sessions under the RQ-2
workload keep their bounds. The misbehaviours are:
- Flooding its subscribers.
- A stalled attached client.
- Crashing repeatedly.
- A command printing without limit.

The bounds are:
- p95 latency within 2× of the undisturbed baseline.
- Memory per healthy session within 1.5× of the baseline.
- VM memory growth caused by the misbehaving session under 256 MB.
- Cancellation completing within one second. Completion needs independent
  evidence that no process in the command's group survives, from a process-table
  check. The stub's terminal event reports exit status and cancellation cause,
  not group termination (`native/exec-stub/src/main.rs:565`). An
  `indeterminate` report is counted separately, not as completion.

**Against:** any shared component (the single exec GenServer and Port,
registries, unbounded subscriber mailboxes, synchronous fsync) lets one session
push healthy sessions past those bounds.

**Why it matters:** this tests the BEAM's claimed advantage more directly than
aggregate throughput does.

**Experiments:** LAB-4, LAB-7.

### RQ-4 — Do processes make agent lifecycles simpler?

**Hypothesis:** one general job primitive plus one correlated wake model can
replace `test_job`, the `thread_wait` special cases and uncorrelated child
reports. It must preserve this behavior:
- Durable admission before execution.
- Single delivery of completions.
- `indeterminate` on execution loss.
- Cancellation with bounded reporting.
- Capacity held across restarts.

**Measure:** net lines, counting the new infrastructure, and the number of
special cases in `session.ex`.

**Against:** a net increase in code or special cases, or any behavior on that
list lost.

**Experiment:** LAB-8.

### RQ-5 — Can a live session safely change its own runtime? (parked)

**Hypothesis:** a session can adopt a new tool or shell generation mid-session
without losing or duplicating accepted input or in-flight effects. It passes
two gates:
- **Replay gate:** replaying its recorded Core facts. This checks the reducer
  only; it never runs replacement shells or tools.
- **Migration gate:** a separate fault-injected migration test that exercises
  the replacement shell and tools across the swap.

**Against:** a swap that loses or duplicates input or effects, or a divergence
that both gates miss.

This builds on PLUGIN-1/2 and is not queued until RQ-1 and RQ-4 have results.

## Lab method

- **One page per experiment.** Write `docs/lab/NNN-slug.md` with the question,
  hypothesis, method (scenario, provider mode, N, seeds), results with numbers,
  what changed and limits.
- **Raw data stays out of `docs/`.** It goes under `lab/results/`.
- **Seeded and repeatable.** A seed reproduces the choices: fault schedules,
  simulated responses and tool plans. It does not fix concurrent interleavings,
  so invariant outcomes and timings are reported across runs, with variance.
- **Simulated first.** Real-model runs are opt-in, capped, and reported
  separately from simulated results.
- **Keep coverage when deleting.** Removing code never removes the recovery or
  fault coverage it exercised; migrate those tests first.
- **Short roadmap Results.** An item's Result here is at most five lines;
  details live in its lab note.
- **Queue discipline.** Keep at most one item `IN PROGRESS`, and exactly one
  executable (`TODO` or `IN PROGRESS`); later items stay `BLOCKED`. Update the
  queue table and the item's Result in the same commit.
- **Commit and push** each completed item before starting its successor.
- **House rules still apply:** Elixir is the single authority, Rust stays at the
  edges, and uncertain mutations fail closed. Workspace bytes can prove a
  postcondition, never causal completion.

Statuses are `TODO`, `IN PROGRESS`, `BLOCKED`, `DONE`, `CANCELED`, `INVALID` and
`DEFERRED` (implementation available; named acceptance postponed).

## Execution queue

| ID    | Status      | Item                                                        | Depends on   |
| ----- | ----------- | ----------------------------------------------------------- | ------------ |
| LAB-0 | DONE        | Reset: hermetic suite, lab guidance and repository hygiene  | Lab pivot    |
| LAB-1 | DONE        | RQ-1: property tests over Core invariants                   | LAB-0        |
| LAB-2 | DONE        | Minimal lab bench: simulated provider, fault points, runner | LAB-0        |
| LAB-3 | IN PROGRESS | RQ-2: concurrency baseline on unchanged code                | LAB-2        |
| LAB-4 | BLOCKED     | RQ-3: isolation under misbehaving sessions                  | LAB-3        |
| LAB-5 | BLOCKED     | RQ-1: chaos schedules against the session shell             | LAB-1, LAB-2 |
| LAB-6 | BLOCKED     | Selective retirement with coverage preserved                | LAB-5        |
| LAB-7 | BLOCKED     | RQ-2/RQ-3: measured fixes, same workloads rerun             | LAB-4, LAB-6 |
| LAB-8 | BLOCKED     | RQ-4: general jobs and one correlated wake model            | LAB-5        |
| LAB-9 | BLOCKED     | Scoped operator acknowledgement of uncertain child results  | LAB-1        |

## LAB-0 — Reset: hermetic suite, lab guidance and repository hygiene

**Scope:**

- **Hermetic tests.** Make `test/test_helper.exs` isolate user skill roots
  (`~/.agents/skills`, `~/.config/agents/skills`) so the suite never reads the
  developer's home.
- **Fix `mix elara.tui --diagnostics`.** The flag is missing from the Mix switch
  list, so the embedded server never starts.
- **Finish aligning docs with the lab direction.** `CLAUDE.md` and `AGENTS.md`
  were updated with the pivot. Remove the SPLIT-5 references in
  `MANUAL_TEST_CHECKLIST.md` and add an addendum to `docs/rust-elixir-split.md`
  retiring its daily-use reversal measurement.
- **Enforce the whole queue.** Make `test/elara/roadmap_test.exs` check every
  queue row's status and the single-executable rule, instead of the fixed
  PROD/SPLIT list.
- **Set up the lab.** Add `docs/lab/README.md` with the experiment-note
  template, and gitignore raw data under `lab/results/`.
- **Repository hygiene.**
  - Prune the three stale worktrees.
  - Delete merged local `codex/*` branches and `elara/child-*`.
  - The owner decides on the unmerged `codex/elara-tui-design-studies` and
    `codex/harness-harvesting-ideas`, and on remote branches.

**Done when:** the full suite passes with both the real and an empty `HOME`;
format and warnings-as-errors compile pass; branches are pruned as the owner
confirms.

**Result (2026-09-26): DONE.** Test-only `config/runtime.exs` clears the
environment and puts `TMPDIR` and state under one per-run directory before the
app starts (subprocess-proven). It also raises supervisor restart intensity,
fixing a seed-dependent whole-app crash. `--diagnostics` fixed; roadmap test
hardened. 47 merged branches deleted; two unmerged remain for the owner.

## LAB-1 — RQ-1: property tests over Core invariants

**Scope:** add StreamData as a test-only dependency. Start with the known
counterexample (an interrupted or timed-out running mutating call), then
generate fact sequences: asks, streamed deltas, provider results with tool
calls, tool results, timeouts, interrupts, stale refs and inbox changes.

**Properties:** generators are state-aware and include steering and deferred
calls.
- The same facts produce the same state and effects.
- Stale-ref facts never change history.
- On every prefix of a trace, each started turn has ended at most once.
- After a defined terminal drain (every pending provider and tool fact
  answered), each started turn has ended exactly once.
- On every prefix, each dispatched call has at most one result; after the
  terminal drain, exactly one.
- The iteration budget holds.
- A running mutating call that is interrupted or times out is `indeterminate`;
  calls not yet started may truthfully report `interrupted`.
- Recorded facts replay to `:match`.

Shell recovery is out of scope; LAB-5 covers it.

**Done when:** properties run in the default suite with a fixed budget, plus a
longer opt-in run. Each counterexample is either fixed or recorded as a finding
in `docs/lab/001-…`.

**Result (2026-09-26): DONE.** Eleven properties with measured coverage and
three boundary traces all hold. The known counterexample is fixed in `Core`, and
review-driven follow-ups carry `indeterminate` through `bash`, remote workers and
the durable ledger (schema 2). The child-integration block is now LAB-9. Suite
green. Note: [001](docs/lab/001-core-properties.md).

## LAB-2 — Minimal lab bench: simulated provider, fault points, runner

**Scope:** build only what LAB-3 to LAB-5 need.
- **`Elara.Provider.Simulated`** is seeded, with configurable time to first
  token, token rate, streamed deltas, scripted or generated tool-call plans, and
  injected errors (429, 5xx, disconnect before or after the first byte).
- **Named fault points** cover the RQ-1 fault model: session process, provider
  and tool tasks, execution stub, client connection and VM restart. Client
  connection and VM restart need an attached protocol client or a separate
  VM, so they are built with LAB-4 and LAB-5, which first use them.
- **The runner:**
  `mix elara.lab run SCENARIO --n N --seed S [--provider simulated|real] [--max-requests R]`.
  Each run gets its own temporary home and sessions root, and simulated mode
  makes no network calls. It writes result lines under `lab/results/` and
  prints a summary.
- **Migrate the JOB-era scenarios** worth keeping, then retire the single-use
  live drivers in `test/support`, and protocol v1 if nothing else uses it.

**Done when:**
- A seed reproduces the same fault schedule, simulated responses and tool plans.
- Timing summaries report run-to-run variance.
- A capped real-model smoke run works.
- `docs/lab/README.md` documents usage.

**Result (2026-09-26): DONE.** Three job scenarios pass every check in 5 of 5
seeded runs; smoke (no checks) completes 5 of 5. A seed reproduces choices and
elapsed-time spread is reported. The capped real smoke run passed. JOB-3/4/5/10
are lab scenarios; live drivers and protocol v1 are retired; review fixed three
bench flaws. Note: [002](docs/lab/002-lab-bench.md).

## LAB-3 — RQ-2: concurrency baseline on unchanged code

**Scope:** fix the reference workload's values in the note, then run it at 10,
50, 200, 500 and 1,000 concurrent sessions, and at child-thread counts with the
four-slot limit lifted for the experiment.
- **Measure:** runtime-added delta latency (p50/p95/p99), throughput, memory
  per session, mailbox lengths, fsync counts, exec GenServer and Port queueing,
  and scheduler utilization.
- **Profile:** attribute cost against the RQ-2 suspects.

**Done when:** one command reproduces the curve with variance, and the note
states whether RQ-2 holds on unchanged code and ranks the bottlenecks.

**Result: IN PROGRESS.** Note [003](docs/lab/003-concurrency-baseline.md): at
N = 500 all three RQ-2 bounds fail on unchanged code (p95 2.4–3.7 s, 10–11 MiB
per session, throughput ratio 0.17–0.19). As delegated children, K = 16 loses
the throughput bound its matched control keeps (one repetition, under host
load); children trail the control in all 12 pairs. Next: attribution.

## LAB-4 — RQ-3: isolation under misbehaving sessions

**Scope:** under the LAB-3 workload at a fixed session count, add one
misbehaving session per scenario: subscriber flood, stalled attached client,
crash loop, or unbounded command output. Measure healthy sessions against the
undisturbed baseline.

**Done when:** each scenario reports healthy p95 latency ratio, cancellation
time and memory. The note names any shared component that breaks isolation.

## LAB-5 — RQ-1: chaos schedules against the session shell

**Scope:** run seeded schedules from the RQ-1 fault model over multi-turn
scenarios with tool calls, queued input, child threads, test jobs and handoff.
After each run, recover from on-disk state and check the safety and progress
invariants, including that no process group is orphaned.
Run with the production restart limit (`max_restarts: 3`), not the test
suite's raised value, so escalation behaves as in production.

Also cover the transport faults found in LAB-1's review:
- A worker connection handler dying between unlinking and killing its job,
  which can leave the job running.
- A client disconnecting before the worker switches the socket to
  `active: :once`, which can crash the handler at an `:ok` match
  (`lib/elara/worker/server.ex:108`).
- `Protocol.recv_line/2` receiving a sustained stream of fragments, to prove it
  stops at its deadline. The current timeout test would pass without that
  check.

The chaos observer must follow handoff successors, including one that finishes
before it attaches, and treat paused inputs and stale terminal events as
outcomes, not completions. The retired `live_session_driver.exs` covered this
(in git history before LAB-2 slice E); the smoke collector does not. Read an
input's receipt only after it settles: the session broadcasts `turn_ended`
before recording a failed receipt.

**Done when:** at least 1,000 seeded schedules run, and the note records
violation counts with a minimized reproduction for each, plus fixes or
findings.

## LAB-6 — Selective retirement with coverage preserved

**Scope:**
- **Coordinator.** Removing it drops candidate judging and map/reduce
  (`lib/elara/coordinator/engine.ex:46`), which Threads lacks. The owner
  decides whether to rebuild those over Threads or drop them deliberately;
  record the decision here before removal.
- **Test-only effect modules.** Remove `LiteralPatch` and `OpaqueShell`.
  `TestExecutor` delegates to the production executor and backs durable
  input-recovery tests (`test/elara/input_queue_recovery_test.exs:26`): migrate
  those tests to the production executor, keep them, then remove it.
- **Check tools.** Move `check_evidence` and `diagnose_check` out of the
  built-in roster into the project plugin, and stop hardcoding plugin tool
  names in `session.ex`.

**Done when:**
- The suite and the LAB-5 chaos suite are green, with no recovery or fault
  test lost.
- The README and API guide match the new surface.
- The removed line count is recorded.

## LAB-7 — RQ-2/RQ-3: measured fixes, same workloads rerun

**Scope:** fix only bottlenecks that LAB-3 or LAB-4 measured. Rerun both
unchanged and publish before/after numbers. Candidate fixes:
- An append-only store with an explicit fsync policy.
- Visibility and budget computed at message boundaries.
- An in-memory lineage index.
- Cheaper recorder fingerprints.
- Execution not serialized through one GenServer.
- Bounded subscriber mailboxes.
- Patch application in place in Rust, without cursor writes.

**Done when:** RQ-2 and RQ-3 are supported or refuted with numbers, and the
RQ-1 suites still pass.

## LAB-8 — RQ-4: general jobs and one correlated wake model

**Scope:**
- **`Elara.Jobs` with profiles.** Each profile declares an argv builder,
  validator, timeout, output policy and optional fingerprint set. `mix_test`
  becomes one profile, `test_job` remains an alias, and v1 records still load.
- **No kill at the output cap.** The stub stops forwarding output but lets the
  command run to its deadline, retaining head and tail. This also removes a
  confound from real-model runs.
- **One wake model.** Job completions, child reports and `thread_wait` share one
  inbox wake model with correlation IDs, and the model can tell an awaited
  completion from an unrelated report.
- **Operator acknowledgement.** Stopped or indeterminate jobs can be
  acknowledged from the TUI or server, not only through the Elixir API.

**Done when:**
- Every behavior RQ-4 lists is preserved under the LAB-5 chaos suite with jobs
  included.
- The note records net lines, counting new infrastructure, and special cases
  removed.
- A capped real-model run wakes on its awaited completion.

## LAB-9 — Scoped operator acknowledgement of uncertain child results

**Why:** since LAB-1, routine timeouts and output-cap kills in a delegated child
record `indeterminate`, which permanently refuses integration
(`lib/elara/threads.ex:533`). Clearing the block after a later successful turn,
or ignoring kills inside the worktree, would be unsound: commands are not
confined to the worktree.

**Scope:**
- **What the acknowledgement binds to.** It is durable and records the child,
  the specific uncertain call IDs, and a digest of the reviewed worktree patch.
  Any new uncertain result or changed bytes invalidates it, and the original
  `indeterminate` results stay in history.
- **Where it is checked.** Inside the serialized workspace operation that
  integration already uses (`lib/elara/threads.ex:282`).
- **What it overrides.** Only the historical-uncertainty guard. Guards for
  active execution or pending recovery (`lib/elara/session.ex:342`) and
  cleanup's integrated-tree checks are unchanged.
- **Who can call it.** Only the TUI and server, not the model. This is workflow
  separation, not a security boundary, since `bash` is unrestricted.

**Done when:** an acknowledged child integrates exactly the reviewed patch, and
tests prove that new uncertainty or changed bytes invalidate the
acknowledgement.

## Baseline facts for experiment design

These facts come from the 2026-09-26 review.

- **Loop and execution defaults:**
  - 12 model iterations per turn, a 30-second tool timeout and 16 KiB of tool
    output. The stub kills the process group at the output cap; since LAB-1 a
    killed command reports `indeterminate`.
  - Tools run sequentially.
  - Iterations, timeout and output size are configurable per session through the
    Elixir API; the stub's kill-at-cap is not.
- **Context:**
  - The owner's 80 user skills add about 38 KB of catalog text to every request.
  - Providers other than Codex fall back to a 128K window with a conservative
    byte estimate, so handoff fires early.
- **Trust boundary:**
  - The local gateway on `127.0.0.1` has no authentication.
  - Repository plugins compile with full authority when a session starts.
  - Tools are not sandboxed.
- **Providers:**
  - The Codex subscription and Grok OAuth paths use unofficial endpoints and
    client IDs.
  - Provider errors are not retried.

## Parked

Not queued; revisit when an experiment needs them:
- Offline policy evaluation by replay. Replay already accepts an alternative
  reducer, but the handoff trigger and wake budget are decided in the session
  shell, outside recorded Core facts; move them into Core first.
- RQ-5 live self-modification.
- Event sources beyond jobs (file changes, CI, git).
- Placement over BEAM distribution versus the current TCP workers.
- Director-style loop ownership in `Core.step/2`.
- A small tool roster with an intent argument.
- Receipts around Port jobs.
- Gateway authentication (a token or Unix socket) and a trust prompt for
  repository plugins, before running long-lived servers unattended.
- Daily-driver work: a launcher or `--cwd`, grep/glob tools, provider retries,
  TUI polish and physical-terminal acceptance.

Explicitly not planned:

- A provider compatibility compiler.
- Convars.
- Embedded Python extensions.
- TLA+ models.
- A cross-language plugin ABI.
- Any Rust rewrite of the session authority.

## History

Shipped before the lab pivot. Full Results, checks and limits are in
`git show 6ac8343:ROADMAP.md`. Experiment narratives are in
[`docs/harness-experiments.md`](docs/harness-experiments.md).

| ID                   | Status   | What shipped                                                                                           | Commits                                    |
| -------------------- | -------- | ------------------------------------------------------------------------------------------------------ | ------------------------------------------ |
| ER-1–ER-3            | CANCELED | Durable-effects research; closed as a method stop                                                      | `57f6b12`                                  |
| PROD-1               | DONE     | Receipt-backed local `write` through the public path                                                   | `4d87900`, `dd8629b`                       |
| PROD-2               | CANCELED | Receipt-backed `edit`; durable effects frozen at PROD-1                                                | `79ded48`                                  |
| SPLIT-1              | DONE     | Rust execution stub; `bash` through an Erlang Port                                                     | `ff8bcb2`                                  |
| SPLIT-2              | DONE     | Protocol v2 snapshot-on-attach and sequenced patches                                                   | `ef43018`, `54ea404`                       |
| SPLIT-3              | DONE     | Streaming provider contract and content deltas                                                         | `7c99e7d`                                  |
| SPLIT-4              | DONE     | Rust TUI as a protocol v2 projection client                                                            | `80a65cd`                                  |
| PROV-1, PROV-2       | DONE     | ChatGPT/Codex subscription; reasoning visibility, model/effort controls, usage                         | `b440861`, `fb7a6a3`                       |
| TUI-1, MAC-1, TUI-2  | DONE     | Embedded server, macOS stub cleanup, assistant Markdown                                                | `131fc52`, `991f2b4`, `220c18c`            |
| TUI-3–TUI-5, TUI-7   | DEFERRED | Composer, transcript navigation, tool inspection, layouts/themes; hands-on acceptance dropped at pivot | `0e1cbda`, `de46872`, `e7c67bf`, `0c968dc` |
| TUI-8                | DEFERRED | Mockup-faithful quiet chrome; visual review dropped at pivot                                           | `b972b27`                                  |
| INPUT-1, INST-1      | DONE     | File references and images; scoped `AGENTS.md` and Agent Skills                                        | `57f930c`, `da9a690`                       |
| TUI-6, CTRL-1        | DONE     | In-TUI session lifecycle; durable input queue and steering                                             | `d5085b8`, `3219bf7`                       |
| THREAD-1, THREAD-2   | DONE     | Persistent delegated children in worktrees; durable communication                                      | `bd4fa99`, `a4f0651`                       |
| CTX-1                | DONE     | Automatic handoff to a linked successor                                                                | `e25058e`                                  |
| PLUGIN-1, PLUGIN-2   | DONE     | Live plugin discovery and reload; agent-authored plugin experiment                                     | `8728298`, `43b283a`                       |
| LOOP-1, DIAG-1       | DONE     | Repeated-call policy; captured check diagnosis                                                         | `20a8eda`, `1b24bfe`                       |
| JOB-1–JOB-12, TEST-1 | DONE     | Supervised test jobs, recovery, cancellation and specialist experiments; suite repairs                 | `c6ebf10`, `306ca87`, `6ac8343`            |
| SPLIT-5              | CANCELED | Daily-driver checkpoint and go/no-go; retired by the lab pivot                                         | —                                          |
