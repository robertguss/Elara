# Handoff — ROB-1234 recovery digest, 2026-10-05

[Elara in Linear](https://linear.app/robert-guss/project/elara-7ee4b27c1215)
is the sole planning and status source. The
[current handoff](https://linear.app/robert-guss/document/current-handoff-lab-3-attribution-and-continuation-569eb39fa4cd)
and issue descriptions carry current continuation. Historical issue comments
retain the briefs, review outcomes, decisions, and results.

## Working arrangement

The owner removed the previous role-based workflow on 2026-10-05 and instructed
the active agent to do the work in this session.
Follow AGENTS.md's delivery and tracking rules. No external skill, separate
agent roles, routing script, or pane tooling is required.

The current active goal is to implement every actionable Linear issue, choose
the queue and implementation decisions autonomously, and move genuine owner
questions to Needs Input before continuing. The goal is incomplete while any
actionable work remains. LAB-3 remains Needs Input at its measurement pause;
the digest fix does not launch a measurement or consume its remaining rerun.

## Repository and verification

ROB-1234 is selected on `work/rob-1234-reproducible-recovery-digest` from main
`4ec59de`. Its Linear issue holds the execution plan, review, and delivery
record. Recovery reports now hash the fault and raw simulator choices, omitting
per-run identities from the digest while preserving identity validation and
evidence. The same-seed real-run regression failed on the old code; the full
recovery file then passed 31 tests (seed 98431), including fresh runs of all
three faults. Compile with warnings as errors, formatting, and diff checks
passed. The diff review confirms the reporting-only scope: recovery behavior,
registration, bounds, and retained result files are unchanged. Check Linear
and Git for merged delivery before treating this issue as Done.

Historical audit verification follows for provenance.

The audit started from clean main at `25fe51b0f6d75847d54d81fbd3204873c432b6ca`,
equal to remote main. That revision includes the census fix `8568f34` and differs
from it only in this handoff. The audit branch was
`work/linear-state-audit-2026-10-05`. The audit changes AGENTS.md, CLAUDE.md,
HANDOFF.md, and the guidance pointer test; implementation and experiment
registrations are unchanged. Read the
[Linear audit record](https://linear.app/robert-guss/document/issue-accuracy-audit-2026-10-05-8070f2f9117f)
for the final checks and delivery revision. Recheck Git and Linear before acting.

All 46 project issues, including archived items, their full descriptions,
comments, status histories, attachments, and dependency relations were read.
Done delivery records were compared with Git history and GitHub merge records.
Current code was checked through the refreshed codebase-memory graph and
bounded source inspection. Retained LAB-3 and LAB-5 JSONL was read to verify
provenance, validity, completion, and failed checks. Historical real-provider,
physical-terminal, and host-load failure claims remain dated evidence.

Verification in this audit: full mix test 886 passed (seed 61482); guidance
tests 3 passed; warnings-as-errors compile, format, and diff checks clean.
Rust TUI tests 116 passed and exec-stub tests 6 passed. No registered
measurement or real-provider run was repeated. The unresolved intermittent
findings remain open despite this passing suite.

## Queue and remaining gates

- [ROB-1083](https://linear.app/robert-guss/issue/ROB-1083), LAB-3: paused;
  the final N=500 supplementary rerun has not launched. Its description links
  the current continuation and the existing approved measurement brief.
- [ROB-1085](https://linear.app/robert-guss/issue/ROB-1085), LAB-5: Backlog.
  The pilot and ROB-1235 recovery fix are delivered. The remaining fault matrix
  and at least 1000 schedules are unfinished.
- LAB-4 (ROB-1084) needs LAB-3 and the post-LAB-3 owner direction checkpoint
  ROB-1091. LAB-6 (ROB-1086) and LAB-8 (ROB-1088) need LAB-5; ROB-1095's
  deliberate Coordinator removal decision is made. LAB-7 (ROB-1087) needs
  LAB-4 and LAB-6.
- ROB-1097–1106 remain parked. ROB-1107/1108 cover deferred hands-on acceptance
  of existing TUI implementation.
- ROB-1234 is the current delivery item; ROB-1254 is the next independent
  candidate. ROB-1216, ROB-1233, and ROB-1254 remain unresolved findings.
  A passing run does not establish that an intermittent is fixed.

LAB-3 closure is an owner decision. Keep at most one executable lab item and
none while paused. No force-push, deployment, release, or evidence deletion
without a specific owner decision.

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
- Known unresolved intermittent failures include attachment/sampler census,
  ROB-1216 SSE, ROB-1233 OpaqueShell, and ROB-1254 ThreadsTest. Preserve failure
  logs and baseline comparisons rather than treating reruns as proof of a fix.
- Use `pgrep -x beam.smp`, then ps and lsof cwd checks to identify a process.
  Broad pattern searches can self-match prompt text.
- Cite the result's `host.commit`; squash merges change commit identifiers.
