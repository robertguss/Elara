# Handoff — driver chunk ending 2026-10-03 (late afternoon)

Linear is the queue and status source: the
[Elara project](https://linear.app/robert-guss/project/elara-7ee4b27c1215) and
its
[current handoff](https://linear.app/robert-guss/document/current-handoff-lab-3-attribution-and-continuation-569eb39fa4cd)
document, whose top entry is this chunk's. Record continuation state, blockers,
review evidence, and delivery there. This file is the driver's chunk-end handoff
for the next driver and oracle. It points at Linear rather than restating it.
The complete pre-migration handoff is preserved in the
[import snapshot](https://github.com/robertguss/Elara/blob/03b257159f987e0baf4de9b57f71af156721a5d0/HANDOFF.md);
its host observations are historical.

## 1. State

Observed 2026-10-03 on the owner's M3 Max (macOS, AC power), checkout
`/Users/robertguss/Projects/startups/Elara`. `main` and `origin/main` are at
`6401912`. This handoff was written on branch `work/driver-handoff-2026-10-03c`
from `6401912`, and its commit merges to `main` (squash) before anyone resumes.
Reviewed through `6401912`; pushed through `6401912`. The live remote had no
`work/` heads; local remote-tracking refs may be stale (`git fetch --prune`).
Re-check HEAD, the working tree and the remote before acting.

## 2. Queue

Linear: team ROB, project Elara. Snapshot 2026-10-03: **no executable item.**
Nothing is Ready, in a started status, or parked in Needs Input. The owner has
switched Elara to the new `crew` skill (§4), so the outgoing driver pulled no
further issue. The next driver selects one, under the owner's autonomy grant
(§6), and moves it to Ready before planning.

The driver's recorded order (ROB-1083's latest `[driver]` comment):

1. [ROB-1243](https://linear.app/robert-guss/issue/ROB-1243) (Backlog): LAB-3
   further diagnosis. It must tell queue wait from supervisor work in the
   census's `Elara.SessionSup` `which_children` interval. Its measurement
   protocol needs an oracle plan review, and it is another N=500, load-gated
   run.
2. [ROB-1083](https://linear.app/robert-guss/issue/ROB-1083) LAB-3 (owner answer
   (a)): a fix once the cause is clear, then one more N=500 rerun.
3. The rest of [ROB-1085](https://linear.app/robert-guss/issue/ROB-1085) LAB-5:
   the fault matrix and at least 1000 schedules.

Gates and deferred work, unchanged and still current:

- LAB-4 ([ROB-1084](https://linear.app/robert-guss/issue/ROB-1084)) needs LAB-3
  and [ROB-1091](https://linear.app/robert-guss/issue/ROB-1091).
- LAB-6 (ROB-1086) and LAB-8 (ROB-1088) need LAB-5; the ROB-1095 Coordinator
  decision (drop) is made.
- LAB-7 (ROB-1087) needs LAB-4 and LAB-6.
- ROB-1097–1106 are parked ideas.
- ROB-1107/1108 are deferred hands-on acceptance of implementation that already
  exists.
- Backlog: ROB-1216 (intermittent SSE test), ROB-1233 and ROB-1234.

## 3. Read these first

- `AGENTS.md` `## Driver` (delivery rules) and `CLAUDE.md`.
- The Linear issue you pull, all of its comments, and the project's "Direction,
  research agenda and operating rules" document.
- For LAB-3 / ROB-1243: note 003's "Setup-stall diagnosis (ROB-1228,
  2026-10-03)" subsection under Limits → Attribution, `docs/lab/README.md` (the
  `setup` diagnostics paragraph), and ROB-1238's completion comment.
- For LAB-5: `docs/lab/005-shell-chaos.md` (attempt 4 and "Fix verification
  (ROB-1235)") and ROB-1235's completion comment.

## 4. Context

- **Workflow switch (owner decision, 2026-10-03).** Elara is moving from the
  driver/oracle/worker loop to the `crew` skill: an Opus driver, a Sonnet
  builder and a Fable oracle. The outgoing driver finished its last step and
  stopped there. No replacement driver was started, and the current oracle was
  left running.
- **First action under crew, before selecting any work.** The crew skill reads
  its Linear configuration from a `## Crew` section in `CLAUDE.md`. That section
  does not exist yet, and without it the skill skips Linear. So:
  1. Add `## Crew` to `CLAUDE.md` with `Linear: team ROB, project Elara`.
  2. Reconcile the old staffing text in `AGENTS.md` `## Driver` (Codex oracle,
     Pi worker) with the crew roles.
  3. Keep Elara's rules where crew's defaults differ:
     - the owner's autonomy grant over queue order and selection (crew defaults
       to user-only Ready selection);
     - at most one executable item;
     - issue branch, PR, oracle sign-off and passing CI before merge;
     - Done means merged, not committed.
- **Staffing in the old loop.** The owner told the earlier driver to "do all the
  work yourself", and this chunk's driver kept to that: it built every step
  itself, with no worker.
- **LAB-3.** ROB-1228's diagnosis localized one N=500 run's setup delay: 148,443
  of the first census's 148,446 ms fell in the census's
  `which_children(Elara.SessionSup)` interval, including its bracketing queue
  reads and bookkeeping. `SessionSup`'s queue read 543 before and 0 after. Queue
  wait, supervisor work and scheduling are not distinguished, and whether the
  earlier ~133 s delays share this localization is unproven. So no fix is
  proposed yet (owner answer (a)).
- **LAB-5.** ROB-1235 fixed the pilot's fail-closed finding: restart repair now
  records the possibly running call as indeterminate. The unchanged pilot
  workload passes 30/30. This is deliberately conservative: a read-only call cut
  off by a restart is also indeterminate. The executor-recovery residual is in
  `docs/sessions.md`. LAB-5 itself (the matrix and at least 1000 schedules)
  remains unfinished.

## 5. This chunk

- PR #23 `d71e97f` ROB-1238 (ROB-1228 2/2): the N=500 setup-stall diagnostic and
  note 003's write-up. Attempt 2 ran at `3854b7e`. ROB-1228 is Done, and the
  follow-up is ROB-1243.
- PR #24 `6401912` ROB-1235: restart repair fails closed, verified by the pilot
  workload at fix commit `c8678b6`.

What the oracle checked itself: it recomputed every note number from the raw
JSONL and the host log, for both issues. It also reran ROB-1235's seven focused
test files (148 passed). Driver-reported only: the full `mix test` (864 passed,
0 failures, seed 913206), format/compile checks, the red-before test evidence,
and both sweeps' execution. Details are in each issue's `[driver]` completion
comment.

## 6. Decisions and authorizations in force

All are recorded in Linear: the standing delivery authorization (AGENTS.md
`## Driver`), the owner's LAB-3 answer (a) on ROB-1083, the LAB-5 option (c) on
ROB-1085, and the owner's grant of autonomy (ROB-1085 comment). One decision is
not on an issue yet: the switch to the `crew` skill (§4). It covers how the loop
is staffed, not the queue or any authorization.

## 7. Operational state

- No worker is running, and no Elara BEAM, sweep, sampler or watchdog is
  running. An unrelated BEAM from another checkout (`wts-dops/stellic`) comes
  and goes; it is external load.
- Retained evidence (gitignored, keep, per ROB-1092):
  - `lab/results/concurrency-diag/` holds both ROB-1238 attempts.
    - Attempt 1 (gate failed, not run): `run.sh`, `fixture.sh`,
      `rob-1238-prelaunch.log`, `rob-1238-compile.out` and
      `rob-1238-watchdog-fixture.log`.
    - Attempt 2 (the run): `run-a2.sh`, `fixture-a2.sh`, the `rob-1238-a2-*`
      logs and `concurrency/20261003T165722555796Z-sweep-sessions-seed42/`.
    - `wd.py` is shared by both attempts and unchanged.
  - `lab/results/rob-1235/` holds the fix-verification sweep.
  - Still kept from before: `lab/results/session_recovery/`,
    `lab/results/rob-1085-smoke/` and `lab/results/concurrency/`.
- Both ROB-1238 launchers refuse to overwrite their logs and pin their revisions
  (`f9ccd9b` and `3854b7e`). Do not rerun them: a new diagnostic gets its own
  reviewed launcher and fresh evidence names.

## 8. Conventions and gotchas

- The shell is zsh: `PIPESTATUS` is unset there, `ls` is aliased (use
  `command ls` in scripts), and `echo ===` fails. Run measurements from a Bash
  script file and capture `${PIPESTATUS[@]}` immediately. Claude Code's safety
  check refuses inline `bash -c` scripts it cannot inspect, so write the script
  to a file first. macOS `/bin/bash` is 3.2.
- Quote heredocs (`<<'EOF'`) for prompts and briefs. Write briefs as `.txt`: a
  formatter hook reflows `.md` files written in the scratchpad.
- The built-in `write` tool makes `Elara.start_session` open a LocalExecutor
  (lib/elara.ex:362). A test that needs the direct (`effect_executor: nil`) path
  must use a custom mutating tool.
- Host load: elevated 1-min load averages (30–55) coincided with activity from
  the owner's other workspaces (iOS simulator and Xcode tests, Spotlight, node,
  CodexBar). The samples do not apportion that load. A 60-min load gate failed
  in the previous chunk and held in this one. Full `mix test` passed cleanly
  this chunk under light load. Under heavy load, earlier chunks saw different
  tests fail each run, so save every full run to a file and rerun failing files
  in isolation. An exception for a known intermittent needs the oracle's
  acceptance.
- Do not run tests or compiles in the checkout while a sweep or diagnostic runs,
  including the oracle.
- Established intermittents: the `attachment_test.exs:408` task census, the
  sampler peer count, and the OpenAI fragmented-SSE test (ROB-1216). Seen under
  heavy load earlier, cause unestablished: OpaqueShell fixture registration
  (ROB-1233) and several others listed in the previous handoff (git history).
- Linear: no Linear MCP in the driver's session. Use GraphQL with
  `$LINEAR_API_KEY`, and read documents from Python with
  `json.loads(..., strict=False)`. Driver comments start with `[driver]`.
- `pgrep -lf beam.smp` self-matches agent prompt text. Use `pgrep -x beam.smp`
  with `ps -o pid,args` and the cwd from `lsof -a -d cwd -p PID -Fn`.
- Squash merges change SHAs. Cite the measured commit (here `c8678b6`, also
  reachable through PR #24's head), never the squash SHA.

## 9. Skills

Required: `crew`, per the owner's switch (§4). The old loop's `driver`, `oracle`
and `worker` skills apply only if the owner reverts. Optional: `herdr`.
