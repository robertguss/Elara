# Handoff

## 1. State

Observed 2026-09-27: repository `/Users/robertguss/Projects/startups/Elara`,
branch `main`. Work is reviewed and pushed through `fa8760c` to `origin/main`.
This handoff is committed on top of it. The working tree was clean before this
file. Re-check HEAD, `git status` and `origin/main` before relying on this.

## 2. Read these first

- **`ROADMAP.md`**: the sole status source. LAB-3 is still IN PROGRESS; its
  Result summarizes both the sessions curve and the child-thread variant.
- **`docs/lab/003-concurrency-baseline.md`**: LAB-3's binding pre-registration.
  - Its Runs section holds the registered "Child-thread variant" subsection, and
    a "Still to pre-register" list that now names only attribution.
  - Results, Interpretation and Limits each have a sessions-curve part and a
    "Child-thread variant" part (Tables E–H, the verdict per K, the shakedown
    addendum).
- **`docs/lab/README.md`**: the runner, `sweep`, `report`, `compare`, and the
  concurrency scenario's `topology=children` mode.
- **`CLAUDE.md` and `AGENTS.md`**: lab direction, conventions and the
  driver/oracle workflow.
- **`git log --oneline 6373e73..fa8760c`**: this chunk's six commits, each of
  which describes what it changed and verified.

## 3. Context

This chunk measured LAB-3's child-thread variant.

- **The comparison.** K = 4, 16, 64 and 256 coding children of one paused
  parent, each cycling the reference workload, against a matched top-level
  control at N = K.
- **The hypothesis.** The child path adds no bound failure; a bound is testable
  only where it holds in the control. It is refuted at K = 16 on throughput.
  Nothing is attributed yet.
- **What the variant needed.** Product plumbing (a `thread_limit` knob,
  context-limit inheritance, held starts, per-child providers) and lab plumbing
  (the children topology, and holds across the runner's root switch). Both are
  committed and tested.

Note 003's rules were registered before any measurement and still bind. Don't
change a registered value or rule after seeing numbers. A result against the
hypothesis is a finding; fixes belong to LAB-7.

## 4. Agreed chunk and acceptance

- **Objective:** LAB-3's child-thread variant:
  - pre-register it (step 1);
  - build and test its plumbing (step 2, product; step 3a, the runner hold; step
    3b, the children topology);
  - run both registered sweeps and write up the results (step 4).
- **Excluded:** attribution and profiling, LAB-3 close-out, any RQ-2 fix
  (LAB-7), real-model runs, count runs for the variant, and LAB-4 and later.
- **Stopping condition:** the variant's results committed and pushed, with LAB-3
  still IN PROGRESS, then this reviewed handoff.
- **Disposition:** `accepted`.
- **Scope changes:**
  - Step 3 was split into 3a and 3b during plan review, for reviewable diffs.
    The oracle agreed; the chunk boundary was unchanged.
  - An unregistered K = 256 shakedown was added before the registered runs
    (oracle ruling; the owner decided to proceed after seeing its outcome).
- **Workflow check:** the replacement-driver takeover worked again. The
  end-of-chunk oracle restart follows this handoff's commit, and the next driver
  should confirm that the oracle it finds is a fresh session.

## 5. Verification and review

**Step 1: the registration (`d7347e6`).** Docs only.

- Plan review took 3 rounds:
  - round 1, 3 P2s: the parent must be paused and report delivery is part of the
    measured path; turn 1 needs the load-end gate; settlement must cover Threads
    and the transport;
  - round 2, 1 P2 and 1 P3: a transport tick could cross the runner's root
    switch, which the oracle reproduced in a probe; and "pending and unconsumed"
    wording;
  - round 3: sign-off, with both addressed.
- Diff review took 1 round with no findings. The oracle byte-compared every
  registered section.

**Step 2: the plumbing (`75e6c0b`).**

- **What changed:** `Elara.Threads.limit/0` (`:elara, :thread_limit`, default
  4); `context_limit` in `child_config`; and `start_child` options
  `pause_inputs:` and `provider:` (same module only, parent's visibility
  settings kept).
- **Checks:** full suite 682 passed. Twelve mutations each turned a test red
  (driver-reported). The oracle ran the 18 thread tests.
- **Review:**
  - plan in 2 rounds: 1 P2, the offline Codex fixture; 1 P3;
  - diff in 1 round: 1 P3, a test-gated provider replacing a sleep.

  All fixed.

- **Found while building:** a managed child always starts paused through
  `canonical_options`, so a start-time pause option was redundant and was
  dropped.

**Step 3a: the runner hold (`04869c9`).**

- **What changed:** `Elara.Lab.hold/2` and release in `run_once/4` after the
  root and directory are final, on every path. `before_release` is a test seam.
  The sampler gained Threads and transport mailboxes.
- **Checks:** full suite 687 passed. Seven mutations each turned a test red
  (driver-reported). The oracle ran the runner tests, including against the real
  transport.
- **Review:** diff in 2 rounds (1 P2: test GenServers leaked; now
  test-supervised). Fixed.

**Step 3b: the children topology (`97d2166`).**

- **What changed:**
  - `--set topology=children`;
  - linked turn-1 watchers;
  - start attempts with censored starts;
  - settlement: watchers, then Threads, then sessions, then Threads and the
    transport quiescent, then the report fixed point, then hold both;
  - `Elara.Lab.with_held/3` for test teardown;
  - new checks gating `compliant`.
- **Checks:** full suite 700 passed, twice. Fourteen mutations each turned a
  test red (driver-reported). A CLI sweep, report and compare smoke ran into
  scratch.
- **Review:**
  - Plan in 5 rounds, with P2s on:
    - watcher ownership;
    - censored starts;
    - deterministic report tests;
    - late suspension;
    - teardown across the root switch;
    - a provider stall outliving settlement;
    - teardown gated on confirmed suspension.
  - Diff in 2 rounds: 1 P2, teardown now waits for the test's own tasks and
    jobs; 1 P3, the start timer starts after the provider is built.

  All fixed. The oracle repeated the forced-failure check independently.

- **Flake found by the full suite and fixed:** a child's session directory can
  begin with `_`; see section 11. It has a regression test.

**Step 4: the registered runs and write-up (`0558ff1`).**

- **Plan:** one round, signed off with 1 P3 (show the start-time population).
- **Shakedown ruling:** signed off, with 1 P3 (report the diagnosis narrowly).
- **Unregistered shakedown:**
  - K = 256, 120 s load, `97d2166`, into scratch. Exit 1: complete and
    compliant, cleanup unconfirmed.
  - Transport quiescence and the actor hold were not confirmed within the
    settlement deadlines.
  - Its record: `lab/results/concurrency/lab3-variant-prelaunch.log` and
    `lab3-variant-shakedown/`. It is not measurement data.
- **Registered sweeps:**
  - Children ran 18:21:22–20:37:11 UTC and exited 1. The control ran
    20:37:11–22:40:52 UTC and exited 0.
  - Both used the exact registered commands, `MIX_ENV` unset (dev, debug stub),
    `caffeinate -ims` and AC power.
  - All 24 slots record `97d2166` with `dirty: false`.
  - The control is 12 of 12 clean. The children are 3 of 12 clean (K = 4); nine
    were retained on `transport_quiescent`, and the three at K = 256 were also
    stopped by the watchdog (incomplete).
- **Result:** refuted at K = 16 on throughput.
  - Children seed 42 had a ratio of 0.933 in a complete, compliant repetition.
  - The control held at 0.990–0.991.
  - Children trail the control in all 12 pairs.
- **Diff review:** one round, signed off with 2 P3s, both fixed. The oracle
  independently recomputed every bound, both summaries, all five TSVs, Tables
  E–H and the host figures.
- **Roadmap test:** `mix test test/elara/roadmap_test.exs` 4 passed.
- **Evidence** under `lab/results/concurrency/`:
  - children: `20260927T182123304442Z-sweep-sessions-seed42/`, with the
    comparison TSV;
  - control: `20260927T203712247101Z-sweep-sessions-seed42/`;
  - `lab3-children-sweep.out`, `lab3-control-sweep.out`, `lab3-variant-runs.log`
    and `lab3-variant-host.log` (52 samples).

**Limits of the evidence.** Note 003's variant Limits has the detail.

- The host was not quiet, by the owner's choice.
- The one refuting repetition overlapped a burst of six `rustc` processes and
  CodexBar. The owner declined a supplementary rerun.
- The sweeps ran one after the other.
- At K = 256, children were not 256 concurrent streams: 108–112 were live on
  average.

## 6. Remaining work

LAB-3, then the ROADMAP queue in order: LAB-4 and LAB-5, then LAB-6 to LAB-9.

- **Attribution.**
  - Pre-register its details in its own step, then profile as note 003
    describes: `tprof` call_time over [480 s, 600 s) of one full run.
  - The registered rule selects N = 10, the lowest N that breaks a bound (memory
    fails at every N), and is subject to normal plan review.
  - Rank the bottlenecks, reporting CPU cost and waiting evidence separately.
    Any replacement of the selection rule must stay visible as a post-results
    deviation.
  - The open questions in section 9 cover a supplementary N = 500 profile and
    the child path.
- **Close-out.** Finish Interpretation (the bottleneck ranking) and Limits, then
  set LAB-3 DONE with a Result of at most five lines. The rest of "Done when" is
  met.

## 7. Next chunk

**Proposed:** LAB-3 attribution, and close-out if plan review agrees it fits one
chunk. It still goes through plan review, including where it stops.

- **Acceptance:**
  - attribution pre-registered in note 003 before any profile runs;
  - the registered profile run, with its CPU and waiting evidence and a
    bottleneck ranking written into note 003;
  - if close-out is in scope, LAB-3 DONE with its Result, and LAB-4 made
    executable in the queue.
- **First action:** plan the chunk and send it for plan review. Ask the owner
  the section 9 profile questions one at a time, when they would change the
  plan.

## 8. Decisions and authorizations in force

- **Carried forward:**
  - The lab pivot, with daily use secondary.
  - `ROADMAP.md` is the sole status source.
  - Commit and push each completed step.
  - Real-model runs need the owner's explicit go-ahead each time.
  - Protocol v1 is retired.
  - Driver/oracle review applies to all work, and each chunk ends with a
    reviewed handoff.
- **LAB-3 design:** note 003's rules.
  - The sessions-curve and child-variant registrations, including 5 MB read as 5
    MiB.
  - In-VM protocol-v2 clients, with their scheduler cost part of the claim.
  - One fresh VM per (value, seed), seed-major.
  - Timing runs untraced.
  - A failed bound is a measurement.
  - Registered runs use `MIX_ENV=dev` with the debug stub, for comparability.
- **Report definitions** (last chunk): a clean repetition is `Sweep.ok?/1`, and
  bounds come from `Sweep.aggregate_bounds/2`, unchanged.
  - A retained repetition still contributes its per-repetition bounds, since
    cleanup does not enter `compliant` or `complete`.
  - Cleanliness is reported separately.
- **Added this chunk:**
  - `thread_limit` defaults to 4. `start_child`'s `pause_inputs:` and
    `provider:` options are Elixir-API only; the model-facing tool passes only
    `coding` and `history`.
  - Children settlement (note 003): cleanup is confirmed only with Threads and
    the transport quiescent, every staged report settled, no child live, and
    both actors held until the root is final.
- **Owner decisions, scoped to this variant's two sweeps:**
  - they ran without quieting the host;
  - they ran unchanged after the shakedown;
  - no supplementary rerun of the refuting K = 16, seed 42 pair.
- **Carried forward:** no reruns without the owner's approval, and any approved
  rerun is reported beside the original. For future registered runs, ask again
  about host conditions.

## 9. Open questions for the user

- **An extra attribution profile at N = 500 (carried forward):** should a
  separately labelled N = 500 profile run beside the registered N = 10 one? N =
  10 is unsaturated. This blocks only that supplementary profile.
- **Attribution of the child path (new):** should attribution also profile the
  children topology? The candidates are K = 16, where the hypothesis failed, or
  K = 64, where the report backlog is large. It would need its own
  pre-registration, since note 003's attribution text covers the sessions
  curve's processes only. This blocks only that supplementary profile.
- **The retained run directories (new):** about 24.5 GiB under the children
  sweep's `tmp/`, plus the shakedown's 0.93 GiB under
  `lab/results/concurrency/lab3-variant-shakedown/tmp/`. Should they be
  archived, or released? This blocks deleting them.
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

- **Running jobs or processes:** none from Elara. Both sweeps ended, and the
  host logger exited with its wrapper. Other projects' BEAM and `caffeinate`
  processes may be running on this host; leave them alone.
- **Evidence to keep:** everything under `lab/results/` (about 25.5 GiB, which
  git does not hold), until the owner archives or releases it (section 9):
  - last chunk's sessions-curve sweeps, `.out` files and `lab3-host.log`;
  - the LAB-2 files cited by note 002;
  - `lab/results/smoke/20260926T2356*`;
  - `lab/results/concurrency-shakedown/`, which is unregistered: don't cite it;
  - this chunk's two sweep directories, including the children's nine retained
    run directories under `tmp/`;
  - the variant logs, and `lab3-variant-shakedown/`, which includes the
    shakedown's retained run directory, `tmp/0-256-seed42/` (0.93 GiB). It was
    moved there from the session scratch path recorded in its
    `repetitions.jsonl`; `lab3-variant-prelaunch.log` records the move.

- **Cleanup obligations:** none, beyond the owner's decision on the retained
  directories.
- **Unsafe to repeat:**
  - A `pgrep -f` loop whose pattern appears in its own command line.
  - Editing the working tree, or running tests, while a sweep runs.
  - Mutating the sweep CLI's validation guards without `--results` (carried
    forward: it can launch a real sweep into `lab/results/`).
  - Smoke-testing sweeps without `--results <scratch>`.

## 11. Conventions and gotchas

- **Questions:** the owner wants one question per message.
- **Mutation checks:** mutation-check every new test. After each mutation write
  and restore, set the file's mtime into the future and run
  `MIX_ENV=test mix compile --force` before trusting a green run. Make sure the
  test data can tell the mutant apart.
- **Line-number filters go stale:** re-derive them after editing a test file;
  one mutation re-run this chunk silently ran the wrong test.
- **Session directories can begin with `_`:**
  - `Store.cwd_key/1` is the cwd's basename plus a hash, and a coding child's
    basename is its random base64url worktree token.
  - So never filter the sessions root by an `_` prefix: session files are
    exactly `root/*/*.jsonl`.
  - `Concurrency.session_files/1` does this.
- **Managed children always start paused** (`Threads.canonical_options`), and
  `launch` resumes them unless `pause_inputs: true`.
- **Turn ends and input settlement:** a session broadcasts `turn_ended` before
  its `{:finish_input}` self-send. One synchronous call after the event orders
  any later call after the input settles.
- **`:sys` behavior:** `:sys.get_state` works on a suspended process. A
  `:sys.suspend` that times out can still take effect later, so record the pid
  before suspending.
- **Lab hooks** (`Elara.Lab.run(..., hook: fun)`) run in the runner process, and
  the scenario's catch-all receives drop unknown messages. Record hook effects
  in an Agent, not by messaging the test.
- **App-level actors in tests:** tests may suspend `Elara.Threads` or the
  transport. The concurrency test module's single teardown waits for the test's
  own tasks and jobs, then uses `Elara.Lab.with_held/3`. Keep new directory or
  root changes inside it.
- **The report transport at scale:** from K = 16 up, its backlog outlived every
  settlement deadline, so every children repetition there was retained.
  - K = 16 and 64 were complete, compliant measurements.
  - K = 256 was also incomplete: the drain never finished, and the watchdog
    stopped each run.
  - Assess completeness for each future run; don't assume it.
  - A retained run directory is 1.0–1.1 GiB at K = 16 and 3.1–3.9 GiB at K = 64
    and 256.
- **Sweep layout:** per-child results sit under
  `<sweep>/results/<i>-<value>-seed<S>/`; `repetitions.jsonl` and `summary.json`
  appear only when the sweep ends. `report` and `compare` take the scenario from
  the directory layout, so keep sweep directories where the sweep put them.
- **Markdown reflow:** a formatter hook reflows Markdown after editor-tool
  edits, so edit registered notes (note 003) from the shell.
- **Herdr prompts:**
  - `herdr agent prompt` refuses `--timeout` without `--wait`, and then sends
    nothing.
  - Send prompts from a file.
  - The oracle's reply follows the last `Verdict:` line of a pane read; dump a
    long read to a file and search it.
- **Shell:**
  - `tr` is aliased to `trash` and `ls` to `eza` in the owner's zsh; use
    `/bin/ls`.
  - zsh does not word-split `$VAR`; use `${=VAR}`.
  - An unquoted `====` in zsh triggers `=` expansion.
  - Never put backticks inside double-quoted shell strings.
- **Waiting on long runs:** a background Bash task notifies when it exits; the
  Monitor tool expires after 30 minutes.
- **Expected warnings:** lab tests print "lab cleanup unconfirmed; retained ..."
  or "lab scenario ... raised". `mix test` takes about 2.6 minutes of heavy CPU.
- **Concurrency scenario:**
  - Its defaults are the registered values.
  - It refuses to start while `Elara.Exec` runs a job.
  - After unconfirmed cleanup, the runner leaves the global sessions root bound,
    so don't reuse that VM.
  - Sweep children inherit `MIX_ENV`.

## 12. Skills

- **Required:** `driver` for the driver, `oracle` for the oracle.
- **Optional:** `herdr` and `mattpocock-skills:tdd`.
