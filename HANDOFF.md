# Handoff — autonomous implementation, 2026-10-06

[Elara in Linear](https://linear.app/robert-guss/project/elara-7ee4b27c1215)
is the sole planning and status source. Read the
[current handoff](https://linear.app/robert-guss/document/current-handoff-lab-3-attribution-and-continuation-569eb39fa4cd)
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

LAB-8/ROB-1088 remains Building, the sole executable lab. Output/profile chunks
PR#54/#55 are merged; shared completion is preserved on
work/rob-1088-correlated-completion atc430c1e5346e008dfd0ac9ccc7dd4f5542c824f2.
Runtime repair86a5c33 restores immediate admission and skips already typed
transports while preserving legacy upgrades. Focused134 at68b0356 and repaired
19/19 public checks pass; count129 files/49,206 lines, +466 this chunk/+831
cumulative, negative reduction evidence. Fulla2 passed1019/1020: completion
checks passed, but the attachment PTY oversize-error visibility test failed.

ROB-1331 is the current technical prerequisite on
work/rob-1331-attachment-error-wait from3024e6b. Reuse the existing eight-second
wait_for for the actual visible oversize error; one fixture line changes.
An owned1.2-second PTY pause fails the old fixed redraw0/1 and passes the repair
1/1; both witnesses confirm child reap, stopped timer, closed master/observer.
Temporary diagnostic source is restored; ordinary product1/1 (10.2s), Python
syntax and diff checks pass. Raw attachment-* and completion-*
logs/control snapshots remain in lab/results/rob-1088-general-jobs-20261006/.
Linear holds exact review/delivery; do not infer full completion acceptance.

After delivering this prerequisite, merge main into the preserved unpushed
completion branch, recheck source identity, run the full suite, review and
SHA-pin that supporting PR. Keep LAB-8 Building; then operator server/TUI
acknowledgment, fresh final chaos/net-line comparison and separately approved
capped real-model gate remain. If that approval is still missing after
independent work, set Needs Input and continue other actionable issues.
Do not resume paused LAB-3 or reuse original registered corpus namespaces.

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
