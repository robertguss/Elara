# Handoff — autonomous implementation, 2026-10-06

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
- LAB-5 child preparation covers parent delegation and child provider/marker
  crashes through the public child lifecycle in a disposable Git fixture.
  It checks durable input/tool identities, automatic reports, one child,
  capacity release and exact acknowledgment before integration. Focused 46
  and three fresh dev-VM rows passed (all 16 checks and cleanup true).
  Released-callback, premature-death, forced-failure and unavailable-barrier
  controls are retained, including a rejected barrier-ownership mutation, in
  `lab/results/rob-1085-child-preparation-20261005/`. See note 005 and ROB-1085
  for final suite, review and delivery. The first full suite passed 920/922;
  ROB-1216's two loopback helper timeouts were repaired separately in PR #40.
  The unchanged lab code then passed all 924 integrated full-suite checks,
  seed 1085. Exact review and delivery are recorded in ROB-1085. These are
  preparations.

Delivered changes have reviewed diffs, clean format/diff checks, both Socket
checks, and verified squash-merge tree equality in their Linear records.
No historical lab results or registered measurements were changed.
CI has Socket checks and does not run mix test; local test evidence is separate.

## Current diagnosis and queue

ROB-1216 is Done after PR #40 merged at `5448d84`. Its fixture repair follows
two retained 2-second loopback helper timeouts in the child candidate's full
suite, seed 1085 (920/922). The missing assertion/stack/seed evidence is now available.
The fixture repair uses a bounded 10-second wait and keeps the runtime/parser
and all response assertions unchanged. Public JSON and fragmented-SSE controls
delayed 2100 ms both fail at the old limit; all 11 provider tests pass with the
repair. Raw red/green and final verification output is retained under
`lab/results/rob-1216-verification-20261005/`; Linear records exact review and
delivery. Full suite 916 passed (11 properties, 905 tests), seed 1085, in
263.2 seconds; compile/format/diff checks pass. Historical host scheduling was
not causally measured.

The earlier bounded diagnosis did not reproduce SSE failure. The provider file
passed its initial execution plus 20 repetitions (189 test executions), then
one full suite passed 888 (seed 183979), at source `4a9c0ad`. No assertion,
timeout, or parser change. Logs: `lab/results/rob-1216-diagnosis-20261005/`.
Those passing runs remain negative evidence, not a fix.

LAB-5 (ROB-1085) is Done after Results PR #49 merged at `fa482cdf`.
Its registered runtime experiment and Results are delivered. Matrix
infrastructure merged in PR #48 at
`15e000c15321a545d087ed85255d209c50f1cfd4`, with tree equality to reviewed head
`f704752`. Full 971 (11 properties, 960 tests; seed 1085; 272.5 s), focused 14,
compile/format/diff and final-head Socket checks passed. The final handoff-only
wording change preserved all seven runtime/test hashes. All seven finite
recovery families through PR #47 are delivered; their reviews and controls
remain in Linear and note 005.

The one registered measurement at `15e000c` completed: 1200/1200 eligible/passed,
50 at each of 24 checkpoints, seeds 1085000–1086199; every one of 20,350 recorded
check values true. Zero outcome failures, ineligible rows or unconfirmed cleanup.
Independent readback matches every identity, source/settings, Port/OS witness
and observed stub list. Recovery/backlog maxima 1127/1178 ms; all declared bounds
pass. Registration/artifact/source hashes match after the run. The excluded
24-row qualification passed; every earlier pilot/preparation/control stays
excluded. No failing measurement row needs minimization or a runtime fix.

Preserve `lab/results/rob-1085-matrix-measurement-20261006-a1/` and every adjacent
`rob-1085-matrix-*-20261006-a1` registration/launcher/qualification/postflight
file, plus every earlier raw namespace. Manifest SHA256
`bbe689027c60ed364d43f54c7c6cbc3d6aed32bf27e94e038fd0694a74640a41`;
measurement summary SHA256
`f92e30959ce5c3a33cccad4e4612957e530755517c9e2b22a6cc7a6c81efdc20`.
The registered launcher has exited. Never rerun/reuse its namespace or pool
other rows into the corpus. The source may now change for reviewed Results
and subsequent work. Measurements are finite scripted-provider/owned-group
claims; detached descendants, disk damage, arbitrary positions, real models
and human acceptance remain excluded. An unrelated Phoenix VM was observed at
postflight outside Elara; leave it alone. Timing is host-specific.

LAB-6 (ROB-1086) is selected as the sole executable lab item. Work is on
`work/rob-1086-selective-retirement`; read its staged plan and latest review in
Linear before continuing. The first chunk removes Coordinator/Engine/API and
migrates every TestExecutor caller to production Executor with assertions intact.
Focused inheritance/Threads/executor/input/effect verification passed 148
(seed 1086); caller migrations preserve all other bytes. The separate
instruction/skill inheritance test uses public Threads. Note 006
records the deliberately removed batch contracts and four Coordinator tests.
LiteralPatch/OpaqueShell runtime retirement and project-plugin diagnosis follow;
LAB-6 stays active until all acceptance is merged. Keep TestJobs until LAB-8
supplies a replacement, and preserve all LAB-5 corpora. Do not resume LAB-3.

LAB-8 also depends on LAB-5; LAB-4/LAB-7 retain their recorded dependencies.
ROB-1091 and ROB-1097–1106 need individual scope review under autonomy. The goal
continues while actionable work remains.

ROB-1104 retains the optional explicit receipt-client finding: accepted, one
callback attempt, zero terminals, A indeterminate and B/C queued behind the
nonterminal barrier. Read-only post-VM SQLite matches job ID/digest; physical
native cleanup creates no causal terminal or generic acknowledgment authority.
The separate-group Port-child preparation remains at local `627c5e7` and its
retained namespace; detached descendants are the existing policy exclusion.
ROB-1324/1325 fixture repairs and all other delivered evidence are recorded in
Linear. Preserve every original failed log, copied root and local branch.

ROB-1107/1108 are Needs Input for owner hands-on/visual TUI acceptance. LAB-3
remains at its recorded measurement pause and strict host protocol below.
Do not stop unrelated workspace work or resume an old launcher against new
source. The registered LAB-5 experiment did not resume LAB-3.

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
- Known unresolved intermittent failures include attachment/sampler census.
  ROB-1216, ROB-1233 and ROB-1254 have demonstrated fixture fixes;
  consult their delivery records. Preserve failure
  logs and baseline comparisons rather than treating reruns as proof of a fix.
- Use `pgrep -x beam.smp`, then ps and lsof cwd checks to identify a process.
  Broad pattern searches can self-match prompt text.
- Cite the result's `host.commit`; squash merges change commit identifiers.
