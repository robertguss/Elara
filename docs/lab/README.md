# Lab notes

One page per experiment. The research questions (RQ-n) and the queue (LAB-n)
live in [`ROADMAP.md`](../../ROADMAP.md); a note records what one experiment
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
