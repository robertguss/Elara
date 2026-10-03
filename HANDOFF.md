# Handoff — driver chunk ending 2026-10-03 (afternoon)

Linear is the queue and status source: the
[Elara project](https://linear.app/robert-guss/project/elara-7ee4b27c1215) and
its
[current handoff](https://linear.app/robert-guss/document/current-handoff-lab-3-attribution-and-continuation-569eb39fa4cd)
document, whose top entry is this chunk's. Record continuation state, blockers,
review evidence, and delivery there. This file is the driver's chunk-end handoff
for the fresh driver and oracle. It points at Linear rather than restating it.
The complete pre-migration handoff is preserved in the
[import snapshot](https://github.com/robertguss/Elara/blob/03b257159f987e0baf4de9b57f71af156721a5d0/HANDOFF.md);
its host observations are historical.

## 1. State

Observed 2026-10-03 on the owner's M3 Max (macOS, AC power), checkout
`/Users/robertguss/Projects/startups/Elara`. `main` and `origin/main` are at
`f9ccd9b`. This handoff was written on branch `work/driver-handoff-2026-10-03b`
from `f9ccd9b`; its commit merges to `main` before the fresh driver starts.
Reviewed through `f9ccd9b`; pushed through `f9ccd9b`. The live remote had no
other `work/` heads; local remote-tracking refs may be stale (`git fetch
--prune`). Re-check HEAD, the working tree and the remote before acting.

## 2. Queue

Linear: team ROB, project Elara. Snapshot 2026-10-03: one executable item,
[ROB-1238](https://linear.app/robert-guss/issue/ROB-1238) (Ready). It is
ROB-1228 2/2, one N=500 diagnostic run localizing LAB-3's profile setup stall.
Its brief was approved after 4 oracle plan rounds, but the run never launched:
the host-load gate did not hold in its 60-minute window. Its latest `[driver]`
comment records what happened. Resuming needs a fresh oracle plan re-review
first: `run.sh` pins HEAD and `origin/main` to `f9ccd9b`, which this handoff's
merge changes. That re-review covers revision selection, provenance checks and
fresh evidence filenames for the second gate window. The existing
`rob-1238-prelaunch.log` stays in place; do not rename or move it. Then, in
order: ROB-1083 (LAB-3, the owner's
answer (a)), ROB-1235 (the LAB-5 fail-closed fix), and the rest of ROB-1085
(LAB-5). The order and its reasons are in the Linear current handoff's top entry
and in ROB-1085's latest `[driver]` comment. No issue is parked in Needs Input.

Gates and deferred work, unchanged and still current:
- LAB-4 ([ROB-1084](https://linear.app/robert-guss/issue/ROB-1084)) needs LAB-3
  and [ROB-1091](https://linear.app/robert-guss/issue/ROB-1091).
- LAB-6 (ROB-1086) and LAB-8 (ROB-1088) need LAB-5; the ROB-1095 Coordinator
  decision (drop) is made.
- LAB-7 (ROB-1087) needs LAB-4 and LAB-6.
- ROB-1097–1106 are parked ideas.
- ROB-1107/1108 are deferred hands-on acceptance of implementation that
  already exists.
- Backlog: ROB-1216 (intermittent SSE test), ROB-1233 and ROB-1234.

## 3. Read these first

- `AGENTS.md` `## Driver` (config and delivery rules) and `CLAUDE.md`.
- The Linear issue you pull, all of its comments, and the project's "Direction,
  research agenda and operating rules" document.
- For ROB-1238: ROB-1228's description, `docs/lab/README.md` (the `setup`
  diagnostics paragraph), and note 003 Limits → Attribution.
- For LAB-5: `docs/lab/005-shell-chaos.md` (registration, smoke addendum,
  attempts 1–4).

## 4. Context

- Staffing: a Pi worker built ROB-1230. The owner then told the outgoing
  driver, "from now on I want you to do all the work yourself in this session",
  so the driver built ROB-1231, 1232, 1237 and 1238 itself. That override
  applied to the outgoing session. Whether it continues is for the owner to
  say; `AGENTS.md` still names Pi.
- Separately, the owner gave the driver full autonomy over what to work on,
  instead of asking. The driver chose the queue order above and recorded it in
  Linear.
- LAB-5's registered pilot is complete and valid (attempt 4, `c82a17f`). The
  predicted finding held 10/10: a started mutation reopened without an effect
  executor is recorded as failed/"interrupted", not indeterminate, against the
  fail-closed rule. ROB-1235 is that fix. LAB-5 itself (the fault matrix and
  ≥1000 schedules) remains unfinished.
- LAB-3: ROB-1237 added opt-in timing of the first census's phases. The driver's
  hypothesis is synchronous supervisor enumeration in `Profile.census/1`, but it
  is unproven. ROB-1238 must distinguish queue wait from supervisor execution
  and scheduling before any causal fix is proposed.

## 5. This chunk

- PR #18 `897becb` ROB-1230: LAB-5 attempt 3 recorded as invalid.
- PR #19 `c82a17f` ROB-1231: session_recovery results made JSON-safe, with host
  provenance.
- PR #20 `3bf748d` ROB-1232: the registered LAB-5 pilot (attempt 4). The oracle
  independently recomputed every table number.
- PR #21 `f9ccd9b` ROB-1237: setup-phase timing.
- ROB-1238: not run (load gate).

Each issue's `[driver]` completion comment records its oracle rounds and
findings, its verify results, and which of those the oracle checked
independently. Full-suite and focused test results are driver-reported
throughout.

## 6. Decisions and authorizations in force

All are recorded in Linear: the standing delivery authorization (AGENTS.md
`## Driver`), the owner's LAB-3 answer (a) on ROB-1083, the LAB-5 option (c) on
ROB-1085, and the owner's grant of autonomy (ROB-1085 comment). Nothing extra is
held in this file.

## 7. Operational state

- Worker: per `AGENTS.md`, `pi` with no arguments, one fresh pane per step. Pi
  built ROB-1230 this chunk; the driver built the rest (§4). No worker is
  running.
- No Elara BEAM, sweep, sampler or watchdog is running. An unrelated BEAM from
  another checkout (`wts-dops/stellic`) comes and goes; it is external load.
- Retained evidence (untracked, keep, per ROB-1092):
  `lab/results/session_recovery/` (attempts 3 and 4, repro, logs),
  `lab/results/rob-1085-smoke/`, and `lab/results/concurrency-diag/`. The last
  holds ROB-1238's `run.sh`, `wd.py`, `fixture.sh`, the fixture log and the
  prelaunch log.
- `run.sh` refuses to overwrite `rob-1238-prelaunch.log` and pins `f9ccd9b`.
  A second attempt needs a re-reviewed launcher with fresh evidence names; the
  existing log stays in place.
- Earlier LAB-3 evidence stays under `lab/results/concurrency/` (both N=500
  profiles, `20261002T210908440701Z-…` and `20261003T123711789702Z-…`, plus
  their `lab3-profile*` logs).

## 8. Conventions and gotchas

- The shell is zsh: `PIPESTATUS` is unset there. Run measurements under explicit
  Bash and capture `${PIPESTATUS[@]}` immediately. macOS `/bin/bash` is 3.2 (no
  associative arrays); this chunk's watchdog is Python for that reason.
- Quote heredocs (`<<'EOF'`) for prompts and briefs. Write briefs as `.txt`: a
  formatter hook reflows `.md` files written in the scratchpad.
- `pgrep -lf beam.smp` self-matches Herdr prompt text. Use `pgrep -x beam.smp`
  with `ps -o pid,args` and the cwd from `lsof -a -d cwd -p PID -Fn`.
- Host load from the owner's other workspaces (Playwright Chrome, java, macOS
  media analysis) reached load averages of 120. Under that load, full `mix test`
  runs failed different tests each time, `main` included. The cause is not
  established. Save every full run to a file and rerun failing files in
  isolation. Before delivery, satisfy the step's reviewed verification gate:
  a passing full run, or a baseline exception the oracle accepts.
- Do not run tests or compiles in the checkout while a sweep or diagnostic
  runs, including the oracle.
- Established intermittents: the `attachment_test.exs:408` task census, the
  sampler peer count, and the OpenAI fragmented-SSE test (ROB-1216). Observed
  under heavy load this chunk, cause unestablished: OpaqueShell fixture
  registration (ROB-1233), AttachmentTest interrupt history, OpenAI loopback
  chat, CheckDiagnosis, ContextTest fresh-BEAM recovery, InputAttachmentsProduct,
  ThreadsTest real PTY, and two ConcurrencyTest runs. Each passed in isolation.
- Linear: no Linear MCP in the driver's session. Use GraphQL with
  `$LINEAR_API_KEY`. Linear documents can contain control characters that `jq`
  rejects; read and update them from Python with
  `json.loads(..., strict=False)`. Driver comments start with `[driver]`.
- `herdr agent prompt --wait` can outlast a 10-minute tool call. Fall back to
  `herdr agent wait`, and read only once the agent is idle.
- A `session_recovery` sweep exits non-zero by design: the predicted
  `indeterminate_without_receipt` check fails for `tool_running`.

## 9. Skills

Required: `driver` for the driver, `oracle` for the oracle, and `worker` for
each worker if workers resume. Optional: `herdr`.
