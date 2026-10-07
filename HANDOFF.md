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

ROB-1332 workspace selection and ROB-1334 shipping practice workspace are merged
in PRs #61/#62. The owner completed both practice tasks on Mac/WezTerm with
configured Codex `gpt-5.5`/`low`: chat passed two tests/format/discount checks;
TUI passed three tests/format/quote checks. Those reports are recorded in
ROB-1106/1107, not a blanket acceptance of all TUI interactions or LAB-8.
The earlier TUI Enter concern was withdrawn; its cause remains unconfirmed.

ROB-1335 fixes the confirmed chat multiline-paste split on
`work/rob-1335-chat-paste`. Bracketed paste accumulates one literal draft until
Enter, preserving typed command boundaries. Normal exit restores tty flags and
stops the reader. A real scripted-provider PTY test verifies Unicode, blank
lines, pasted slash text, no premature submission, typed `/quit`, and restoration
with echoctl initially on/off. Prompt examples are copyable text blocks.
Fresh full suite: 1050 passed (11 properties); compile warnings-as-errors,
format and diff checks passed. Read ROB-1335 for authoritative delivery evidence.
Mac/WezTerm retest of this fix remains pending; no model calls were made by
the agent. Pipes/terminals without bracketed paste remain line-oriented.

ROB-1098 stays Backlog until fresh use and sufficient recorded policy facts
justify a bounded divergence census; replay cannot establish outcome quality
beyond the first divergence. Do not start another lab driver by default.

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
