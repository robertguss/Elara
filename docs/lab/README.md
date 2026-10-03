# Lab notes

One page per experiment. The research questions (RQ-n) and the queue (LAB-n)
live in [Elara in Linear](https://linear.app/robert-guss/project/elara-7ee4b27c1215);
a note records the versioned registration and what one experiment
found. Experiments before the 2026-09-26 lab pivot are in
[`harness-experiments.md`](../harness-experiments.md).

## Conventions

- Name notes `NNN-slug.md` with a zero-padded sequence number, for example
  `001-core-properties.md`. Numbers are never reused.
- State the hypothesis before running anything. A result against it is a
  finding; do not tune the experiment until it passes.
- Prefer many seeded runs against simulated or scripted providers. Real-model
  runs are opt-in, capped, and reported separately.
- Raw results go under `lab/results/` (gitignored). A note quotes the summary
  numbers and the exact command that reproduces them.
- Keep a note to about one page. Link the commits it depends on instead of
  pasting code.

## Template

```markdown
# NNN — Title

- **Question:** RQ-n. What this experiment asks, in one sentence.
- **Hypothesis:** A claim the result could refute.
- **Queue item:** LAB-n · **Date:** YYYY-MM-DD · **Commit:** `abc1234`

## Method

Scenario, provider mode (scripted / simulated / real), N, seeds, fault schedule,
machine. The command that reproduces the summary:

    mix elara.lab run SCENARIO --n N --seed S

## Results

Numbers first: a small table or a few lines. Note invariant violations and
minimized reproductions.

## Interpretation

Does the result support or refute the hypothesis? What it does not show.

## Changes

Fixes or features the experiment produced, with commits.

## Limits and next

Confounds, unmeasured effects, and the follow-up this suggests.
```

## Running experiments

    mix elara.lab run SCENARIO [--n N] [--seed S] [--set KEY=VALUE ...] [--results DIR]

Repetition `r` uses seed `S + r` in its own temporary sessions root and skills
home, so runs never touch `~/.elara`. Each repetition appends one JSON line to
`lab/results/SCENARIO/` (gitignored), and a summary prints the spread across
repetitions. For example:

    mix elara.lab run smoke --n 3 --seed 42 --set sessions=8

A scenario implements `Elara.Lab.run/1` (see `Elara.Lab.Scenarios.Smoke`) and
is registered in `Elara.Lab`. Scenarios drive sessions through
`Elara.Provider.Simulated`, which is seeded per session. Its collector
messages report each choice and each delta's intended emission time.

**What a seed fixes, and what it doesn't.** A seed fixes the choices: the
simulated responses, tool plans, injected errors, and fault schedules. A
scenario reports these as a `choices_digest`, and rerunning the same seed
reproduces that digest. A seed does not fix concurrent interleavings or
timings, so report those as a spread across repetitions, not as exact values.

**Sweeps.** A curve runs each value and seed in its own fresh VM:

    mix elara.lab sweep SCENARIO --over KEY=V1,V2,... [--n N] [--seed S] [--set KEY=VALUE ...]

Repetition `r` runs every value at seed `S + r` before the next repetition
starts, so each value's repetitions spread over the whole sweep. Each child gets
its own TMPDIR, log and results directory under
`lab/results/SCENARIO/<stamp>-sweep-KEY-seed<S>/`, next to `repetitions.jsonl`
(every child's result line, tagged with its value, seed, order, times and exit
status) and `summary.json` (per-value spreads, per-bound aggregation and the
saturation value). A bound holds at a value only if every expected repetition
holds, fails if any repetition establishes a failure, and is otherwise
undetermined. The sweep runs every child, then fails if any exited non-zero,
left no valid result, failed a check, was retained or is incomplete.

**Reports.** `mix elara.lab report DIR` writes `report.tsv` (one row per
repetition: status, bounds and every curve field) and `points.tsv` (one row per
value; cleanliness is counted separately from the bounds) into a sweep
directory. `mix elara.lab compare BASE_DIR OTHER_DIR [--seed S] [--fields ...]`
pairs two sweeps by value and seed and writes both statuses, both values, and
their difference where both are numbers; otherwise it names why not.

**Scenarios.**

| Scenario          | What it exercises                                                                    |
| ----------------- | ------------------------------------------------------------------------------------ |
| `smoke`           | Concurrent sessions with tool rounds and injected errors; delta latency              |
| `concurrent_jobs` | Four test-job slots, rejection, cancellation and refill, one completion each (JOB-10) |
| `session_crash`   | An idle owner killed while its job runs; offline completion, delivery on reopen (JOB-5) |
| `provider_fault`  | One scripted `bad_response` before or during interpretation; a second session keeps progressing (JOB-3/4) |
| `concurrency`     | RQ-2 reference workload: closed-loop users cycling sessions, each observed by a protocol-v2 client; `topology=children` makes them delegated children of one paused parent ([003](003-concurrency-baseline.md)) |
| `session_recovery` | LAB-5 bounded pilot: one faulted input and two queued inputs, provider-task or direct-marker death ([005](005-shell-chaos.md)) |

The job scenarios use `Elara.Lab.Jobs`, a fixture whose test blocks until the
scenario releases it, so a fault lands while a job provably runs. They run on
the simulated provider only.

`concurrency` defaults to note 003's pre-registered values (10 users, 600 s of
load); `--set` overrides any of them, for example
`--set sessions=500 --set trace=counts`. Its simulator stamps each delta with
its request and index and writes a request ledger, so a client joins arrivals
to intended times exactly. Each result line carries latency, throughput,
memory, queue, scheduler and (with `trace=counts`) call-count measurements,
the host, and `bounds`: whether each RQ-2 bound holds, fails or is
undetermined for that repetition. It also carries diagnostics-only `user_failures`
(bounded normalized user exit labels; truncation can merge different reasons)
and `timers` (timer arm, deadline and handling-delay snapshots), and samples the
coordinator mailbox under `queues.coordinator`; these fields recover failure
labels and localize delay, but carry no verdict, change no check or bound, and a
queue-length snapshot cannot prove earlier backlog or guarantee a root cause. It refuses to start while `Elara.Exec` runs
a job. Its cleanup is confirmed only when every user, session, task and client
it started has ended, no execution job is pending, and the stub's epoch is
unchanged; until its provider tasks end, it keeps their ledger.

With `--set topology=children`, each user's session is a coding child of one
paused parent (`thread_limit` is lifted to `sessions` for the run), and its
assignment is turn 1. Results then carry `children` (start attempts, censored
starts and start times), `reports` (completion reports staged, accepted,
delivered and pending) and `parent` (inbox entries and file size). Its cleanup
also requires `Elara.Threads` and the report transport to be quiescent, every
staged report settled, no child left running, and both actors held until the
runner's root and directory are final.

With `--set trace=profile` (topology `sessions` only), a run profiles the last
`profile_window_ms` of its load (120 s by default, so [480 s, 600 s) at the
registered duration) as note 003's attribution registers:
- **At the window's start:** a memory census of the named classes, then
  `Elara.Lab.Profile` activation.
- **At load end:** the freeze, a second census of what the profile traces, then
  collection in a collector beside the drain. Collection is due within
  `profile_collect_ms` (300 s) of its start.

The result's `profile` holds:
- the window's timestamps, its validity, its coverage;
- own time per class and per function;
- both memory censuses.

The profile is invalid, reported but not ranked, when:
- its window rules fail;
- collection is late or failed;
- any run check fails;
- the run is incomplete.

A profile run carries no verdict: its `bounds` is empty, and `report` shows
`no_verdict`.

On a profile sweep, `report` also writes five tables:
- `profile-windows.tsv`: timestamps, overlap, own-time totals, coverage and
  collection;
- `profile-classes.tsv`: per class, its kind, pids, calls, own time and shares;
- `profile-functions.tsv` and `profile-modules.tsv`: ranked classes' own time
  with ranks, shares, and an approximate rate over the interior (the envelope
  beside it). Native entries, and modules that include any (`native_us`), may
  include blocking time;
- `profile-memory.tsv`: both censuses, per class and per ETS table, plus
  binaries and VM memory categories.

Every row starts with its profile's validity, reasons and four latenesses. An
unranked profile keeps its rows with null ranks.

For the waiting evidence and the traced/untraced pair, compare the registered
timing sweep with the profile sweep. The profile side is traced:

    mix elara.lab compare TIMING_DIR PROFILE_DIR --seed 42 --fields latency_p50_ms,latency_p95_ms,latency_p99_ms,throughput_ratio,memory_max_per_session,memory_mean_per_session,session_mailbox_max,session_mailbox_p99,connection_mailbox_max,connection_mailbox_p99,exec_mailbox_max,exec_mailbox_p99,scheduler_normal,scheduler_dirty_cpu,scheduler_dirty_io,bash_excess_p50_ms,bash_excess_p95_ms,bash_excess_p99_ms

`:file.sync/1` calls per second come from the count sweep's `report.tsv`.

**Checks and cleanup.** A scenario reports invariants as
`checks: %{name => boolean}`. The summary counts failed checks, and the task
exits non-zero when any fails. A repetition with a failed check keeps its
directory (sessions, transcripts, job records) as `evidence_dir`. A scenario
settles its own jobs and sessions; if it cannot confirm that
(`cleanup_confirmed: false`) or it raises, the runner keeps the directory as
`retained_dir`, runs no more repetitions, and leaves the global sessions root
bound to it so unsettled work still finds its records. Don't reuse that VM.
A scenario can `Elara.Lab.hold/2` a shared actor, which the runner resumes only
once the root and directory are final; `Elara.Lab.with_held/3` gives test
teardown the same protection.
The job scenarios log simulated choices through `Elara.Lab.choice_log/0`, so
they report a `choices_digest` too.

**Scripting and faults.** A simulated profile's `rules` script specific requests
(`{predicate_on_messages, response}`, first match wins). Every request takes
one draw from the choice stream and answer text has its own per-request seed,
so a matched rule does not shift later choices or text. `Elara.Lab.Faults` kills a target at a named
point (`:provider_started`, `:provider_streaming`, `:tool_running`), or a named
session from outside with `inject({:session, id})`. Client-connection and
VM-restart faults arrive with LAB-4 and LAB-5.

**Real mode.** `--provider real --max-requests R` runs a scenario against the
configured provider (`ELARA_PROVIDER`, else the saved login) and spends real
quota. The cap is static: sessions × turns × per-turn iterations ≤ R. Only
`smoke` supports it; latency percentiles and choice digests are null there,
since they come from the simulator.

    ELARA_PROVIDER=openai-codex mix elara.lab run smoke --provider real --max-requests 3
