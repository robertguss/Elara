# Handoff — driver chunk ending 2026-10-03 (night)

Linear is the queue and status source: the
[Elara project](https://linear.app/robert-guss/project/elara-7ee4b27c1215).
Briefs, review outcomes and results live in each issue's `[driver]` comments.
The project's
[current handoff](https://linear.app/robert-guss/document/current-handoff-lab-3-attribution-and-continuation-569eb39fa4cd)
document is the earlier loop's continuation log. This chunk did not update it:
under crew, the issues' comments and this file carry continuation.
`test/elara/roadmap_test.exs` requires this link. This file is the chunk-end
handoff for the next crew (driver, oracle, builder). It points at Linear rather
than restating it. Earlier handoffs are in git history; this one carries forward
every item that is still open.

## 1. State

Observed 2026-10-03 (night) on the owner's M3 Max (macOS, **on battery** at the
time), checkout `/Users/robertguss/Projects/startups/Elara`. `main` and
`origin/main` are at `8568f34`. This handoff was written on branch
`work/driver-handoff-2026-10-03e` from `8568f34`, and its commit squash-merges
to `main` before anyone resumes, so `main` will be one commit past `8568f34`,
differing only in `HANDOFF.md`. Reviewed through `8568f34`; pushed through
`8568f34`. No `work/` heads remain on the remote except, until it merges, this
handoff's branch. The working tree is clean apart from gitignored
`lab/results/`. Re-check HEAD, the working tree and the remote before acting.

## 2. Queue

Linear: team ROB, project Elara. Snapshot 2026-10-03 (night):

- **Executable: [ROB-1083](https://linear.app/robert-guss/issue/ROB-1083)
  (LAB-3), status `Building`, paused mid-step.** The one authorized N = 500
  supplementary rerun, rerun 2, has an oracle-approved brief and an
  oracle-checked launcher, and **has not run**. Its brief is the `[driver]`
  "Brief (oracle-approved)" comment on the issue (Phases A launcher, B launch, C
  write-up). Phase A is done. Phase B is next; see §4 "Resuming ROB-1083".
- Nothing is in `Ready`, `Planning`, `In Review` or `Needs Input`. No split
  issue has sub-issues left.

Recorded order after ROB-1083:

1. The rest of [ROB-1085](https://linear.app/robert-guss/issue/ROB-1085) LAB-5:
   the fault matrix and at least 1000 schedules.
2. If ROB-1083's write-up leaves LAB-3 closable, closure is the **owner's**
   decision (the brief says so). It rests on N = 10 at `eaa88f9` and N = 500 at
   the rerun's revision.

Gates and deferred work, unchanged:

- LAB-4 ([ROB-1084](https://linear.app/robert-guss/issue/ROB-1084)) needs LAB-3
  and [ROB-1091](https://linear.app/robert-guss/issue/ROB-1091).
- LAB-6 (ROB-1086) and LAB-8 (ROB-1088) need LAB-5. The ROB-1095 Coordinator
  decision (drop) is made.
- LAB-7 (ROB-1087) needs LAB-4 and LAB-6.
- ROB-1097–1106 are parked ideas.
- ROB-1107/1108 are deferred hands-on acceptance of implementation that already
  exists.
- Backlog: ROB-1216 (intermittent SSE test), ROB-1233, ROB-1234 and ROB-1254
  (`ThreadsTest:123` under host load).

## 3. Read these first

- `CLAUDE.md` (including `## Crew`) and `AGENTS.md` `## Delivery and tracking`.
- ROB-1083 with all of its comments, especially the four from 2026-10-03 evening
  and night: the release, the brief, attempt 1, and the pause note. Also read
  the project's "Direction, research agenda and operating rules" document.
- ROB-1255's completion comment, and `docs/lab/README.md`'s `setup` paragraph as
  ROB-1255 changed it. It states when the new census differs from the old one
  and the comparability rule the rerun's write-up applies.
- note 003 (`docs/lab/003-concurrency-baseline.md`): the registration ("## Runs"
  → "### Attribution"), Tables I–N with their "Recompute" paragraph, the 26a64f1
  rerun block, and the "Setup-stall diagnosis (ROB-1228)" and "SessionSup
  diagnosis (ROB-1243)" subsections.
- For LAB-5: `docs/lab/005-shell-chaos.md` and ROB-1235's completion comment.

## 4. Context

- **The census fix (ROB-1255, `8568f34`).** The profile census now lists
  sessions by reading `Elara.SessionSup`'s links minus its parent, not by
  calling `which_children`. So it no longer waits behind serialized
  `Session.init/1` calls (ROB-1243's ~130 s stall). With starts queued at the
  first census it lists the sessions alive at that instant, and later ones are
  classified by the spawn trace. A profile with starts queued at activation is
  not comparable with earlier runs at that N. The N = 10 profile recorded no
  SessionSup reading, so whether N = 10 is affected is not shown.
- **Resuming ROB-1083.** The next driver does these in order:
  1. **Check out main.** After this handoff's squash-merge, switch to `main`,
     `git pull --ff-only`, and confirm HEAD = origin/main and a clean tree. The
     launcher checks HEAD, not the branch.
  2. **Re-pin the launcher.** `lab/results/concurrency/run-rerun2-a2.sh` pins
     `SHA=8568f34`, and its `clean_head` requires HEAD = origin/main = that SHA.
     This handoff's merge moves main, so the launcher as reviewed would STOP at
     preflight. Have the builder edit the **unrun** `-a2` launcher in place, as
     `lab/results/concurrency-diag/run-a2.sh` (lines 12–13, 24–26, 51–52) did
     for ROB-1238:
     - `SHA=<new main>` and `BASE=8568f34`;
     - `clean_head` also requires `git diff --name-only $BASE HEAD` to be
       exactly `HANDOFF.md`;
     - the preflight logs that diff, and the `clean_head` stop message names
       the diff check.

     `$SHA` already drives the result check's first line, so nothing else
     changes. Send the edit to the oracle as a launcher re-review, with the diff
     against the signed-off bytes (sha256 `0dd1c056…`), and post the re-pinned
     launcher's new sha256 on ROB-1083. Any other merge to main before the
     launch repeats this step.
  3. **Amend the brief.** Post a `[driver]` brief amendment on ROB-1083 with
     the re-pin. Wherever the brief names `8568f34` as the run's revision, read
     the new main (the run's `host.commit`):
     - the Phase B result line;
     - the Phase C block label;
     - the N = 500 closure revision;
     - the write-up branch base;
     - the `git diff --stat` / no-'-'-lines base.

     ROB-1255's fix is still cited as `8568f34`. Send the builder the amended
     brief.
  4. **Power and load.** `pmset -g batt | head -1` must show 'AC Power' before
     "launch". The launcher checks this only at preflight, so the charger stays
     in until it ends: up to 120 min for the gate, plus up to 40 min for the
     run. 40 min is the watchdog's deadline. It is untested with a live N = 500
     profile, and a watchdog kill uses the rerun. The gate needs two 1-min load
     readings at most 8, 60 s apart. The load was about 24 at 23:12Z.
  5. **Launch and write up** (Phases B and C of the brief). The builder runs
     `bash lab/results/concurrency/run-rerun2-a2.sh` in the background. One
     launch.
     - **What the record covers.** The only recorded retry decision covers
       attempt 1: a preflight stop with no compile, gate or sweep. The brief
       otherwise says a stop is reported, not retried.
     - **A further stop before the sweep** (preflight, fixture or gate) is a new
       driver decision. Record it on ROB-1083 before any relaunch; ROB-1238's
       gate stop is the precedent. A relaunch needs a fresh namespace (`-a3`)
       and an oracle check of the copy.
     - **Once the sweep has started** there is no retry, a watchdog kill
       included.

     Phase C must also:
     - name attempt 1 (stopped at preflight: not on AC power; its two files
       retained);
     - say the run's commit differs from `8568f34` only in `HANDOFF.md`;
     - report `.settlement.killed_sessions` / `leftover_sessions` and the
       cleanup-deadline risk (oracle note on ROB-1083, 2026-10-03 22:43Z).
- **Why the cleanup risk exists.** Run cleanup
  (`lib/elara/lab/scenarios/concurrency.ex:914-915`) computes its deadline
  before a `which_children(Elara.SessionSup)` call. That call can now wait
  behind a start backlog at load end, because the census no longer drains it at
  480 s. Over 30 s, sessions are killed rather than stopped. It is out of scope
  to fix. The write-up reports what happens.
- **LAB-5.** Unchanged since the previous handoff. ROB-1235 made restart repair
  fail closed. The matrix and the 1000 schedules remain.

## 5. This chunk

The driver changed mid-chunk: a replacement driver took over at `09845bb`. Every
review went to the oracle, by Jev's call (concurrency flag, 0.94–0.95).

- PR #30 `8568f34` (branch commit `5b471f1`) ROB-1255: the census reads
  SessionSup's links.
  - Oracle: plan 2 rounds, diff 2 rounds. All findings were fixed; details are
    in the completion comment.
  - Checked independently by the oracle: OTP 29 links/parent behaviour on a
    blocked supervisor; a scratch run with real sessions showing the census set
    equals `which_children`'s; `lab_profile_test.exs` 56 passed; format/compile
    clean.
  - Checked by the driver: the two new tests fail at `09845bb` (54/56, scratch
    worktree); targeted lab files 133 passed.
  - Builder-reported only: full `mix test`, 886 passed, before the round-2 test-
    and doc-only fixes. Not rerun since.
- ROB-1083 (no commit): brief, plan review (oracle, 2 rounds), Phase A launcher
  (oracle launcher check, signed off), attempt 1 stopped at preflight, the `-a2`
  copy (oracle, signed off). Not launched.

## 6. Decisions and authorizations in force

All are recorded in Linear or the repository:

- the standing delivery authorization (`AGENTS.md`);
- the owner's autonomy grant over queue order and selection (`AGENTS.md`);
- the owner's LAB-3 answer (a) on ROB-1083: one N = 500 rerun after the fix;
- the driver's decision on ROB-1083 that attempt 1 (preflight stop, no sweep)
  did not use that rerun;
- the LAB-5 option (c) on ROB-1085.

Nothing is held only in chat.

## 7. Operational state

- **Nothing is running.** No Elara BEAM, sweep, sampler, watchdog or launcher.
  An external `beam.smp` from `wts-dops/campus-mvp` and other workspaces come
  and go as external load.
- **ROB-1083's launcher files** (untracked, under `lab/results/concurrency/`):
  - `run-rerun2.sh` / `fixture-rerun2.sh`: attempt 1 (sha256 `60292ca4…` /
    `84a9491e…`). Never rerun them. The fresh-namespace check refuses anyway.
  - `lab3-profile-n500-rerun2-prelaunch.log` and
    `lab3-profile-n500-rerun2-watchdog-fixture.log`: attempt 1's evidence. Keep
    them.
  - `run-rerun2-a2.sh` / `fixture-rerun2-a2.sh`: attempt 2 (sha256 `0dd1c056…` /
    `0fc379fe…`), signed off but needing the re-pin in §4. The
    `lab3-profile-n500-rerun2-a2-*` namespace is empty.
  - The launcher uses `lab/results/concurrency-diag/wd.py` by path (sha256
    `81ddb6d8…`; logged, not enforced; check the `wd_py_sha256=` line).
- **Retained evidence** (gitignored; keep it, per ROB-1092):
  `lab/results/concurrency-diag/` (ROB-1238 and ROB-1243/1252 runs, launchers,
  `wd.py`), `lab/results/concurrency/` (all lab3 runs and the six
  `*-sweep-sessions-seed42` directories), `lab/results/rob-1235/`,
  `lab/results/session_recovery/` and `lab/results/rob-1085-smoke/`.
- Do not rerun `run.sh`, `run-a2.sh`, `run-1243.sh` or `run-rerun2.sh`. Each
  pins its revision and refuses to overwrite its logs.
- `git stash@{0}` (WIP on `cc6e778`, 2026-09-05) predates the crew. Leave it.

## 8. Conventions and gotchas

- **Shell.** It is zsh: `PIPESTATUS` is unset, `ls` is aliased (use
  `command ls`), and `echo ===` fails. Run measurements from a Bash script file
  and capture `${PIPESTATUS[@]}` immediately. macOS `/bin/bash` is 3.2.
- **Prompts and briefs.**
  - Quote heredocs (`<<'EOF'`) for every prompt and brief. An unquoted heredoc
    runs backticked words as commands and silently drops them from the prompt.
    This happened again this chunk. To insert paths, quote the heredoc and
    substitute a placeholder with `sed` afterwards.
  - Write briefs as `.txt`: a formatter hook reflows `.md` files written in the
    scratchpad.
- **Crew tooling.**
  - Run `jev.py` and `crewlog.py` directly; they are `uv run` scripts.
  - `jev.py fresh` crashes (`StopIteration`) on a pane with no transcript. Treat
    it as already fresh.
  - `crewlog.py usage` needs the issue the `step` was logged under.
- **Reading agents.** Ask the oracle and builder to write replies to a
  scratchpad file and reply with its path. `herdr agent read` truncates. Text in
  an agent's input box is Claude Code's auto-suggestion, not user input.
- **Verify builder reports.** Check every claim against the tree.
- **Launchers.**
  - Check `pmset -g batt` before "launch".
  - A launcher pins main's SHA. Any merge to main between review and launch
    needs a re-pin (§4).
  - While a launcher runs, no `mix` in the checkout and no merges to main.
    Within the first minute, no pane runs a command containing the fixture's
    marker string (`M=` in the fixture, `rob1238-fixture-…`): it trips the
    fixture.
- **GitHub.** `gh pr create` has hung before. Use
  `gh api repos/robertguss/Elara/pulls --input <json>` and merge with
  `gh api -X PUT …/pulls/N/merge -f merge_method=squash`. The PR checks are only
  Socket ×2; CI does not run `mix test`. Delete the merged `work/` branch.
- **Linear.** There is no Linear MCP in the driver's session. Use GraphQL with
  `$LINEAR_API_KEY`: filter `issues(filter:{project:{name:{eq:"Elara"}}})`, and
  read with `json.loads(..., strict=False)`. Driver comments start with
  `[driver]`. The oracle cannot read Linear: export the issue text to a file for
  it.
- **Host load.** The owner's other workspaces drive the 1-min load to 30–100.
  - Under load the full suite fails different unrelated tests each run. Save
    every full run to a file, rerun failing files in isolation, and run a
    baseline at the base revision in a separate `git worktree` when in doubt.
  - An exception for a known intermittent needs the oracle's acceptance.
- **Established intermittents:** the `attachment_test.exs:408` task census; the
  sampler peer count; ROB-1216 (SSE); ROB-1233 (OpaqueShell); ROB-1254
  (ThreadsTest:123).
- **Tests.**
  - `lab_profile_test.exs`'s bracket test suspends the app's `Elara.TaskSup` for
    a few ms, with `on_exit` resume.
  - The built-in `write` tool makes `Elara.start_session` open a LocalExecutor
    (lib/elara.ex:365). A test that needs the direct path must use a custom
    mutating tool.
- **Probe data.** Probe sample `t` is the tick's start. `running` bucket starts
  use floor division on the negative monotonic clock. Result-line `params` are
  CLI strings holding only the keys set on the command line.
- **Process checks.** `pgrep -lf beam.smp` self-matches agent prompt text. Use
  `pgrep -x beam.smp` with `ps -o pid,args` and the cwd from
  `lsof -a -d cwd -p PID -Fn`.
- **Citing SHAs.** Cite the commit the run recorded (`host.commit`). Squash
  merges change SHAs.
- **Scripts.** Claude Code's safety check refuses inline `bash -c` scripts it
  cannot inspect, so write the script to a file first.

## 9. Skills

Required: `crew` for every role. Optional: `herdr`.
