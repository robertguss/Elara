# Handoff — autonomous implementation, 2026-10-05

[Elara in Linear](https://linear.app/robert-guss/project/elara-7ee4b27c1215)
is the sole planning and status source. Read the
[current handoff](https://linear.app/robert-guss/document/current-handoff-lab-3-attribution-and-continuation-569eb39fa4cd)
and current issue descriptions/comments for plans, review, results, and delivery.

## Working arrangement and active goal

The owner retired the previous role workflow and instructed the active agent to
do all work here. Follow AGENTS.md and CLAUDE.md. No external skill, separate
agent roles, routing script, or pane tooling is required.

The active goal is to implement every actionable Linear issue, choose work and
technical decisions autonomously, put genuine owner questions in Needs Input,
and continue other work. The goal remains active while actionable work remains.
Historical parked/unselected wording alone does not require owner permission.
Keep at most one executable lab item. Do not force-push, deploy, release, or
remove retained evidence without a specific owner decision. Done means merged.

## Delivered and verified

- The 46-issue accuracy audit and guidance retirement merged in PR #32 at
  `4ec59de`. Its [record](https://linear.app/robert-guss/document/issue-accuracy-audit-2026-10-05-8070f2f9117f)
  is a dated snapshot; later issue Results supersede its queue counts.
- ROB-1234 merged in PR #33 at `5e23f19`: recovery digests omit run identities
  while identity validation and evidence remain intact. A public same-seed
  regression failed before the fix; 31 recovery tests passed afterward.
- ROB-1254 merged in PR #34 at `4b8d4d9`: explicit provider synchronization
  replaces the timed child fixture. Delayed observation reproduced the old
  failure; the barrier and forced-failure cleanup controls passed. Full suite
  887 passed, seed 670644. Logs: `lab/results/rob-1254-verification-20261005/`.
- ROB-1233 merged in PR #35 at `4a9c0ad`: register the owned fixture root before
  optional descendant sampling; verify command ownership on macOS. Independent
  red controls prove registration and cleanup defects; 22 OpaqueShell, 100
  effect, and 8 Exec integration tests passed. Logs:
  `lab/results/rob-1233-verification-20261005/`.
- LAB-5 transport preparation protects a worker job through the handler's
  unlink/kill interval and handles closed socket setup by cancelling the job.
  Four TCP/Exec lifecycle tests and two new deadline regressions cover real
  process cleanup, monitor retirement, and buffered/sustained fragments. Red
  controls and a forced-failure cleanup check are retained in
  `lab/results/rob-1085-transport-20261005/`. Full suite 894 passed, seed 1085.
  PR and merge evidence are in ROB-1085; this is not full matrix acceptance.
- ROB-1324 repairs the production-write fixture's 100 ms lifecycle wait with
  an explicit 5-second bound and one ordered cleanup owner. A delayed valid
  provider reproduces the old failure; the fixed wait passes. A forced-failure
  witness confirms all four tracked actors stop before directory removal.
  Effect suite 100 and full suite 894 passed, seed 1085. Raw controls, including
  the rejected first cleanup ordering, remain in
  `lab/results/rob-1324-verification-20261005/`; Linear records PR/merge evidence.
- LAB-5 handoff preparation adds a read-only input observer, monitored lifecycle
  gates, and five public handoff crash checkpoints. It follows finished
  successors, distinguishes interruption/failed/paused from completion, and
  rejects unexpected inputs and stale receipt/event evidence. Provider and
  marker work must be admitted before effects; cleanup closes admission first.
  Focused verification passed 38, seed 1085; five fresh dev-VM preparations
  passed all 21 checks. The integrated full suite passed 914, seed 1085.
  Controls and exact source hashes are in
  `lab/results/rob-1085-expanded-preparation-20261005/`; see note 005 and
  ROB-1085 for final review, suite, and delivery evidence. These are preparations.

Delivered changes have reviewed diffs, clean format/diff checks, both Socket
checks, and verified squash-merge tree equality in their Linear records.
No historical lab results or registered measurements were changed.
CI has Socket checks and does not run mix test; local test evidence is separate.

## Current diagnosis and queue

ROB-1216's bounded diagnosis did not reproduce SSE failure. The provider file
passed its initial execution plus 20 repetitions (189 test executions), then
one full suite passed 888 (seed 183979), at source `4a9c0ad`. No assertion,
timeout, or parser change. Logs: `lab/results/rob-1216-diagnosis-20261005/`.
The issue is Needs Input for a retained failing assertion/stack/seed. Passing
runs are negative evidence, not a fix.

LAB-5 (ROB-1085) is Building, the one selected executable lab item. The valid
pilot, recovery fix, and transport preparation are delivered; the
children/handoff/jobs/client/worker/stub/whole-VM/process-group matrix and at
least 1000 schedules remain. Review and register its expanded method before
measurement; reuse the durable lab runner and fresh production-intensity VMs.
The handoff observer/gates/five checkpoints originated at local candidate
`149b6a5`, whose full suite exposed ROB-1324. That fixture repair merged in
PR #38 at `0c2d6dd`; the handoff changes are integrated on
`work/rob-1085-expanded-recovery-matrix`, with all 914 full-suite checks passing.
ROB-1085 records review, PR and merge confirmation for this preparation.
The handoff family is implemented but unmeasured. Next extend the remaining
child/test-job/native/client/worker/stub/whole-VM families, preserving causal
fault witnesses, per-input receipt/terminal accounting, honest uncertainty,
slot/acknowledgment and native cleanup checks. The current handoff fixture's
script/gate PIDs support same-VM recovery only; do not reuse that provider
configuration for whole-VM restart. Keep every preparation separate from the
eventual registered matrix and preserve its source provenance.
LAB-6/LAB-8 depend on LAB-5; Coordinator judging/map-reduce removal was already
decided by ROB-1095. LAB-4/LAB-7 retain their research dependencies.

ROB-1107/1108 are Needs Input for owner hands-on/visual acceptance of implemented
TUI behavior. ROB-1097–1106 require individual scope review under autonomy.
LAB-3 remains at its recorded measurement pause, with its unrun final N=500
profile and strict host protocol below. AC power was present during the current
checks, but one measured 1-minute load was 23.52, above its required maximum 8;
no load gate or measurement was launched. Do not stop unrelated workspace work.

## LAB-3 continuation

Read ROB-1083's description and the 2026-10-03 brief and pause comments,
ROB-1255's completion comment, note 003's registration and attribution tables,
and docs/lab/README.md's census comparability rule.

The census fix reads SessionSup's links minus its parent, avoiding a mailbox
call behind serialized session initialization. It includes a child still in
init. A census with queued starts is not comparable with earlier runs at that
N; N=10's SessionSup state was not recorded. The fix has not yet been verified
by the final N=500 measurement.

Retained launcher state:
- `lab/results/concurrency/run-rerun2.sh` and `fixture-rerun2.sh` belong to
  attempt 1. It stopped at preflight on battery, before compile, gate, or sweep.
  Never rerun or overwrite these files or their two logs.
- `run-rerun2-a2.sh` and `fixture-rerun2-a2.sh` are the reviewed, unrun copy.
  Their recorded hashes start `0dd1c056` and `0fc379fe`.
  The `lab3-profile-n500-rerun2-a2-*` output namespace was empty at the audit.
- The launcher still pins `8568f34`; it must not be run as-is against a later
  revision. Before measurement resumption, review its revision/provenance checks
  and amend the brief on ROB-1083. The old amendment allowed only HANDOFF.md to
  differ. This audit also changes AGENTS.md, which is a runtime prompt input:
  do not silently broaden that allowance or assume an identical workload.
  Choose and document a measurement revision that respects the registration.
- Confirm AC power, clean pinned source, no Elara BEAM, and the approved load
  gate: two 1-minute readings at most 8, 60 seconds apart, within 120 minutes.
  The charger stays connected. The watchdog deadline is 40 minutes.
- Once the sweep starts there is no retry, including a watchdog kill.
  A further pre-sweep stop needs a recorded disposition and fresh namespace.
- Phase C reports the result's eligibility, provenance, diagnostics,
  `settlement.killed_sessions`, and `leftover_sessions` beside the originals.
  Invalid profiles stay unranked and leave LAB-3 unfinished.

Cleanup still computes a deadline before a SessionSup `which_children` call;
a backlog can exhaust that deadline and lead to kills. It is an unresolved
measurement limitation, outside this audit.

## Evidence and operational notes

Preserve all of `lab/results/`, particularly concurrency, concurrency-diag,
session_recovery, rob-1085-smoke, and rob-1235. ROB-1092's decision is retain
as-is. ROB-1093's historical and archive branches remain retained; delivered
work branches have been removed. Leave `stash@{0}` (WIP on `cc6e778`) alone.

At the audit's pre-test process check no `beam.smp` was running. Recheck before
future experiments. Do not stop unrelated workspace processes.
No tests, compiles, or source edits while a measurement launcher is running.

- Use explicit Bash for launchers and capture PIPESTATUS immediately; macOS
  Bash is 3.2. Quote heredocs. Re-derive source line numbers.
- Use the connected Linear tools. Read current descriptions and comments before
  writes; historical `[driver]` and `[lead]` prefixes identify earlier records.
- CI has Socket checks and does not run mix test; distinguish local tests from
  CI evidence.
- Known unresolved intermittent failures include attachment/sampler census
  and ROB-1216 SSE. ROB-1233 and ROB-1254 have demonstrated fixture fixes;
  consult their delivery records. Preserve failure
  logs and baseline comparisons rather than treating reruns as proof of a fix.
- Use `pgrep -x beam.smp`, then ps and lsof cwd checks to identify a process.
  Broad pattern searches can self-match prompt text.
- Cite the result's `host.commit`; squash merges change commit identifiers.
