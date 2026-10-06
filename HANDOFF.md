# Handoff — autonomous implementation, 2026-10-06

[Elara in Linear](https://linear.app/robert-guss/project/elara-7ee4b27c1215)
is the sole planning and status source. Read the
[current handoff](https://linear.app/robert-guss/document/current-handoff-autonomous-implementation-569eb39fa4cd)
and current issue descriptions/comments for plans, review, Results and delivery.

## Working arrangement and goal

The active agent performs planning, implementation, review, verification,
commits and delivery in this chat under AGENTS.md and CLAUDE.md. No separate
role workflow, routing script or pane tooling applies. The owner's active goal
is every actionable Linear issue: select and decide autonomously, move genuine
owner questions to Needs Input, and continue independent work. Historical parked
wording alone does not block selection. Keep one executable lab item. Done
requires merge and complete issue acceptance. Do not force-push, deploy, release
or delete retained evidence without a specific owner decision.

## Current work

LAB-8/ROB-1088 remains Building, sole executable lab. Supporting output,
profiles, shared completion and operator chunks PR#54/#55/#57/#58 are merged.
Main b001c3831a298bd9b7a10af25b0df9e6ad1f71ce equals reviewed92e0470;
operator actual exact-head Socket checks passed. Deliveryd4e39bfc/review69a263a8
retain full1021 at frozenf248162, focused41/native118/pointer3, source240-hash
readback, authority/confirmation controls and forced cleanup a2. Operator count
129/49,363,+157 phase/+988 cumulative, negative reduction evidence. ROB-1331
is Done/PR#56. See note008 and retained operator-* artifacts.

Current branch work/rob-1088-final-chaos from b001c38; exact final-phase plan
in commentdc1a9002-91cd-4e6e-97f9-1cb90a4c3cb0. JobRecovery now selects genuine
Jobs tool/run with api:job and mix_test arguments; absent option keeps legacy
workload. Its existing gate records actual tool identity; Matrix requires this
evidence for general rows. Invalid API rejects before resources. Public red0/5
and missing-Matrix-evidence red0/1 turn green focused24, including forced native
failures through both APIs. Compile/format/diff pass. Count129/49,387,+24 phase/
+1,012 cumulative; Session2860 unchanged. Full1030 (11properties,1019tests),
seed1088,304.9s passes at clean aa78b730f8b47ed552262797d9efccefad3c7adb;
all240 before-suite hashes match postflight,0 global/Elara BEAM. Frozen compiled
registration/launch next; no final acceptance or comparative timing claim.

Fresh finite regression namespace lab/results/rob-1088-final-chaos-20261006-a1/:
24 original checkpoints,3 receipt transport,5 general job API,32 distinct seeds
1088700–1088731. Existing MatrixRunner, S2 peers, supervisor3/5, causal/OS/cleanup
checks; stop on failed/ineligible/unconfirmed cleanup. Register exact source/
compiled/native artifacts before launch. Do not edit source, compile or test
while launcher runs. Keep separate from original LAB-5 registered measurement.

After final scripted review/delivery, separately approved capped real-model
awaited-completion acceptance remains. If approval absent, Needs Input and
continue independent backlog. LAB-4/LAB-7 still depend on paused LAB-3 and owner
direction. Do not resume that pause or any human/account gate automatically.
Linear owns latest queue/status/review/check/merge evidence.

## Retained evidence and continuation boundaries

LAB-5 (ROB-1085), LAB-6 (ROB-1086) and receipts ROB-1104 are Done. Their final
merge/review/registration evidence is in Linear and notes005/006/007. LAB-5's
one registered measurement at15e000c is1200/1200 eligible/passed,50×24,
20,350 checks true, seeds1085000–1086199. Preserve its registration,
qualification, launcher, measurement and postflight namespaces. Never rerun
or reuse that namespace, pool other rows into it or relabel regressions as the
original measurement. Manifest bbe689027c60ed364d43f54c7c6cbc3d6aed32bf27e94e038fd0694a74640a41;
summary f92e30959ce5c3a33cccad4e4612957e530755517c9e2b22a6cc7a6c81efdc20.

Preserve every raw namespace under lab/results/, including excluded pilots,
failed controls and later LAB-6/ROB-1104/LAB-8 regressions. Keep original
LAB-5 descendant branch627c5e7 unpushed/failing, historical/archive local branches
and stash@{0} (WIP oncc6e778). See Linear for exact retained paths/source pins.
No source edits, compiles or tests while a measurement launcher is running.

Recheck process ownership before experiments; never stop unrelated processes.
Use pgrep -x beam.smp, then ps/lsof cwd evidence. Explicit Bash launchers must
capture PIPESTATUS immediately; macOS Bash is3.2. Re-derive selection line numbers.
CI runs Socket checks, not mix test; distinguish local evidence. Source IDs in
results are host.commit; squash merges change commit IDs. Preserve intermittent
failure logs and baseline evidence; a rerun alone does not prove a fix.
