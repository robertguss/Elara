# Handoff — driver chunk ending 2026-10-03 (evening)

Linear is the queue and status source: the
[Elara project](https://linear.app/robert-guss/project/elara-7ee4b27c1215).
Briefs, review outcomes and results live in each issue's `[driver]` comments.
The project's
[current handoff](https://linear.app/robert-guss/document/current-handoff-lab-3-attribution-and-continuation-569eb39fa4cd)
document is the earlier loop's continuation log. This chunk did not update it:
under crew, the issues' comments and this file carry continuation.
`test/elara/roadmap_test.exs` requires this link.
This file is the chunk-end handoff for the next crew (driver, oracle, builder).
It points at Linear rather than restating it. Earlier handoffs are in git
history; this one carries forward every item that is still open.

## 1. State

Observed 2026-10-03 (evening) on the owner's M3 Max (macOS, AC power), checkout
`/Users/robertguss/Projects/startups/Elara`. `main` and `origin/main` are at
`2e1cc79`. This handoff was written on branch `work/driver-handoff-2026-10-03d`
from `2e1cc79`, and its commit squash-merges to `main` before anyone resumes.
Reviewed through `2e1cc79`; pushed through `2e1cc79`. No other `work/` heads
exist on the remote. Local remote-tracking refs may be stale
(`git fetch --prune`). Re-check HEAD, the working tree and the remote before
acting.

## 2. Queue

Linear: team ROB, project Elara. Snapshot 2026-10-03 (evening): **no executable
item.** Nothing is Ready, in a started status, or parked in Needs Input. No
split issue has sub-issues left. The next driver selects one under the owner's
autonomy grant (§6), moving it to Ready with a `[driver]` comment.

The recorded order (ROB-1243's completion comment and the latest `[driver]`
comment on ROB-1083):

1. [ROB-1255](https://linear.app/robert-guss/issue/ROB-1255) (Backlog): the
   LAB-3 harness fix ROB-1243 motivated. It takes the census's session
   enumeration off `Elara.SessionSup`'s mailbox. Direction (a) is harness-only;
   direction (b) is a product change and outside LAB-3's scope unless the owner
   decides otherwise. It needs a plan review and a test that fails first.
2. [ROB-1083](https://linear.app/robert-guss/issue/ROB-1083) LAB-3 (owner answer
   (a)): after that fix, one more N=500 rerun with the registered command (probe
   off), reported beside the originals, under the registered eligibility rules.
3. The rest of [ROB-1085](https://linear.app/robert-guss/issue/ROB-1085) LAB-5:
   the fault matrix and at least 1000 schedules.

Gates and deferred work, unchanged:

- LAB-4 ([ROB-1084](https://linear.app/robert-guss/issue/ROB-1084)) needs LAB-3
  and [ROB-1091](https://linear.app/robert-guss/issue/ROB-1091).
- LAB-6 (ROB-1086) and LAB-8 (ROB-1088) need LAB-5. The ROB-1095 Coordinator
  decision (drop) is made.
- LAB-7 (ROB-1087) needs LAB-4 and LAB-6.
- ROB-1097–1106 are parked ideas.
- ROB-1107/1108 are deferred hands-on acceptance of implementation that already
  exists.
- Backlog: ROB-1216 (intermittent SSE test), ROB-1233, ROB-1234, and ROB-1254
  (new: `ThreadsTest:123` fails at `06b8a65` too, under host load).

## 3. Read these first

- `CLAUDE.md` (including `## Crew`) and `AGENTS.md` `## Delivery and tracking`.
- The Linear issue you pull, with all of its comments, and the project's
  "Direction, research agenda and operating rules" document.
- For ROB-1255 / LAB-3:
  - note 003, "SessionSup diagnosis (ROB-1243, 2026-10-03)" and the "Setup-stall
    diagnosis (ROB-1228, 2026-10-03)" before it (Limits → Attribution);
  - `docs/lab/README.md`, the `setup` and `session_sup_probe` paragraphs;
  - the completion comments on ROB-1243 and ROB-1252.
- For LAB-5: `docs/lab/005-shell-chaos.md` and ROB-1235's completion comment.

## 4. Context

- **Crew.** Elara now runs on the `crew` skill: an Opus driver, a Sonnet builder
  and a Fable oracle. Jev (`jev.py gate`) picks the reviewer for each phase.
  This chunk was the first under crew, and Jev sent every phase to the oracle
  (the concurrency flag).
- **The LAB-3 finding.** One probe-on run supports the hypothesis that the
  census stall is harness-level: `DynamicSupervisor.start_child` runs each `Elara.Session.init/1` inside
  `Elara.SessionSup`, so SessionSup serializes session inits. The census's
  `which_children` call waited about 130 s behind about 326 queued `start_child`
  calls, with SessionSup blocked in `:proc_lib.sync_start/2` for 99.9% of its
  traced time.
  - It is still unknown whether each init is slow or merely unscheduled under
    load. That matters for a product fix (ROB-1255 direction (b)), not for the
    harness fix (a).
- **Probe.** `session_sup_probe` (default 0) is for diagnosis only. With 0, runs
  are as before apart from `call_start`/`call_done` clock reads in profile runs.
  Probe-on runs are not comparable with probe-off runs. The registered ROB-1083
  rerun must run with the probe off.
- **LAB-5.** Unchanged since the previous handoff. ROB-1235 made restart repair
  fail closed (a deliberately conservative choice). The matrix and the 1000
  schedules remain.

## 5. This chunk

Each step went to the oracle, by Jev's call; review details are in each issue's
`[driver]` completion comment.

- PR #27 `3c4399f` ROB-1251 (ROB-1243 1/2): the opt-in SessionSup probe, split
  call timing, the running trace and `session_starts`, plus the AGENTS.md
  sentence recording the autonomy grant.
  - Oracle: plan 3 rounds, diff 2 rounds.
  - The oracle checked independently: OTP 29 behaviour of status, trace sessions
    and the mailbox-copy cost (throwaway scripts); the negative-clock bucket bug
    and its fix; targeted lab tests (70 passed).
  - Driver-reported only: the full `mix test` (876/881; the 5 failures were in
    unrelated files under host load and pass 30/30 in isolation) and the
    targeted run (135 passed).
- PR #28 `2e1cc79` ROB-1252 (ROB-1243 2/2): one N=500 diagnostic run at
  `3c4399f` and note 003's write-up.
  - Oracle: plan 2 rounds, launcher check 1 round, write-up 2 rounds.
  - The oracle independently recomputed every share, decisive condition and
    count from `repetitions.jsonl`, and tested the launcher's result check on
    synthesized records.
  - Driver-reported only: the run's execution (its logs are the evidence).
- Linear only: ROB-1243 is Done, with ROB-1255 and ROB-1254 filed in Backlog.

## 6. Decisions and authorizations in force

All are recorded in Linear or the repository:

- the standing delivery authorization (`AGENTS.md`);
- the owner's autonomy grant over queue order and selection, reconfirmed in the
  driver pane on 2026-10-03, now in `AGENTS.md` and on ROB-1243;
- the owner's LAB-3 answer (a) on ROB-1083;
- the LAB-5 option (c) on ROB-1085.

Nothing is held only in chat.

## 7. Operational state

- No Elara BEAM, sweep, sampler, watchdog or launcher is running. External BEAMs
  from `wts-dops/campus-mvp` and another `beam.smp` (mise Erlang, seen at 891%
  CPU) come and go. They are external load.
- Retained evidence (gitignored; keep it, per ROB-1092):
  - `lab/results/concurrency-diag/`:
    - ROB-1238's two attempts, unchanged;
    - ROB-1243/1252's run: `run-1243.sh`, `fixture-1243.sh`, `rob-1243-*` (logs,
      `rob-1243-analysis.py` and `.out`) and
      `concurrency/20261003T221109754815Z-sweep-sessions-seed42/`;
    - `wd.py` is shared and unchanged (sha256 `81ddb6d8…`).
  - Still kept from before: `lab/results/rob-1235/`,
    `lab/results/session_recovery/`, `lab/results/rob-1085-smoke/` and
    `lab/results/concurrency/`.
- Do not rerun `run.sh`, `run-a2.sh` or `run-1243.sh`. Each pins its revision
  and refuses to overwrite its logs. A new run gets its own reviewed launcher
  and fresh evidence names.

## 8. Conventions and gotchas

- **Shell.** It is zsh: `PIPESTATUS` is unset, `ls` is aliased (use
  `command ls`), and `echo ===` fails. Run measurements from a Bash script file
  and capture `${PIPESTATUS[@]}` immediately. macOS `/bin/bash` is 3.2.
- **Prompts and briefs.**
  - Quote heredocs (`<<'EOF'`) for every prompt and brief. An unquoted heredoc
    runs backticked words as commands and silently drops them from the prompt;
    this happened twice this chunk.
  - Write briefs as `.txt`: a formatter hook reflows `.md` files written in the
    scratchpad.
- **Crew tooling.**
  - Run `jev.py` and `crewlog.py` directly; they are `uv run` scripts, so
    `python3 jev.py` fails on the missing `typesafe_sdk`.
  - `jev.py fresh` crashes (`StopIteration`) on a pane that has never been
    prompted. Treat that pane as already fresh.
  - `crewlog.py usage` needs the issue the `step` was logged under (the parent
    when the step is a sub-issue).
- **Reading agents.** `herdr agent read` truncates long replies. Ask the oracle
  and builder to write replies to a scratchpad file and reply with its path.
  Text in an agent's input box (for example "commit it") is Claude Code's
  auto-suggestion, not user input.
- **Verify builder reports.** Check every claim against the tree. A report this
  chunk named a test file that did not exist.
- **GitHub.** `gh pr create` hung with no output this chunk. Creating the PR
  with `gh api repos/robertguss/Elara/pulls` and merging with
  `gh api -X PUT …/pulls/N/merge -f merge_method=squash` worked. The PR checks
  are only Socket ×2; CI does not run `mix test`.
- **Linear.** There is no Linear MCP in the driver's session. Use GraphQL with
  `$LINEAR_API_KEY`: the `project.issues` connection is too complex, so filter
  `issues(filter:{project:{name:{eq:"Elara"}}})`. Read with
  `json.loads(..., strict=False)`. Driver comments start with `[driver]`.
- **Host load.** The owner's other workspaces drive the 1-min load to 30–100.
  - The ROB-1252 gate held at 22:10Z after two failed candidates.
  - Under load, the full suite fails different unrelated tests each run.
    This chunk: check_diagnosis_test:30/:112, attachment_test:346 and
    open_ai_test ×2 (driver-run; they passed in isolation), and ThreadsTest:123
    (ROB-1254, also failing at the base revision).
  - Also seen under load this chunk, not baselined: the lab_sampler "phased"
    test and a lab_concurrency settlement test. The builder reported both
    passing in isolation; the driver has not confirmed either.
  - An exception for a known intermittent needs the oracle's acceptance.
  - Save every full run to a file, rerun failing files in isolation, and run a
    baseline at the base revision in a separate `git worktree` when in doubt.
- **Established intermittents:**
  - the `attachment_test.exs:408` task census;
  - the sampler peer count;
  - ROB-1216 (SSE);
  - ROB-1233 (OpaqueShell);
  - ROB-1254 (ThreadsTest:123).
- **Probe data.**
  - Probe sample `t` is the tick's start, and the read lands before the next
    tick (`sampler.ex`).
  - `running` bucket starts are aligned on the negative monotonic clock, using
    floor division.
  - Result-line `params` are CLI strings.
- **Process checks.** `pgrep -lf beam.smp` self-matches agent prompt text. Use
  `pgrep -x beam.smp` with `ps -o pid,args` and the cwd from
  `lsof -a -d cwd -p PID -Fn`.
- **Citing SHAs.** Cite the commit the run recorded (`host.commit`):
  `3c4399f` for ROB-1252's run, `c8678b6` for ROB-1235's. Do not substitute a
  SHA the run did not record; squash merges change SHAs.
- **Tests.** The built-in `write` tool makes `Elara.start_session` open a
  LocalExecutor (lib/elara.ex:365). A test that needs the direct
  (`effect_executor: nil`) path must use a custom mutating tool.
- **Scripts.** Claude Code's safety check refuses inline `bash -c` scripts it
  cannot inspect, so write the script to a file first.
- **Repository writes.** Do not run tests or compiles in the checkout while a
  sweep runs, and do not merge to `main` while a launcher's gate runs: its
  recheck stops if `origin/main` moves.

## 9. Skills

Required: `crew` for every role. Optional: `herdr`.
