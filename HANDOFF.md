# Handoff

## 1. State

Observed 2026-09-27: repository `/Users/robertguss/Projects/startups/Elara`,
branch `main`. Work is reviewed through `301434b` and pushed through `301434b`
to `origin/main`. This handoff is committed on top of that commit. The working
tree was clean before this file. Re-check HEAD, `git status` and `origin/main`
before relying on this.

## 2. Read these first

- **`ROADMAP.md`**: the sole status source. LAB-3 is IN PROGRESS; its Result
  line points at note 003.
- **`docs/lab/003-concurrency-baseline.md`**: LAB-3's pre-registration, and it
  binds. It fixes the reference workload, metric definitions, the expected →
  emitted → received accounting, checks, drain and guard, and verdict rules. It
  also fixes the run design (timing runs, count runs, the two exact sweep
  commands). It lists what the child-thread variant and attribution still need
  pre-registered.
- **`docs/lab/README.md`**: the runner, `mix elara.lab sweep`, and the
  `concurrency` scenario.
- **`CLAUDE.md` and `AGENTS.md`**: lab direction, conventions, the driver/oracle
  workflow.
- **`git log --oneline -8`**: the three LAB-3 commits (`521f013`, `724f904`,
  `301434b`) describe what each built and verified.

## 3. Context

Elara is primarily a BEAM harness research lab, and work follows the ROADMAP
queue. The previous handoff proposed LAB-3 to DONE as this session's chunk. In
plan review the oracle found that too large for one session, because the
registered runs alone take hours. The chunk was cut to the measurement
apparatus.

Note 003 was committed before any measurement so its rules cannot be tuned to
the data. Don't change a registered value or rule after seeing numbers. A result
against the hypothesis is a finding.

The harness went through many review rounds. Its design choices each close a
failure the oracle established by source inspection, targeted scratch
reproductions or design counterexamples; the commit messages summarize them:

- **Stamped deltas and a request ledger** replace message-ordering assumptions.
- **Identity-based cleanup** also requires Exec to be settled.
- **Write-once cutoff** for guard and drain stops.
- **Phased sampling**, so governing statistics come from the window only.
- **One fresh VM per (value, seed)** in a sweep.

## 4. Agreed chunk and acceptance

- **Objective:** LAB-3, steps 1 to 3:
  - pre-register the workload and rules (note 003);
  - build the `concurrency` scenario and its measurement parts;
  - build `mix elara.lab sweep`.
- **Excluded:** the registered sweeps, the child-thread variant, profiling and
  attribution, the results and close-out, and any fix to an RQ-2 suspect (LAB-7
  owns fixes). Also real-model runs and LAB-4 and later.
- **Stopping condition:** step 3 committed and pushed, then this reviewed
  handoff, with LAB-3 still IN PROGRESS.
- **Disposition:** `accepted`.
- **Scope change:** narrowed from "LAB-3 to DONE" to steps 1 to 3, on the
  oracle's plan-review finding. It was agreed within the review workflow; the
  owner was not asked separately.
- **Workflow check carried from the previous handoff:** its live Herdr restart
  and takeover were unproven. This session exercised the replacement-driver
  part: this driver received the bootstrap prompt, replied READY, and on the
  takeover message closed the previous driver's pane (driver-reported). Whether
  the oracle was restarted fresh before this session is not known to this
  driver, so the oracle restart remains unproven.

## 5. Verification and review

- **Step 1, pre-registration (`521f013`).**
  - `mix test test/elara/roadmap_test.exs`: 4 passed, and the format check
    passed.
  - The oracle rechecked both.
  - Review: plan in 3 rounds (10 P2 findings), diff in 2 rounds (2 P2, 1 P3).
    All fixed.
- **Step 2, harness (`724f904`).**
  - Full suite: 646 passed, after a forced test-env recompile, on the tree
    committed as `724f904`. Driver-reported.
  - 33 mutation checks, each applied alone with forced recompiles, each turned a
    targeted test red. Driver-reported; the commit message records the count but
    no log was kept.
  - The oracle ran the focused lab tests (65, then 78 passed) and the
    compile/format checks itself. It established its diff findings by source
    inspection and targeted scratch reproductions.
  - Review: plan in 5 rounds (13 P2, 1 P3), diff in 2 rounds (9 P2 plus 2
    nonblocking). All fixed.
- **Shakedown (not data).**
  - Command:
    `mix elara.lab run concurrency --seed 42 --set duration_ms=180000 --results lab/results/concurrency-shakedown`.
    N = 10 at registered timings.
  - It ran on the step 2 working tree before step 2's diff-review fixes, so on
    no commit.
  - Every check passed and cleanup was confirmed. 20 sessions, 275 turns;
    expected = emitted = received = 68,750. History reached 200,100 bytes at
    session end.
  - Evidence:
    `lab/results/concurrency-shakedown/concurrency/20260927T031140661891Z-seed42.jsonl`.
    The oracle inspected the file.
  - Limits: it predates the fixes, is one short run, and is not a registered
    result. Don't cite or tune from its numbers.
- **Step 3, sweep (`301434b`).**
  - Full suite: 657 passed. Driver-reported.
  - 16 sweep mutations each turned a targeted test red, including dropping
    TMPDIR from the real child runner. Driver-reported.
  - The suite includes a real two-child CLI sweep (`smoke`). It asserts distinct
    child OS pids and each child's own tmp and run directories under its
    assigned TMPDIR.
  - The oracle ran the focused tests (21 passed) and compile/format checks, and
    established its findings by source inspection and targeted scratch
    reproductions.
  - Review: plan in 2 rounds (3 P2), diff in 3 rounds (3 P2, 1 P3). All fixed.

## 6. Remaining work

LAB-3's remainder, then the queue in `ROADMAP.md` order (LAB-4 and LAB-5, then
LAB-6 to LAB-9):

- **Registered sweeps.** Run the timing sweep and the count sweep, exactly as
  note 003's Runs section gives them.
- **Tracing overhead.** Compare each seed-42 count run with the untraced seed-42
  timing run for latency and throughput, and report it. The sweep commands do
  not do this comparison.
- **Child-thread variant.** Pre-register it first, in its own step: note 003
  lists the plumbing it needs, including a `thread_limit` knob in
  `lib/elara/threads.ex`, whose default must stay 4. Then run it.
- **Attribution.** Profile as note 003 describes, then rank the bottlenecks with
  CPU cost and waiting evidence reported separately.
- **Clock offset (unresolved).** The VM runs in `multi_time_warp` mode, not
  no time warp. The scenario maps each persisted tool result's wall-clock
  timestamp to monotonic time with the offset read after the run, so an offset
  change during a run could move a tool failure across the cutoff. This only
  affects `tools_ok` in censored runs. Resolve it in the next chunk's plan by
  recording tool results' monotonic event times or by establishing that the
  offset stayed stable; recording the offset at the cutoff alone cannot
  reconstruct earlier timestamps.
- **Close-out.** Write note 003's Results, Interpretation and Limits. Record
  whether RQ-2 holds at N = 500 under the verdict rules, and the saturation
  value. Set LAB-3 DONE with a Result of at most five lines.

## 7. Next chunk

**Proposed:** LAB-3 measurement and close-out. It still goes through plan
review, including where it stops.

- **Acceptance:** LAB-3's "Done when":
  - one command reproduces the curve with variance;
  - the note states whether RQ-2 holds on unchanged code and ranks the
    bottlenecks.
- **It also requires:**
  - the seed-42 tracing-overhead comparison, reported;
  - the child-thread variant, pre-registered and then run;
  - attribution done as note 003 describes;
  - the clock-offset concern in section 6 resolved before censored results are
    interpreted.
- **Likely size:** the timing sweep is about 3 hours: 15 children at ~11.5
  minutes each, longer where guards or drains slow the high values. The count
  sweep adds about an hour. Consider stopping this chunk after the sessions
  curve and its interpretation.
- **First action:** plan the chunk and send it for plan review. Then run the
  timing sweep in the background on an otherwise quiet machine, and check it as
  children finish.

## 8. Decisions and authorizations in force

- **Carried forward:**
  - The lab pivot, with daily use secondary.
  - `ROADMAP.md` is the sole status source.
  - Commit and push each completed item or step.
  - Real-model runs need the owner's explicit go-ahead each time.
  - Protocol v1 is retired.
  - Driver/oracle review applies to all work; each chunk ends with a reviewed
    handoff.
- **LAB-3 design, agreed in review and binding for its measurements:**
  - Note 003's rules, including LAB-3's reading of "5 MB" as 5 MiB.
  - In-VM protocol-v2 clients: accepted, with their shared-scheduler cost stated
    as part of the claim.
  - One fresh VM per (value, seed), run seed-major.
  - Timing runs untraced; count runs separate.
  - A failed hypothesis bound is a measurement, not a sweep failure.

## 9. Open questions for the user

- **Unmerged branches (carried forward):** what to do with
  `codex/harness-harvesting-ideas`, `codex/elara-tui-design-studies` and
  `exp/001-mission-receipt-design` (the last exists only on `origin`). This
  blocks deleting or merging them.
- **Security advisories (carried forward):** how to respond to `mint 1.9.3`'s
  advisories (one HIGH), pulled in via `req`. This blocks dependency upgrades.
- **LAB-6 (carried forward):** whether to rebuild the Coordinator's judging and
  map/reduce on Threads, or drop them. This blocks LAB-6.

## 10. Operational state

- **Running jobs or processes:** none.
- **Evidence to keep:** everything under `lab/results/`, which git does not
  hold. Keep each until the owner archives or releases it.
  - The LAB-2 files cited by note 002 and the previous handoff.
  - The three unused pre-slice-E smoke files `lab/results/smoke/20260926T2356*`.
  - The labeled shakedown file in section 5.
- **Removed:** one stray sweep directory from a mutation run
  (`lab/results/smoke/20260927T040702514368Z-sweep-sessions-seed1`). It was not
  evidence.
- **Cleanup obligations:** none.
- **Unsafe to repeat:** mutating the sweep CLI's validation guards (see the
  gotcha in section 11).
- **Operating condition for registered sweeps:** they run for hours and their
  timings are confounded by other load on the laptop. Run them when the machine
  is otherwise quiet; this needs no separate approval unless the owner has
  stated a constraint or the machine is visibly busy.

## 11. Conventions and gotchas

- **Questions:** the owner wants one question per message.
- **Mutation checks:** mutation-check every new test: break the behavior, see it
  go red, restore, see it green.
- **Stale beams:** a mutation of the same byte size, restored within the same
  second, can leave a stale compiled module that Mix won't rebuild. After each
  write and restore, set the file's mtime into the future and recompile. Run
  `MIX_ENV=test mix compile --force` before trusting a green run.
- **CLI validation tests:** some pass no `--results`. If a mutation removes a
  guard, they launch a real sweep into `lab/results/`. Check for stray
  `*-sweep-*` directories after such a run.
- **`tr`:** in the owner's zsh, `tr` is aliased to `trash`, so don't use it.
- **`ls`:** aliased to `eza`, so use `/bin/ls` when flags matter.
- **Backticks:** never put backticks inside double-quoted shell strings, since
  zsh runs them. Send Herdr prompts from a file.
- **Markdown reflow:** a formatter hook reflows Markdown after each edit made
  with the editor tools, so re-read a file before editing it again. Edits made
  from the shell are not reflowed.
- **Long reviews:** a large diff review can outlast the 580 s prompt wait. Run
  `herdr agent wait` on the oracle before reading its reply.
- **Suite run time:** `mix test` takes about 2.6 minutes. Replay a failing order
  with `mix test --seed N`.
- **Expected warnings:** lab tests that deliberately retain a directory print
  "lab cleanup unconfirmed; retained ..." or "lab scenario ... raised". That is
  expected.
- **`concurrency` defaults:** they are the registered values, so a bare
  `mix elara.lab run concurrency` is a full 10-user, 10-minute run.
- **Busy Exec:** `concurrency` refuses to start while `Elara.Exec` runs a job.
  Its tests are `async: false`.
- **Tool-failure timestamps:** the scenario reads tool-failure times from
  session-entry wall clocks, converted with `System.time_offset/1` read after
  the run. Elixir starts the VM in `multi_time_warp` mode, so the offset can
  change; see the clock-offset item in section 6.
- **Children's environment:** a sweep's children inherit `MIX_ENV`. In the test
  environment, `config/runtime.exs` nests each child's TMPDIR under the one the
  sweep assigned.
- **Receipt ordering:** a session broadcasts `turn_ended` before it settles the
  input's receipt, so wait for the settled receipt.
- **Lab runner:** after unconfirmed cleanup, the runner leaves the global
  sessions root bound to that run's directory, so don't reuse that VM. A sweep
  child's VM exits anyway.
- **Job-scenario digests:** job scenarios' choice digests are the same for every
  seed.

## 12. Skills

- **Required:** `driver` for the driver and `oracle` for the oracle.
- **Optional:** `herdr`, and `mattpocock-skills:tdd`.
