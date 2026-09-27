# Handoff

## 1. State

Observed 2026-09-27: repository `/Users/robertguss/Projects/startups/Elara`,
branch `main`. Work is reviewed and pushed through `8595b76` to `origin/main`.
This handoff is committed on top of it. The working tree was clean before this
file. Re-check HEAD, `git status` and `origin/main` before relying on this.

## 2. Read these first

- **`ROADMAP.md`**: the sole status source. LAB-3 is still IN PROGRESS; its
  Result summarizes the sessions curve.
- **`docs/lab/003-concurrency-baseline.md`**: LAB-3's binding pre-registration,
  plus the sessions curve's Results, Interpretation and Limits. The Runs
  section's "Still to pre-register" list covers what the child-thread variant
  and attribution need.
- **`docs/lab/README.md`**: the runner, `mix elara.lab sweep`, and the new
  `report` and `compare` commands.
- **`CLAUDE.md` and `AGENTS.md`**: lab direction, conventions and the
  driver/oracle workflow.
- **`git log --oneline -8`**: this chunk's three commits (`3a7cbfb`, `97311a1`,
  `8595b76`) describe what each changed and verified.

## 3. Context

This chunk measured LAB-3's sessions curve on unchanged code. RQ-2 is refuted
at N = 500; note 003's Results and Interpretation have the numbers, the
registered saturation value and its caveat. Nothing is attributed yet: the note
deliberately stops short of naming a bottleneck.

Note 003's rules were registered before any measurement and still bind. Don't
change a registered value or rule after seeing numbers. A result against the
hypothesis is a finding; fixes belong to LAB-7.

## 4. Agreed chunk and acceptance

- **Objective:** LAB-3's sessions curve:
  - resolve the previous handoff's clock-offset concern;
  - run the two registered sweeps;
  - write the sessions-curve Results, Interpretation and Limits into note 003.
- **Excluded:** the child-thread variant, attribution and profiling, LAB-3
  close-out, any RQ-2 fix (LAB-7), real-model runs, and LAB-4 and later.
- **Stopping condition:** the sweeps and write-up committed and pushed, then
  this reviewed handoff, with LAB-3 still IN PROGRESS.
- **Disposition:** `accepted`.
- **Scope change:** the boundary moved during plan review, without being put to
  the owner separately. The oracle required tested report and comparison tooling
  before any measurement. So a tooling step (`97311a1`) was added between the
  clock-offset step and the sweeps. That step also fixed a count-trace flaw
  found while building it.
- **Workflow check:** the replacement-driver takeover worked again this session:
  bootstrap, READY, then the takeover message closed the previous driver's pane.
  The end-of-chunk oracle restart follows this handoff's commit. The next driver
  should confirm that the oracle it finds is a fresh session.

## 5. Verification and review

- **Step 1: every persisted tool failure counts (`3a7cbfb`).**
  - Why it changed: the scenario used to map wall-clock entry timestamps to
    monotonic time with an offset read after the run. The oracle showed that
    time-offset notifications can't establish a complete offset range. So the
    scenario now counts every persisted tool failure, in stopped runs too, which
    errs toward "undetermined".
  - Full suite: 657 passed. Four mutations each turned a test red.
    Driver-reported.
  - The oracle ran the focused tests (19 passed), compile, format and
    `git diff --check`.
  - Review: plan in 2 rounds (2 P2 and 1 P3, then 1 P3 wording), diff in 1 round
    with no findings. All fixed.
- **Step 2: report and compare tooling, plus the count-trace fix (`97311a1`).**
  - `mix elara.lab report` and `mix elara.lab compare` were added, and the curve
    fields now cover every registered measurement.
  - `Elara.Lab.CallCounts.install!/2` loads a module before setting its
    call-count pattern, and raises unless exactly one function matched. Before
    this, a counted module that was not yet loaded when the window opened
    silently counted 0.
    - The driver established that flaw: inserting blank lines above the tiny
      count test made it fail.
    - The oracle reproduced it independently in an isolated probe.
  - Full suite: 676 passed. 19 mutations each turned a test red.
    Driver-reported.
  - The oracle ran 43 focused tests (report, call-count, concurrency and sweep),
    then 15 report tests after the precision fix.
  - Review: plan in 5 rounds, which also covered step 3's plan (5 P2 and 2 P3
    across them); diff in 2 rounds (1 P2: numeric differences had been
    rounded). All fixed.
- **Step 3: the sweeps and the write-up (`8595b76`).**
  - Timing sweep: 15 children, 10:15:41–12:51:07 UTC. Count sweep: 5 children,
    12:51:16–13:43:00 UTC.
  - Both were the note's exact commands, under `caffeinate -ims`, with `MIX_ENV`
    unset (dev, debug native stub), on AC power.
  - All 20 result lines record `97311a1` with `dirty: false`, and all 20 are
    clean per `Sweep.ok?/1`.
  - The oracle independently matched all 20 child results to the sweep records,
    recomputed both summaries and all five TSVs exactly, and checked Tables A–D.
    The registered sections of the note are byte-identical to before.
  - `mix test test/elara/roadmap_test.exs`: 4 passed.
  - Review: diff in 2 rounds (1 P2: the tracing headline overclaimed; 3 P3 on
    derived ranges, host-burst wording and history). All fixed.
  - Evidence under `lab/results/concurrency/`:
    - timing: `20260927T101541605186Z-sweep-sessions-seed42/`;
    - count: `20260927T125116839454Z-sweep-sessions-seed42/`;
    - sweep output: `lab3-timing-sweep.out` and `lab3-count-sweep.out`;
    - host samples: `lab3-host.log`.
- **Limits of the evidence:**
  - The host was not quiet; the owner chose to start anyway. Note 003's Limits
    lists the sampled external activity.
  - The one N = 50 repetition that sets the saturation value overlapped heavy
    external load. The owner declined a supplementary rerun.
  - The host logger's loop matched its own command line in `pgrep`, so it never
    exited. Two loggers ran through the count sweep, each sampling `uptime` and
    `ps` every 5 minutes, and both kept going until they were stopped at
    15:33:28 UTC. Their cost is unmeasured; the oracle judged that it does not
    justify a rerun. Samples after 13:43:00 UTC are outside the sweeps, and the
    log says so.

## 6. Remaining work

LAB-3, then the ROADMAP queue in order: LAB-4 and LAB-5, then LAB-6 to LAB-9.

- **The child-thread variant.**
  - Pre-register it in its own step, before any plumbing is measured. Note 003
    lists what it needs:
    - `context_limit` inheritance;
    - a provider identity and collector for each child;
    - coordinated attach and start;
    - children that cycle like top-level sessions;
    - a `thread_limit` knob in `lib/elara/threads.ex` whose default stays 4.
  - Then build the plumbing, run it and write it up.
- **Attribution.** Profile as note 003 describes: `tprof` call_time over [480 s,
  600 s) of one full run. Then rank the bottlenecks, reporting CPU cost and
  waiting evidence separately. The registered rule selects N = 10, the lowest
  N that breaks a bound, since memory fails there; this is subject to normal
  plan review. Whether to add a separately labelled N = 500 profile is an open
  question for the owner (section 9). Any replacement of the selection rule
  must stay visible as a post-results deviation.
- **Close-out.** Finish Interpretation (the bottleneck ranking) and Limits, then
  set LAB-3 DONE with a Result of at most five lines. "Done when" is otherwise
  met: the sweep command reproduces the curve with variance, and the note states
  that RQ-2 fails on unchanged code.

## 7. Next chunk

**Proposed:** the LAB-3 child-thread variant. The order matches ROADMAP's "Next:
the child-thread variant, then attribution". It still goes through plan review,
including where it stops.

- **Acceptance:**
  - the variant is pre-registered in note 003 before any measurement;
  - the plumbing is reviewed and tested, with `thread_limit` defaulting to 4 and
    covering admission, slot acquisition and the reported limit;
  - the registered run's results are in note 003, with LAB-3 still IN PROGRESS.
- **First action:** plan the chunk and send it for plan review. Plan review may
  instead prefer attribution first. In that case it profiles N = 10 as
  registered; the owner's answer on an extra N = 500 profile need not block
  that.

## 8. Decisions and authorizations in force

- **Carried forward:**
  - The lab pivot, with daily use secondary.
  - `ROADMAP.md` is the sole status source.
  - Commit and push each completed step.
  - Real-model runs need the owner's explicit go-ahead each time.
  - Protocol v1 is retired.
  - Driver/oracle review applies to all work, and each chunk ends with a
    reviewed handoff.
- **LAB-3 design:** note 003's rules, including 5 MB read as 5 MiB.
  - In-VM protocol-v2 clients, with their scheduler cost stated as part of the
    claim.
  - One fresh VM per (value, seed), seed-major.
  - Timing runs untraced; count runs separate.
  - A failed bound is a measurement.
- **Added this chunk:**
  - Every persisted tool failure counts, in stopped runs too.
  - Report definitions:
    - a clean repetition is `Sweep.ok?/1`;
    - per-point bounds come from `Sweep.aggregate_bounds/2`, unchanged, and
      absent named bounds render as undetermined;
    - "lowest N below 0.95" counts any repetition, clean or not;
    - the saturation value needs a compliant, complete repetition;
    - comparisons pair by value and seed, and subtract only when both values are
      numbers, keeping both statuses.
  - Registered runs use `MIX_ENV=dev` with the debug native stub, as measured,
    for comparability.
  - No reruns without the owner's approval; any approved rerun is reported
    beside the original.
- **Owner decisions, each scoped to this chunk's two sweeps only:**
  - They ran without quieting the host.
  - The N = 50, seed 44 repetition gets no supplementary rerun.
  - For future registered runs, ask again about host conditions.

## 9. Open questions for the user

- **An extra attribution profile at N = 500 (new):**
  - Note 003's rule selects N = 10 for attribution: the lowest N that breaks a
    bound, since memory fails at every N. N = 10 is an unsaturated system:
    latency and throughput first fail at N = 50 (one repetition) and fail in
    every repetition from N = 200.
  - Should a separately labelled N = 500 profile run beside the registered
    N = 10 one?
  - This blocks only that supplementary profile, not the registered N = 10
    profile.
- **Unmerged branches (carried forward):** what to do with
  `codex/harness-harvesting-ideas`, `codex/elara-tui-design-studies` and
  `exp/001-mission-receipt-design`; the last exists only on `origin`. This
  blocks deleting or merging them.
- **Security advisories (carried forward):** how to respond to `mint 1.9.3`'s
  advisories (one HIGH), pulled in through `req`. This blocks dependency
  upgrades.
- **LAB-6 (carried forward):** whether to rebuild the Coordinator's judging and
  map/reduce on Threads, or drop them. This blocks LAB-6.

## 10. Operational state

- **Running jobs or processes:** none. The sweeps finished, and both host
  loggers were stopped.
- **Evidence to keep:** everything under `lab/results/` (about 500 KB, which git
  does not hold), until the owner archives or releases it:
  - the LAB-2 files cited by note 002;
  - the three unused pre-slice-E smoke files `lab/results/smoke/20260926T2356*`;
  - the shakedown in `lab/results/concurrency-shakedown/`. It is
    unregistered, predates the apparatus fixes of the previous chunk and this
    one, and is not measurement data, so don't cite it or tune from it;
  - this chunk's two sweep directories, the two `.out` files and
    `lab3-host.log`.
- **Cleanup obligations:** none.
- **Unsafe to repeat:**
  - A `pgrep -f` loop whose pattern appears in its own command line.
  - Editing the working tree, or running tests, while a sweep runs.
  - Mutating the sweep CLI's validation guards without `--results` (carried
    forward: it can launch a real sweep into `lab/results/`).

## 11. Conventions and gotchas

- **Questions:** the owner wants one question per message.
- **Mutation checks:** mutation-check every new test. Make sure the test data
  can actually tell the mutant apart: this chunk's first `tool_failures` data
  let a mutant survive.
- **Stale beams:** after each mutation write and restore, set the file's mtime
  into the future and run `MIX_ENV=test mix compile --force` before trusting a
  green run.
- **Sweeps and the checkout:** sweep children compile from the checkout, and
  each result line records the dirty flag. Don't touch the tree during a sweep,
  and keep the machine quiet. `mix test` takes about 2.6 minutes of heavy CPU.
- **Waiting on long runs:** the Monitor tool expires after 30 minutes and can
  cut its last line; re-read the output file. A background Bash task notifies
  when it exits.
- **Call-count tracing:** `:trace.function/4` sets no pattern on an unloaded
  module, and interactive mode loads modules lazily. Use
  `Elara.Lab.CallCounts.install!/2`.
- **`report` and `compare`:** they take the scenario from the directory layout
  (`<root>/<scenario>/<stamp>-sweep-...`), so keep sweep directories where the
  sweep put them.
- **Markdown reflow:** a formatter hook reflows Markdown after editor-tool
  edits. It reflowed registered paragraphs of note 003, so edit registered notes
  from the shell. Shell edits are not reflowed.
- **Herdr prompts:** `herdr agent prompt` refuses `--timeout` without `--wait`,
  and then sends nothing. Send prompts from a file. The oracle's reply is after
  the last `Verdict:` line of a pane read; dump a long read to a file and search
  it.
- **Shell aliases:** `tr` is aliased to `trash` and `ls` to `eza` in the owner's
  zsh. Use `paste`, `sed` or `/bin/ls`.
- **Backticks:** never put backticks inside double-quoted shell strings.
- **Expected warnings:** lab tests print "lab cleanup unconfirmed; retained ..."
  or "lab scenario ... raised". That is expected.
- **Concurrency scenario:**
  - Its defaults are the registered values.
  - It refuses to start while `Elara.Exec` runs a job.
  - Each session broadcasts `turn_ended` before settling its receipt.
  - After unconfirmed cleanup, the runner leaves the global sessions root bound
    to that run's directory, so don't reuse that VM.
- **Children's environment:** sweep children inherit `MIX_ENV`. In the test
  environment, `config/runtime.exs` nests each child's TMPDIR under the one the
  sweep assigned.

## 12. Skills

- **Required:** `driver` for the driver, `oracle` for the oracle.
- **Optional:** `herdr` and `mattpocock-skills:tdd`.
