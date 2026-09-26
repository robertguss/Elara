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

Baseline at `6ac8343`:

- 539 Mix tests. 533 pass with the owner's real `HOME`; the six failures come
  from user skills leaking into the suite and pass with an empty `HOME`.
- 121 Rust tests pass.
- The build compiles with warnings denied.

**Next action:** LAB-0.

## Research agenda

Each question has a hypothesis that an experiment can refute. A result against a
hypothesis is a finding, not a failure.

### RQ-1 — Do the invariants hold under arbitrary faults?

**Hypothesis:** Elara's documented invariants hold under randomized fault
schedules:

- Accepted input is consumed at most once.
- No mutation re-executes after its callback started.
- Uncertain outcomes are reported as `indeterminate`.
- Every session file remains openable.

**Against:** any counterexample. The pure `Core.step/2` makes property testing
cheap; the shell needs fault injection.

**Known suspect:** an interrupted or timed-out _running_ mutating call is
recorded as `{:error, "interrupted"}` or `{:error, "timed out"}`, not
`indeterminate` (`lib/elara/session/core.ex:274-289`).

**Experiments:** LAB-2, LAB-4.

### RQ-2 — Where does concurrency break?

**Hypothesis:** once per-event work proportional to history is removed, one VM
on a laptop sustains at least 500 concurrent streaming sessions with simulated
providers, and throughput is bound by provider latency rather than the runtime.

**Suspected costs:**

- Whole-history JSON encoding on every streamed delta (provider visibility and
  context budget).
- A full JSONL rewrite on every append.
- A session-file scan by `Handoff.lineage` on every provider dispatch.
- Full-state hashing plus an fsync per recorder transition.
- One shared execution-stub Port per VM.

**Experiments:** LAB-5 (baseline), LAB-6 (fixes, same benchmark).

### RQ-3 — Do processes make agent lifecycles simpler?

**Hypothesis:** one general job primitive plus one correlated wake model can
replace `test_job`, the `thread_wait` special cases and uncorrelated child
reports. It should use less code than today and pass the RQ-1 fault suite.

**Evidence:** code and special cases removed, chaos results, and one real-model
run waking on the awaited completion.

**Experiment:** LAB-7.

### RQ-4 — Can recorded sessions evaluate policy changes offline?

**Hypothesis:** recorded Core facts can show where an alternative loop, wake or
handoff policy would first diverge from a recorded run, cheaply enough to vet
policy changes before any model spend.

**Limit:** replay stops at the first divergence that needs new model output, and
the recorder strips attachments and provider state.

**Experiment:** LAB-8.

### RQ-5 — Can a live session safely change its own runtime? (parked)

This covers replay-gated replacement of the session shell and agent-authored
capabilities with bounded lifetimes. It builds on PLUGIN-1/2. It is the
highest-risk question and is not queued until RQ-1 and RQ-3 have results.

## Lab method

- **One page per experiment.** Write `docs/lab/NNN-slug.md` with the question,
  hypothesis, method (scenario, provider mode, N, seeds), results with numbers,
  what changed and limits.
- **Raw data stays out of `docs/`.** It goes under `lab/results/`.
- **Seeded and repeatable.** Rerunning the documented command reproduces the
  summary. Prefer many seeded runs to a single anecdote.
- **Simulated first.** Real-model runs are opt-in, capped, and reported
  separately from simulated results.
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

| ID    | Status  | Item                                                       | Depends on   |
| ----- | ------- | ---------------------------------------------------------- | ------------ |
| LAB-0 | TODO    | Reset: hermetic suite, lab guidance and repository hygiene | Lab pivot    |
| LAB-1 | BLOCKED | Retire subsystems nothing in the product uses              | LAB-0        |
| LAB-2 | BLOCKED | RQ-1: property tests over Core invariants                  | LAB-0        |
| LAB-3 | BLOCKED | Lab bench: simulated provider, fault points, seeded runner | LAB-1        |
| LAB-4 | BLOCKED | RQ-1: chaos schedules against the session shell            | LAB-2, LAB-3 |
| LAB-5 | BLOCKED | RQ-2: concurrency baseline                                 | LAB-3        |
| LAB-6 | BLOCKED | RQ-2: remove top hot paths, rerun baseline                 | LAB-5        |
| LAB-7 | BLOCKED | RQ-3: general jobs and one correlated wake model           | LAB-4        |
| LAB-8 | BLOCKED | RQ-4: offline policy evaluation by replay                  | LAB-3        |

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

## LAB-1 — Retire subsystems nothing in the product uses

**Scope:**

- Remove the Coordinator. Only tests and the API guide use it, and Threads
  covers delegation.
- Remove the test-only effect modules (`LiteralPatch`, `OpaqueShell`,
  `TestExecutor`) and their tests; Git history keeps them.
- Move `check_evidence` and `diagnose_check` out of the built-in roster into the
  project plugin, and stop hardcoding plugin tool names in `session.ex`.

**Done when:**

- The suite is green.
- The README and API guide no longer describe removed surfaces.
- The removed line count is recorded.

## LAB-2 — RQ-1: property tests over Core invariants

**Scope:** add StreamData as a test-only dependency. Generate fact sequences:
asks, streamed deltas, provider results with tool calls, tool results, timeouts,
interrupts, stale refs and inbox changes.

**Properties:**

- The same facts produce the same state and effects.
- Stale-ref facts never change history.
- Every started turn ends exactly once.
- Every dispatched call receives exactly one result.
- The iteration budget holds.
- A running mutating call that is interrupted or times out is `indeterminate`.
  This is expected to fail today; calls not yet started may truthfully report
  `interrupted`.
- Recorded facts replay to `:match`.

**Done when:** properties run in the default suite with a fixed budget, plus a
longer opt-in run. Each counterexample is either fixed or recorded as a finding
in a lab note.

## LAB-3 — Lab bench: simulated provider, fault points, seeded runner

**Scope:**

- **`Elara.Provider.Simulated`** is seeded, with configurable time to first
  token, token rate, streamed deltas, scripted or generated tool-call plans, and
  injected errors (429, 5xx, disconnect before or after the first byte).
- **Named fault points** cover the session shell, provider and tool tasks, the
  execution stub, client connections and VM restart.
- **The runner:**
  `mix elara.lab run SCENARIO --n N --seed S [--provider simulated|real] [--max-requests R]`.
  Each run gets its own temporary home and sessions root, and simulated mode
  makes no network calls. It writes result lines under `lab/results/` and prints
  a summary: percentiles, failures and invariant violations.
- **Migrate the JOB-era scenarios** worth keeping into bench scenarios. Then
  retire the single-use live drivers in `test/support`, and protocol v1 if
  nothing else uses it.

**Done when:**

- A reference scenario produces identical summaries for the same seed.
- A capped real-model smoke run works.
- `docs/lab/README.md` documents usage.

## LAB-4 — RQ-1: chaos schedules against the session shell

**Scope:** run randomized fault schedules over multi-turn scenarios with tool
calls, queued input, child threads, test jobs and handoff. After each run,
recover from on-disk state and check that:

- Accepted input was consumed at most once.
- No mutation re-executed after its callback started.
- Uncertain outcomes are `indeterminate`.
- Every session file opens.
- Job capacity is released or explicitly held.
- No process group is orphaned.

**Done when:** at least 1,000 seeded schedules run, and the note records
violation counts with a minimized reproduction for each, plus fixes or findings.

## LAB-5 — RQ-2: concurrency baseline

**Scope:** run 10, 50, 200, 500 and 1,000 concurrent sessions (and child
threads, with the four-slot limit lifted for the experiment) against simulated
providers.

- **Measure:** delta latency (p50/p95/p99), throughput, memory, mailbox lengths,
  fsync counts, stub Port queueing and scheduler utilization.
- **Profile:** attribute cost against the RQ-2 suspects.

**Done when:** one command reproduces the curve and a ranked bottleneck list.

## LAB-6 — RQ-2: remove top hot paths, rerun baseline

**Scope:** fix the leading LAB-5 bottlenecks, then rerun LAB-5 unchanged and
publish before/after numbers. Likely fixes:

- An append-only store with an explicit fsync policy.
- Visibility and budget computed at message boundaries rather than per delta.
- An in-memory lineage index.
- Cheaper recorder fingerprints.
- Patch application in place in Rust, without cursor writes.

**Done when:** RQ-2 is supported or refuted with numbers, and the RQ-1 suites
still pass.

## LAB-7 — RQ-3: general jobs and one correlated wake model

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

- The LAB-4 chaos suite passes with jobs included.
- The note records lines and special cases removed.
- A capped real-model run wakes on its awaited completion.

## LAB-8 — RQ-4: offline policy evaluation by replay

**Scope:** `mix elara.lab replay --policy MODULE` runs over a corpus of flight
recordings (bench runs plus existing sessions). It reports each recording's
first divergence (sequence, fact, decision) and aggregates. Compare variants of
the duplicate-call guard, iteration budget, handoff trigger and wake budget.

**Done when:** at least two policy variants are evaluated over the corpus. The
note records replay time per recording and the fraction of decisions that could
be assessed.

## Baseline facts for experiment design

These facts come from the 2026-09-26 review.

- **Loop and execution defaults:**
  - 12 model iterations per turn, a 30-second tool timeout and 16 KiB of tool
    output. The stub kills the process group at the output cap.
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
