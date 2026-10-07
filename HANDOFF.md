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

ROB-1335 chat multiline-paste repair is merged in PR #63. Owner Mac/WezTerm
retest passed, including typed `/quit`. The delivered verification was 1050
passed (11 properties), plus compile/format checks and scripted PTY coverage.
ROB-1107/1108 are now Done after owner TUI interaction and visual acceptance:
editing, navigation, tool viewer/search/copy, appearance, smaller-window use,
and saved defaults after reopening. Three layouts and four themes were sampled,
not every combination. Read Linear for exact evidence and limits; no broad
daily-driver or LAB-8 acceptance is implied.

ROB-1098 now implements the registered context-cutoff slice: versioned shell
observations and `Elara.FlightRecorder.ContextCensus.compare/2`. Live policy is
unchanged. The census holds accounting fixed and stops each conditional segment
prefix at its first divergence/gap; legacy recordings are unsupported. It does
not infer outcome quality, successful handoffs, savings or continuity across
rebase/restart. No provider-private state or wake-policy capture was added.

Full suite: 1061 passed (11 properties); focused: 77 passed (11 properties).
Compile/format/source-doc diff checks passed. Oracle's fresh-VM atom and malformed
coverage findings were reproduced red and fixed; follow-up found no blockers.
Read `docs/lab/009-context-cutoff-census.md` and ROB-1098 for registration,
review and delivery state. Raw logs, including rejected preparations, remain in
`lab/results/rob-1098-context-cutoff-20261007/`. No production corpus was evaluated
and no preferred cutoff selected. Future corpus use needs fresh observations;
do not backfill missing facts or resume broader policy work automatically.

LAB-3 remains unfinished and paused on its original owner-host protocol.
LAB-8 scripted delivery is merged, but capped real-model acceptance remains
Needs Input. ROB-1106 remains the Backlog daily-driver umbrella.
No account-backed run, paused measurement, deployment or evidence disposal
is authorized by the direction change. Preserve every raw namespace under
`lab/results/`, original measurements, failed/excluded controls, historical
branches and stash; Linear retains their exact pins and boundaries.

The active agent owns implementation and review in the current session.
Keep at most one executable lab item. Done requires merged acceptance.
Standing authorization covers reviewed issue-branch push/PR/merge after
required checks, not force-push, deployment, release or evidence deletion.
