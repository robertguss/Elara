# 002 — Minimal lab bench

- **Question:** Infrastructure for RQ-1 to RQ-3: can one command run a seeded,
  repeatable scenario, inject named faults and report variance, without the
  network?
- **Hypothesis:** a seed reproduces a run's choices (simulated responses, tool
  plans, fault schedules). Timings and interleavings vary and are reported as a
  spread.
- **Queue item:** LAB-2 · **Date:** 2026-09-26 · **Commits:** `3265599`,
  `ba7e831`, `a1d9145`, `d8aef3e`, `e3f5ca0`, `c6b34c6`, `29a368d`, `78b9221`

## Method

The bench has four parts, documented in the [lab README](README.md):

- **`Elara.Provider.Simulated`:** a seeded simulated provider with scripted
  `rules`.
- **`Elara.Lab.Faults`:** named fault points, plus a kill aimed at one session.
- **`Elara.Lab.Jobs`:** a test-job fixture that blocks until the scenario
  releases it.
- **The runner:** `mix elara.lab run`, which fails the command on a failed check
  and keeps evidence.

Four scenarios, each run 5 times from seed 42 on the simulated provider, on a
MacBook Pro:

    mix elara.lab run SCENARIO --n 5 --seed 42

The capped real-model smoke run used the saved OpenAI Codex login:

    ELARA_PROVIDER=openai-codex mix elara.lab run smoke --provider real --max-requests 3

## Results

| Scenario          | Checks failed | Distinct digests | Elapsed ms (min/mean/max) | Notes                                 |
| ----------------- | ------------- | ---------------- | ------------------------- | ------------------------------------- |
| `smoke`           | n/a (none)    | 5 of 5           | 964 / 992.6 / 1015        | 48 turns done, 12 failed by injected errors; delta p95 2–3 ms |
| `concurrent_jobs` | 0             | 1                | 1283 / 1643.8 / 1998      | 5 of 5 sessions complete in every run |
| `session_crash`   | 0             | 1                | 489 / 495.4 / 518         | 3 turns per run                       |
| `provider_fault`  | 0             | 1                | 1193 / 1209.6 / 1219      | 5 turns per run, both fault cases     |

The unit tests show that the same seed reproduces a scenario's digest and a
different seed changes smoke's. The job scenarios' choices are scripted (a fixed
plan or rules, with no random errors), so their digest is the same for every
seed. There it shows that the same scripted path ran, not that the seed changes
anything. The real smoke run completed 1 of 1 turns in 4.4 s within 3 requests.
Its latency and digest are null by design.

## Interpretation

The hypothesis holds for choices. Run-to-run variance appears in elapsed time,
widest in `concurrent_jobs` (1.3–2.0 s).

Review of the bench found three mechanisms to fix before trusting it:

- **Rules shifted later choices.** A rule that replaced an answer skipped that
  answer's text draws, which shifted every later choice. Answer text now uses a
  per-request random state.
- **Restoring the root could strand a job.** Restoring the global sessions root
  after an unconfirmed cleanup could strand a still-running job's records. The
  root now stays bound to that run.
- **Failed checks lost evidence.** A failed check deleted its evidence; the
  directory is now kept.

**Finding (observation ordering):** a session broadcasts `turn_ended` before it
settles the input's receipt. Until then, a failed input reads `:consumed`, which
is set when the input is dequeued. This matches `docs/test-jobs.md` and is not a
runtime defect. An observer must wait for the settled receipt, and LAB-5's scope
now says so.

## Changes

- **Scenarios:** JOB-3/4, JOB-5 and JOB-10 became the lab scenarios
  `provider_fault`, `session_crash` and `concurrent_jobs`.
- **Retirements:** the single-use live drivers and `live_session_driver.exs` are
  gone. They remain available at `d8aef3e`.
- **Protocol:** session protocol v1 (cursor replay) is retired, and only v2 is
  accepted.

## Limits and next

- **Timings are one machine's.** The elapsed times are wall-clock numbers from
  one laptop, not a baseline.
- **Process-group cleanup isn't checked.** The job scenarios check each
  fixture's recorded test pid, not whole process groups. LAB-5 owns the orphan
  check.
- **Some faults don't exist yet.** Client-connection and VM-restart faults, and
  a handoff-aware observer, arrive with LAB-4 and LAB-5.
- **Real mode is minimal.** Only `smoke` supports it.

LAB-3 uses this bench for the concurrency baseline.
