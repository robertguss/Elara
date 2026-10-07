# Handoff — balanced research and daily use, 2026-10-07

[Elara in Linear](https://linear.app/robert-guss/project/elara-7ee4b27c1215)
is the sole planning and status source. Read the
[current handoff](https://linear.app/robert-guss/document/current-handoff-autonomous-implementation-569eb39fa4cd)
and issue descriptions/comments for queue, acceptance, review and delivery.

The owner explicitly chose balanced research and daily-use improvements.
ROB-1091 records that decision. The full 49-issue audit and oracle consultation
are recorded in the project discussion and
[this thread](https://ampcode.com/threads/T-01a1165f-98bc-759f-9d6a-1c07e4b6cbad).
Historical measurements remain source/host-specific; this audit did not rerun them.

ROB-1334 supplies `examples/shipping/README.md`: the owner requested a prepared
workspace rather than selecting another repository. The dependency-free baseline
and Mac copy/launch guide leave chat discount and TUI quote exercises unfinished.
Baseline test/format/compile and documented shell syntax passed in the orb;
acceptance values were checked against an in-memory reference, not a model run.
Read ROB-1334 in Linear for delivery evidence. Owner dogfooding remains pending;
the suggested five-minute stop rule is manual, not an enforced spend cap.

ROB-1332, a bounded CLI `--cwd` slice under ROB-1106, is implemented on
`work/rob-1332-cli-cwd` from merged PR #60. Scripted public startup tests cover
target tools, instructions, skills, plugin trust and chat history; native tests
cover creation/listing/saved reopen, live-ID authority and tilde parity.
Fresh `mix test` passed 1044 (11 properties), native tests passed 119,
compile-with-warnings-as-errors, format and Clippy passed. An earlier full run
failed the unchanged connection-sampler test; its focused rerun and the fresh
full suite passed without changing sampler code. Oracle's tilde finding was
fixed and re-reviewed. Read ROB-1332 for authoritative PR/check/merge evidence.
Next is bounded use on another disposable repository, not another lab driver;
real-model and owner-terminal acceptance are not implied by scripted tests.
ROB-1098 is Backlog, not blocked on the prior stop-for-day; reconsider its
recorded-input replay experiment after fresh use and sufficient recorded facts.

LAB-3 remains unfinished and paused on its original owner-host protocol.
LAB-8 scripted delivery is merged, but capped real-model acceptance remains
Needs Input. ROB-1107/1108 retain owner hands-on/physical-terminal gates.
No account-backed run, paused measurement, deployment or evidence disposal
is authorized by the direction change. Preserve every raw namespace under
`lab/results/`, original measurements, failed/excluded controls, historical
branches and stash; Linear retains their exact pins and boundaries.

The active agent owns implementation and review in the current session.
Keep at most one executable lab item. Done requires merged acceptance.
Standing authorization covers reviewed issue-branch push/PR/merge after
required checks, not force-push, deployment, release or evidence deletion.
