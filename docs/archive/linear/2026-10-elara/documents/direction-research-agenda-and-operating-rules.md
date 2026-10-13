# Direction, research agenda and operating rules

- **Created:** 2026-10-02T00:09:22.383Z by Robert Guss
- **Updated:** 2026-10-07T13:10:06.875Z
- **Linear URL:** https://linear.app/robert-guss/document/direction-research-agenda-and-operating-rules-4281a3150a0e

---

## Current direction — 2026-10-07

The owner explicitly chose balanced BEAM harness research and daily-use improvements ([ROB-1091](https://linear.app/robert-guss/issue/ROB-1091/decision-post-lab-3-research-versus-daily-use-direction)), superseding lab-first/experiment-only prioritization below. Active agent and oracle select the bounded CLI --cwd slice [ROB-1332](https://linear.app/robert-guss/issue/ROB-1332/cli-workspace-selection-cwd-for-ask-chat-and-tui) under [ROB-1106](https://linear.app/robert-guss/issue/ROB-1106/daily-driver-usability) first; [ROB-1098](https://linear.app/robert-guss/issue/ROB-1098/offline-policy-evaluation-by-replay) policy replay returns to Backlog for a bounded recorded-input experiment afterward. Preserve pure Core, single authority, durable uncertainty, and the existing measurement/account/owner-acceptance gates. Older dated directions below are historical where they conflict.

# Current operating rules — 2026-10-05

Linear Elara is the sole planning/status/decision source. The current handoff's top entry and current issue descriptions govern continuation. Registrations, methods, and implementation remain versioned in the repository; raw evidence belongs under lab/results and stays retained. Historical imported observations keep their original dates and limitations.

The owner removed the previous role-based workflow on 2026-10-05. The active agent owns review, planning, implementation, verification, commits, and delivery in the current session. Follow AGENTS.md; no external skill, fixed staffing/model roles, or routing scripts are required. The prior workflow records below are historical.

Ready means explicitly selected; dependencies alone do not authorize execution. Keep at most one executable lab item, none while paused. Backlog is queued/unselected; Planning/Building/In Review reflect actual activity; Needs Input reflects an owner gate; Done means completed delivery merged, or a recorded completed owner decision. Repository pointer tests do not enforce the remote queue.

Standing authorization permits reviewed issue-branch pushes, PRs, and merges after required checks. No force-push, deployment, release, or evidence deletion without a specific owner decision. Owner autonomy over queue order persists; lab-first remains primary, daily use secondary. Elixir is the authority, Rust owns edge processes, and there are no NIFs.

The 2026-10-05 audit authorizes metadata/guidance reconciliation and does not launch paused measurements. LAB-3's final N=500 rerun remains paused and unrun; its revision/provenance, AC-power, and load gates must be handled before resumption. LAB-5's pilot and recovery fix are delivered, but its broader matrix and >=1000 schedules remain. LAB-9 is merged. [ROB-1091](https://linear.app/robert-guss/issue/ROB-1091/decision-post-lab-3-research-versus-daily-use-direction) remains the post-LAB-3 owner direction checkpoint before LAB-4. [ROB-1090](https://linear.app/robert-guss/issue/ROB-1090/decision-lab-3-measurement-host-conditions-and-retained-evidence)/1092/1093/1095 decisions are recorded and completed. Read current issues rather than treating historical “Needs Input” statements as live gates.

# Research agenda

## RQ-1 safety/progress (LAB-1, LAB-5)

Faults: abrupt session/provider task/tool task/stub/client/whole VM exit at named turn points. Exclude disk corruption/torn writes/full disks until explicit revision. Safety: accepted input consumed at most once; mutation never reexecutes after callback begins; uncertainty indeterminate; session files openable. Any counterexample refutes. Historical running-mutation counterexample was fixed by LAB-1, not still open.
Within5 seconds after reopening with simulated provider: inputs terminal (turn ended or durable failed receipt) or recoverable (queued/paused and visible in input_status); slots released or indeterminate-held awaiting operator ack. Consumption alone is not terminal. After resume/ack recoverable inputs must terminate; deadline5 seconds + bounded backlog×per-input simulated work (LAB-5 must bound both).

## RQ-2 scale (LAB-3, LAB-7)

Initial workload:20 turns/session; each read4KB +200ms stub command; simulated TTFT300ms,50 deltas/sec about20B each with intended timestamps; history\~200KB; context_limit1,000,000/no handoff, handoff-lineage separate variant; persistence on;10-minute owner-laptop run/hardware recorded. LAB-3 registration resolves incompatible initial values using cycling sessions and5000B answers; do not revert its fixed workload.
Measure intended-emission-to-attached-v2-client arrival (includes simulator scheduling lag), memory=(VM total+stub RSS−idle baseline)/sessions. Hypothesis N500 p95<50ms, memory<5MB (LAB3 registered MiB), throughput tracks intended rate. Exceeding either ceiling or premature throughput flattening refutes. Suspects: per-delta whole-history JSON visibility/budget; full JSONL rewrites; per-dispatch lineage file scans; recorder hashing/fsync; shared Exec GenServer/Port. Suspects are not causal findings.

## RQ-3 isolation (LAB-4, LAB-7)

One subscriber flood, stalled client, crash loop or unlimited-output command; healthy p95≤2×baseline, memory≤1.5×baseline, offender VM growth<256MB, cancel≤1s with independent process-group disappearance evidence. Indeterminate is not cancellation completion. Shared components exceeding bounds refute. More directly tests containment than aggregate throughput, but no claim about BEAM advantage without comparison.

## RQ-4 lifecycle simplification (LAB-8)

One jobs primitive/correlated wake must preserve durable admission, single completion delivery, indeterminate execution loss, bounded cancellation reporting, restart-held capacity. Measure net lines including infrastructure and session special cases; net increase or lost behavior refutes.

## RQ-5 live change (parked, [ROB-1099](https://linear.app/robert-guss/issue/ROB-1099/parked-rq-5-live-self-modification))

Replay gate covers recorded Core facts only; migration gate actually exercises new shell/tools across fault-injected swap. Loss/duplication or divergence missed by both refutes. Wait for RQ-1/4 results.

# Method

Start from refutable hypothesis. Negative result is finding, not failed implementation. Seed repeats choices, not interleavings; report variance. Simulated first; real-model opt-in/capped/separate. One proportional experiment note, raw data outside docs. Preserve coverage before retirement. Elara properties require controlled internal variation or external runtime comparison before crediting BEAM. Uncertain mutations fail closed; workspace bytes prove postcondition, never causal completion. Tools are not OS sandbox or exactly-once external effects.

# Baseline facts (historical 2026-09-26 review; recheck before designs)

12 iterations/turn,30s tool timeout,16KiB output; stub kills group at cap, now indeterminate. Tools sequential. Iteration/time/output configurable through API, kill-at-cap not. Owner80 skills add\~38KB catalog/request; non-Codex fallback128K context conservative byte estimate. Loopback gateway no auth; trusted repository plugins compile with full authority; tools unsandboxed. Codex subscription/Grok OAuth unofficial endpoints/client IDs; no provider-error retries.

# Explicitly not planned (not backlog commitments)

Provider compatibility compiler; convars; embedded Python extensions; TLA+ models; cross-language plugin ABI; any Rust rewrite of session authority.

# Historical operating records — superseded

These dated records preserve prior authorizations, staffing arrangements, migration states, and observations. Current rules above, current issue descriptions, and the current handoff govern execution.

# (Historical; see the Current handoff top entry for the live queue) Owner resumed — driver loop, 2026-10-02 evening

The owner resumed execution from the driver pane on their M3 Max Mac (not the Linux orb). Instruction: work through the whole backlog, Needs Input decisions included, and do as much as possible. The workflow is now the Herdr driver loop: a Claude **driver** (owns Linear, writes briefs, commits and delivers), a Codex **oracle** (plan, diff and handoff reviews) and a fresh Pi **worker** per step (builds test-first, leaves changes uncommitted). Amp Lead/Builder/Tester orbs are no longer used. Each step: oracle plan review, worker build, driver re-verification, oracle diff review until no P1/P2 is open, then commit on an issue branch, push, PR, merge after CI. Done means merged. The standing issue-branch push/PR/merge authorization continues. Deployment, release and evidence deletion are still not authorized unless the owner decides on a specific issue.

Owner decisions recorded today: ROB-1090 record existing load on this Mac (Done); ROB-1092 retain evidence as is (Done); ROB-1093 four delivered branches deleted, historical kept (Done); ROB-1095 drop Coordinator judging/map-reduce (Done).

Queue, one executable item at a time: (1) AGENTS.md driver configuration, (2) ROB-1089 LAB-9 finish, (3) ROB-1083 LAB-3 step 4 on this Mac, (4) ROB-1085 LAB-5 pilot, then newly unblocked items. Older entries below are historical.

# (Historical, superseded by the resumption above) Owner instruction — paused, 2026-10-02

The owner paused backlog execution after requesting a safe stopping point and all overnight code committed. No issue is executable. ROB-1089 is preserved as a pushed WIP checkpoint and remains Needs Input pending owner resumption, full acceptance checks, fresh Tester and Oracle diff review. LAB-5 harness repair, Mint security remediation and bounded PTY investigation are merged; full LAB-5 and registered LAB-3 remain unfinished. The current handoff and issue comments contain exact commits, evidence and remaining gates.

Earlier owner authorization permits Lead, consulting Oracle, to prioritize eligible work one candidate at a time and publish reviewed issue branches/PRs/merges; it does not override the latest pause. Resume only on owner instruction. Measurement-host, destructive-action, product-choice, real-model, deployment and release gates remain. No automatic mass promotion or prerequisite waiver.

# Authority and workflow

Linear Elara is the sole current planning/status/decision/handoff source. Experiment registrations, code and evidence stay versioned in the repo. Raw data belongs under lab/results, ignored by default; explicitly selected small evidence/logs and historical review probes have been committed under the owner’s preservation authorization. Unversioned retained owner-host data remains protected. Source import: 03b257159f987e0baf4de9b57f71af156721a5d0. Lab-first remains the owner choice; daily use secondary. Elixir single authority, Rust execution/TUI edges, no NIFs.

Ready means explicitly authorized, not merely dependency-complete. Backlog means unselected (parked/deferred acceptance distinguished in titles); Planning, Building, In Review mean actual activity; Needs Input records owner gate; Done means completed merged work, Canceled deliberate cancellation. Historical imports retain original result dates; Linear creation/completion timestamps are migration timestamps. No new priorities/deadlines imposed.

At most one selected executable lab item; zero while paused. LAB-3 remains Needs Input for its original Mac/evidence gate; LAB-5 remains Needs Input for a future reviewed measurement brief; LAB-9 remains Needs Input for the current owner pause. Owner decision issues do not consume the lab slot. Dependencies are necessary, not sufficient. The future post-LAB-3 direction checkpoint gates LAB-4, while independent work may be selected only after owner resumption and applicable review. Queue discipline lives in Linear, not repository tests.

Lead owns Linear, reads issue/comments before writes and avoids duplicate transitions/comments. Oracle reviews brief and exact candidate range; medium-mode Builder test-first in fresh orb; fresh Tester checks immutable candidate. Never mix roles or transfer unpushed assumptions as if remote code. The owner has explicitly authorized reviewed issue-branch pushes, PRs and merges; the current pause prevents further execution until resumed. Deployment, release and destructive actions are not authorized. After reviewed evidence is committed/pushed under authorization, link commit and update issue Result/status before successor. Done only after confirmed merge. Queue discipline is Lead-reviewed in Linear; hermetic repository pointer tests do not enforce remote scheduling. No routine repository handoff generation.

# Research agenda

## RQ-1 safety/progress (LAB-1, LAB-5)

Faults: abrupt session/provider task/tool task/stub/client/whole VM exit at named turn points. Exclude disk corruption/torn writes/full disks until explicit revision. Safety: accepted input consumed at most once; mutation never reexecutes after callback begins; uncertainty indeterminate; session files openable. Any counterexample refutes. Historical running-mutation counterexample was fixed by LAB-1, not still open.
Within5 seconds after reopening with simulated provider: inputs terminal (turn ended or durable failed receipt) or recoverable (queued/paused and visible in input_status); slots released or indeterminate-held awaiting operator ack. Consumption alone is not terminal. After resume/ack recoverable inputs must terminate; deadline5 seconds + bounded backlog×per-input simulated work (LAB-5 must bound both).

## RQ-2 scale (LAB-3, LAB-7)

Initial workload:20 turns/session; each read4KB +200ms stub command; simulated TTFT300ms,50 deltas/sec about20B each with intended timestamps; history\~200KB; context_limit1,000,000/no handoff, handoff-lineage separate variant; persistence on;10-minute owner-laptop run/hardware recorded. LAB-3 registration resolves incompatible initial values using cycling sessions and5000B answers; do not revert its fixed workload.
Measure intended-emission-to-attached-v2-client arrival (includes simulator scheduling lag), memory=(VM total+stub RSS−idle baseline)/sessions. Hypothesis N500 p95<50ms, memory<5MB (LAB3 registered MiB), throughput tracks intended rate. Exceeding either ceiling or premature throughput flattening refutes. Suspects: per-delta whole-history JSON visibility/budget; full JSONL rewrites; per-dispatch lineage file scans; recorder hashing/fsync; shared Exec GenServer/Port. Suspects are not causal findings.

## RQ-3 isolation (LAB-4, LAB-7)

One subscriber flood, stalled client, crash loop or unlimited-output command; healthy p95≤2×baseline, memory≤1.5×baseline, offender VM growth<256MB, cancel≤1s with independent process-group disappearance evidence. Indeterminate is not cancellation completion. Shared components exceeding bounds refute. More directly tests containment than aggregate throughput, but no claim about BEAM advantage without comparison.

## RQ-4 lifecycle simplification (LAB-8)

One jobs primitive/correlated wake must preserve durable admission, single completion delivery, indeterminate execution loss, bounded cancellation reporting, restart-held capacity. Measure net lines including infrastructure and session special cases; net increase or lost behavior refutes.

## RQ-5 live change (parked, ROB-1099)

Replay gate covers recorded Core facts only; migration gate actually exercises new shell/tools across fault-injected swap. Loss/duplication or divergence missed by both refutes. Wait for RQ-1/4 results.

# Method

Start from refutable hypothesis. Negative result is finding, not failed implementation. Seed repeats choices, not interleavings; report variance. Simulated first; real-model opt-in/capped/separate. One proportional experiment note, raw data outside docs. Preserve coverage before retirement. Elara properties require controlled internal variation or external runtime comparison before crediting BEAM. Uncertain mutations fail closed; workspace bytes prove postcondition, never causal completion. Tools are not OS sandbox or exactly-once external effects.

# Baseline facts (historical 2026-09-26 review; recheck before designs)

12 iterations/turn,30s tool timeout,16KiB output; stub kills group at cap, now indeterminate. Tools sequential. Iteration/time/output configurable through API, kill-at-cap not. Owner80 skills add\~38KB catalog/request; non-Codex fallback128K context conservative byte estimate. Loopback gateway no auth; trusted repository plugins compile with full authority; tools unsandboxed. Codex subscription/Grok OAuth unofficial endpoints/client IDs; no provider-error retries.

# Explicitly not planned (not backlog commitments)

Provider compatibility compiler; convars; embedded Python extensions; TLA+ models; cross-language plugin ABI; any Rust rewrite of session authority.

# Migration boundary

Migration alone granted no measurement, rerun, upgrade, cleanup or product-work authority. Subsequent explicit owner instructions authorized the delivered work recorded in Linear, followed by the current pause. Repository cutover merged in PR #8; it is not pending publication. LAB-3 Mac/raw evidence access remains unverified in the orb; no substitute experiment or evidence deletion is authorized.
