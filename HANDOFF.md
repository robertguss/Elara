# Handoff

## 1. State

Observed 2026-09-30: repository `/Users/robertguss/Projects/startups/Elara`,
branch `main`. Work is reviewed and pushed through `c806975` to `origin/main`.
This handoff is committed on top of it. The working tree was clean before this
file. Re-check HEAD, `git status` and `origin/main` before relying on this.

The owner paused the session mid-chunk ("stop for the night and resume
tomorrow"): steps 1–3 are done, and step 4 is planned and signed off but not
started.

## 2. Read these first

- **`ROADMAP.md`**: the sole status source. LAB-3 is IN PROGRESS.
- **`docs/lab/003-concurrency-baseline.md`**, "### Attribution" under Runs: the
  binding registration (at `cd0b16d`) of the N = 10 profile and the
  supplementary N = 500 one. Its text must not change.
- **`docs/lab/README.md`**: `trace=profile`, the five `profile-*.tsv` tables,
  and the exact `compare` recipe for waiting evidence.
- **`git log --oneline cd0b16d..c806975`**: this chunk's three commits, each
  describing what it changed and verified.
- **`CLAUDE.md` and `AGENTS.md`**: lab direction and conventions.

## 3. Context

LAB-3 measured the sessions curve (all three RQ-2 bounds fail at N = 500) and
the child-thread variant (refuted at K = 16). Nothing is attributed yet. This
chunk builds and runs the registered attribution: a `call_time` own-time profile
of classified processes over [480 s, 600 s), with two memory censuses.

What was built:

- `Elara.Lab.Profile` and `Elara.Lab.MemoryCensus` (`26bf5b4`): the
  registration's classes, ordered activation, freeze, barriers, validity rules
  and holder census.
- `trace=profile` in the concurrency scenario (`a0fccb5`), through
  `Elara.Lab.Scenarios.Concurrency.Profiling`: census, then activation at the
  window's start; at load end, freeze, then census, then collection in a linked
  collector beside the drain; a profile run carries no verdict.
- `Elara.Lab.ProfileReport` (`c806975`): the per-N tables, written by
  `mix elara.lab report` for a profile sweep; `no_verdict` in report and points.

**The `other` limit (owner decision: keep the registration).** In tiny smoke
runs the descriptive `other` class held 27–33% of traced own time, mostly
`prim_file`, `file_io_server` and `Exqlite`, most likely file I/O server
processes that sessions spawn. The registered classes do not rank them, so
`:file.sync/1`'s cost may sit outside the ranking. The step-4 write-up states
this as a limit with other's share per N; it is not an amendment.

## 4. Agreed chunk and acceptance

- **Objective:** LAB-3 attribution, then close-out.
  1. Profile and memory-census libraries. Done, `26bf5b4`.
  2. Scenario wiring, `trace=profile`. Done, `a0fccb5`.
  3. Profile reporting. Done, `c806975`.
  4. The two registered profile runs and their write-up in note 003. Plan signed
     off (revision 2); not started.
  5. Close-out: note 003's Interpretation and Limits, LAB-3 DONE with a Result
     of at most five lines, LAB-4 made executable.
- **Excluded:** children-topology profiling (deferred by the owner and not
  registered, at `cd0b16d`), any other N,
  `call_memory`, lock counting, any RQ-2 fix (LAB-7), real-model runs, LAB-4 and
  later.
- **Stopping condition:** step 5 committed and pushed, then the reviewed
  handoff. **Fallback:** if either profile is invalid, incomplete, fails its
  checks, or is missing or unusable, the chunk stops after step 4's write-up with LAB-3 IN PROGRESS (unless
  the owner explicitly revises this). N = 10 may still be ranked on its own when
  eligible; N = 500 is then reported, not ranked.
- **After the chunk:** the owner wants to pause and discuss with the oracle (and
  maybe another LLM) what comes next, including when to start building the
  harness out for real daily use. At close-out, ROADMAP's "Next action" says:
  "Discuss future direction with the owner; LAB-4 remains TODO in the queue
  pending that discussion." That keeps `roadmap_test`'s one-executable- item
  rule without authorizing LAB-4.
- **Disposition:** `incomplete` (paused by the owner before step 4).
- **Scope changes, each agreed in review:** step 1 adopted untracked code the
  previous driver wrote without review; step 2 added the bounded
  `Profile.dispose/1` and the `Concurrency.Profiling` module; step 3 added
  `t0_ms` to the profile and put the tables in their own module.

## 5. Verification and review

All results below are driver-reported unless marked as oracle-checked.

**Step 1 (`26bf5b4`).**

- Plan: signed off in 1 round.
- Diff: 3 rounds. P2: a restarted named actor silently became `other`; now
  `:named_actor_replaced` invalidates. The oracle's two plan-review points
  (barrier on both sessions; pid counts from records) were fixed.
- Checks: full suite 755 passed. 41 mutants, 37 red; 4 survive as redundant
  checks on the tested paths (md5 check, the two session-destroy paths, a `nil`
  binding filter), which the oracle confirmed on those paths only. A flaky
  receipt assertion I added was found and fixed.
- Oracle-checked: restarts of all three named actors, counter-loss probes,
  focused tests.

**Step 2 (`a0fccb5`).**

- Plan: 3 rounds. P2s: collector replies consumed by receive loops; unbounded
  collector and classifier cleanup; window validation breaking non-profile runs;
  collector surviving owner death; completion timestamps and the empty-read
  race.
- Diff: 3 rounds. P2: a failed collection discarded its window, known failures
  and census, then its measured holders (now kept under class `unavailable`).
  P3: overdue failures count as timeouts. All fixed.
- Checks: full suite 782 passed; 26 mutants, all red. CLI smoke (tiny sweep,
  sessions=2,4, `smoke2` below) exit 0, result lines about 220 KB, collection
  76 and 131 ms. Step-2 results carry no `t0_ms`.
- Oracle-checked: owner-death and cancel probes, failure-path probes, the smoke
  JSON.

**Step 3 (`c806975`).**

- Plan: 2 rounds. P2s: qualification context in every table; census timestamps
  and per-table ETS rows.
- Diff: 2 rounds. P2: module roll-ups lost the native flag (now
  `includes_native`, `native_us`). Fixed.
- Checks:
  - Before the native roll-up fix: full suite 801 passed at seeds 226522,
    758110 and 643313. One run at seed 285253 failed `ThreadsTest` "real PTY
    starts two children…" (`test/elara/threads_test.exs:678`); it passed 3 of
    3 alone and did not recur. Its cause, and whether it relates to this
    chunk's changes, are unknown.
  - After the fix (the committed code): full suite 802 passed at seed 960192.
  - 22 mutants, all red.
  - A fresh CLI smoke (`smoke3` below) exit 0, with census 1 at t = 1010 ms
    against from = 1000.
- Oracle-checked: focused tests and the smoke tables.

**Step 4 (plan only).** Plan: 2 rounds, signed off. P2: validity and the four
latenesses in every condensed table.

## 6. Remaining work

1. Step 4: the registered runs and write-up.
2. Step 5: LAB-3 close-out.
3. The direction discussion (section 4).
4. Then the ROADMAP queue as that discussion leaves it: LAB-4 and LAB-5, then
   LAB-6 to LAB-9.

## 7. Next chunk

**Approved (resumed):** this chunk, from step 4. Its plan is already signed off;
re-send it as a short plan review only if anything changed.

- **First action:** ask the owner about host conditions (below). On 2026-09-30
  at 18:02 the host was very busy: 1-minute load 91, an iOS Simulator and
  `fseventsd` near or above 100% CPU, and another project's BEAM (`campus-mvp`)
  running. Check again before asking.
- **Step 4 procedure (signed-off plan):**
  1. Preconditions: tree clean at the pushed HEAD, no Elara BEAM running, AC
     power, `MIX_ENV` unset.
  2. The owner's host-conditions answer, recorded.
  3. A pre-launch record in
     `lab/results/concurrency/lab3-profile-prelaunch.log`: UTC date, HEAD,
     `git status --porcelain`, Elixir and OTP versions, `pmset -g batt`,
     `uptime`, the command.
  4. A host sampler every 5 minutes (`date -u`, `uptime`, top 8 by CPU) into
     `lab3-profile-host.log`, stopped when the sweep ends; confirm it stopped.
  5. The registered command, in the background, logged to
     `lab3-profile-sweep.out`:

         caffeinate -ims mix elara.lab sweep concurrency --over sessions=10,500 --n 1 --seed 42 --set trace=profile

  6. Record end time and exit status. Verify each result line's commit, dirty
     false, seed 42, `trace=profile`, its sessions value and no other parameter.
  7. `mix elara.lab report PROFILE_DIR`, then the README's `compare` from
     `lab/results/concurrency/20260927T101541605186Z-sweep-sessions-seed42`
     (untraced timing base) to PROFILE_DIR, rows for N = 10 and 500 only.
     `:file.sync/1` per second from Table C (count sweep
     `20260927T125116839454Z-sweep-sessions-seed42`).
  8. Eligibility per profile before any ranking.
- **Step 4 boundaries (signed-off plan):** step 4 makes no code changes. A
  defect a run exposes stops work for owner and oracle review; it is not fixed
  inline. Verification: `mix test test/elara/roadmap_test.exs` passes; `git
  diff` shows no registered text changed; the oracle recomputes the write-up's
  tables from the TSVs.
- **Write-up (signed-off plan):** note 003 gets Results, Interpretation and
  Limits "### Attribution" subsections:
  - Table I: validity.
  - Table J: classes, with other's share and top modules.
  - Table K: the top five functions per N, with total µs, share of class and of
    ranked, calls, the native flag, and µs/s beside the interior and envelope
    lengths; plus the top five modules.
  - Table L: each suspect, with source-audited call paths labelled as such, else
    "not attributed".
  - Table M: waiting evidence, untraced value with the traced one beside it.
  - Table N: memory holders, with census timestamps, unique bytes, VM binary
    memory and the signed difference; `system` differences include profiler
    storage.
  - The traced/untraced pair, with Table D's caveat.

  Every condensed table carries validity and the four latenesses. Complete lists
  are in the linked TSVs. A bottleneck is claimed only where own-time rank and
  waiting evidence agree. Estimates are labelled, and N = 500 is labelled
  supplementary. The LAB-3 Result gains one clause; status stays IN PROGRESS
  until step 5.

- **Acceptance:** step 4 and step 5 committed and pushed, or the fallback.

## 8. Decisions and authorizations in force

- **Carried forward:**
  - The lab pivot, with daily use secondary.
  - `ROADMAP.md` is the sole status source.
  - Commit and push each completed step.
  - Real-model runs need the owner's go-ahead each time.
  - Protocol v1 is retired.
  - Driver/oracle review applies to all work, and each chunk ends with a
    reviewed handoff.
  - Note 003's rules, including the report definitions (a clean repetition is
    `Sweep.ok?/1`; bounds come from `Sweep.aggregate_bounds/2`; cleanup is
    reported separately).
  - `thread_limit` defaults to 4.
  - No reruns without the owner's approval, and any approved rerun is reported
    beside the original.
- **Added this chunk:**
  - The supplementary N = 500 profile is owner-approved (it is in the
    registration).
  - Children-topology profiling is deferred by the owner and not registered
    (`cd0b16d`).
  - The attribution registration stays as written; the `other` limit is stated,
    not amended (owner, 2026-09-30).
  - After LAB-3, pause for the direction discussion (owner).
  - Profile runs carry no verdict: empty `bounds`, `no_verdict` in reports, and
    they are excluded from `ratio_below_threshold_values`.
  - Call paths in the write-up are source-audited and labelled so; no runtime
    caller tracer (oracle ruling).
  - Profile knobs `profile_window_ms` (default 120,000) and `profile_collect_ms`
    (default 300,000) are validated only for `trace=profile`; `trace=profile`
    requires `topology=sessions`.

## 9. Open questions for the user

- **Host conditions for step 4:** quiet the host first, or run as is and record
  it? This blocks step 4's launch.
- **The retained run directories (carried forward):** about 24.5 GiB under the
  children sweep's `tmp/`, plus the shakedown's 0.93 GiB under
  `lab/results/concurrency/lab3-variant-shakedown/tmp/`. Archive or release?
  This blocks deleting them.
- **Unmerged branches (carried forward):** `codex/harness-harvesting-ideas`,
  `codex/elara-tui-design-studies`, and `exp/001-mission-receipt-design` (only
  on `origin`). This blocks deleting or merging them.
- **Security advisories (carried forward):** how to respond to `mint 1.9.3`'s
  advisories (one HIGH), pulled in through `req`. This blocks dependency
  upgrades.
- **LAB-6 (carried forward):** rebuild the Coordinator's judging and map/reduce
  on Threads, or drop them. This blocks LAB-6.

## 10. Operational state

- **Running jobs or processes:** none from Elara. The BEAM seen at pause time
  belongs to another project (`campus-mvp`); leave other projects' processes
  alone.
- **Evidence to keep:** everything under `lab/results/` (about 25.5 GiB, not in
  git), as the handoff at `af1d188` listed, until the owner decides. This chunk
  added nothing there. Its smoke sweeps and mutation scripts are in a
  temporary session scratch directory (see section 11); they support this
  chunk's verification claims but are not registered measurement evidence,
  and may disappear.
- **Cleanup obligations:** none, beyond the owner's decision on retained
  directories.
- **Unsafe to repeat:**
  - A `pgrep -f` loop whose pattern appears in its own command line.
  - Editing the tree or running tests while a sweep runs.
  - Mutating the sweep CLI's validation guards without `--results` (it can
    launch a real sweep into `lab/results/`).
  - Smoke-testing sweeps without `--results <scratch>`.

## 11. Conventions and gotchas

- **Questions:** the owner wants one question per message.
- **Mutation checks:** mutation-check every new test. After each mutant write
  and restore, set the file's mtime into the future and run
  `MIX_ENV=test mix compile --force` before trusting a result. This chunk's
  harness scripts (`mutate-step1.py`, `mutate-step2.py`, `mutate-step3.py`)
  and smoke sweeps (`smoke2/`, `smoke3/`) are, for now, in the temporary
  directory `/private/tmp/claude-501/-Users-robertguss-Projects-startups-Elara/a2390d7d-faeb-4ee2-a2f4-783a6942fbf0/scratchpad/`. Rebuild them if they are gone.
- **Markdown notes:** a formatter hook reflows Markdown after editor-tool
  edits, so edit registered notes (note 003) from the shell.
- **`mix format` reflows code:** string-replace edits written against pre-format
  text fail; re-read the formatted text first.
- **Heredocs:** write prompts with `<<'EOF'`. An unquoted heredoc runs
  backticked words as commands (it silently dropped a word from one prompt).
- **Line-number filters go stale:** re-derive them after editing a test file.
- **Session directories can begin with `_`:** never filter the sessions root by
  an `_` prefix; session files are exactly `root/*/*.jsonl`.
- **In the concurrency tests, the coordinator is the test process.** Raising
  inside the scenario mid-load leaves users and sessions running; that is why
  the exception test raises at `:profile_await` and the owner-death test runs at
  `Profiling` level.
- **Profiling details:**
  - The collector is `spawn_link`ed; nothing in the lab traps exits.
  - Cancel is unlink, then kill, then confirmed exit.
  - Outcomes are timestamped in an ETS holder, never sent as messages.
  - `Profile.dispose/1` kills a classifier that does not stop within `:stop_ms`.
- **Census timestamps** are VM monotonic ms (often large negatives); the tables
  add `*_after_t0_ms` from the recorded `t0_ms`.
- **Smoke observations (tiny workload, not registered measurement evidence):** the session class's top
  functions were `:json.escape_binary/5` and `:json.escape_binary_ascii/5`;
  `other` held 27–33%.
- **Intermittent test:** `ThreadsTest` real-PTY test at
  `test/elara/threads_test.exs:678` failed once in five full runs during step 3.
- **Shell:** `tr` is aliased to `trash` and `ls` to `eza`; use `/bin/ls`. zsh
  does not word-split `$VAR` (use `${=VAR}`).
- **Herdr prompts:** send from a file; `--timeout` needs `--wait`; the oracle's
  reply follows the last `Verdict:` line of a pane read.
- **Waiting on long runs:** a Bash `run_in_background` task notifies when it
  exits; a process started with `&` inside a foreground command does not.
- **Expected warnings:** lab tests print "lab cleanup unconfirmed; retained ..."
  or "lab scenario ... raised". `mix test` takes about 3.3 minutes.

## 12. Skills

- **Required:** `driver` for the driver, `oracle` for the oracle.
- **Optional:** `herdr` and `mattpocock-skills:tdd`.
