# 006 — Bounded real-PTY investigation

- **Question:** Does the historical `ThreadsTest` real-PTY failure reproduce on
  the current Linux line at seed 285253?
- **Hypothesis:** At least one invocation in the fixed target/file/suite matrix
  reproduces the real-PTY failure and identifies whether its `start` or `resume`
  stage fails.
- **Queue item:** ROB-1096 · **Date:** 2026-10-02 · **Commit:**
  `a609b4a03a7d6a6bfc1a9eac409eaa877fe0cd75`

## Method

The historical traceback was not preserved. The import snapshot records one
Mac failure at `test/elara/threads_test.exs:678`, followed by three isolated
passes and a later passing suite. On Debian 12 x86_64, Elixir 1.20.3 / OTP 29,
Python 3.11.6, and Rust 1.98.1, the following matrix ran serially, once per
listed invocation. The rule was to stop before any later invocation after the
first failure; the only failure occurred in the final invocation:

    mix test test/elara/threads_test.exs:678 --seed 285253 # three invocations
    mix test test/elara/threads_test.exs --seed 285253     # one invocation
    mix test --seed 285253                                # one invocation

The target still resolves to the intended test, which drives both `start` and
`resume`. Its first invocation called the normal
`Mix.Tasks.Elara.Tui.binary!/0` source-digest path and built the TUI with
`cargo build --locked`; the recorded source digest matches the stored digest.
Exact UTC intervals, commands, outputs, exit statuses, revision, environment,
and binary provenance are in [`lab/results/rob-1096/`](../../lab/results/rob-1096/).

## Results

| Invocation | Result |
| --- | --- |
| Target 1 | 1 passed, 17 excluded; exit 0 |
| Target 2 | 1 passed, 17 excluded; exit 0 |
| Target 3 | 1 passed, 17 excluded; exit 0 |
| Threads file | 18 passed; exit 0 |
| Full suite | 829/830 passed; exit 2 |

The real-PTY test passed in all five contexts, including the full suite. The
full suite's only failure was unrelated: `Elara.Lab.SamplerTest` expected two
loopback connection-owner peers but discovery returned one. Per the registered
boundary, that failure was recorded without retry or unrelated remediation.

## Interpretation

The PTY failure was **not reproduced within the registered bounds**. No PTY
predicate failed, so neither the `start` nor `resume` stage supplies a
minimized reproduction or supports a source change. The full-suite sampler
failure does not alter the PTY result.

## Changes

No source or test behavior changed. This note and its raw logs are the bounded
investigation evidence.

## Limits and next

This Linux result cannot disprove the historical Mac failure. Seed 285253 fixes
ExUnit ordering, not operating-system behavior, scheduling, or concurrent
interleavings. The missing original traceback prevents comparison of an exact
predicate or stage. Further PTY diagnosis needs new failure evidence rather
than retries, sleeps, timeout changes, or weakened assertions.
