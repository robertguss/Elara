# Handoff — TUI-first daily use, 2026-10-08

[Elara in Linear](https://linear.app/robert-guss/project/elara-7ee4b27c1215)
is the sole planning and status source. Read the
[current handoff](https://linear.app/robert-guss/document/current-handoff-autonomous-implementation-569eb39fa4cd)
and issue descriptions/comments for queue, acceptance, review and delivery.

The owner clarified that the TUI is the primary interactive product. Preserve
the Elixir API/one-shot use and existing chat compatibility; new interactive
work targets the TUI. ROB-1341 under ROB-1106 delivers the bounded source-backed
`bin/elara` launcher. Bare `elara` starts a new session in caller cwd, not an
automatic resume; explicit list/session targets and `--cwd` remain supported.
README documents PATH setup. This is not a standalone package or installer.

Launcher configuration/builds stay in Elara's checkout; application startup and
relative credential/UI paths use caller cwd. Native argument preflight replaces
the duplicate Mix parser. Oracle identified a project-override leak into tool
commands; the wrapper now clears `MIX_EXS` rather than exporting Elara's path.
Subprocess checks cover project isolation, build confinement, saved reopening,
Codex model/effort forwarding with fake credentials, option-like prompts, and
live-session workspace authority. The scripted PTY exercises multiline editing,
resize, stop/queue/resume, and clean Ctrl-C exit through the launcher; existing
native Esc coverage remains. Read ROB-1341 for final test/review/merge evidence.
Linux PTY verification is not Mac/WezTerm/Herdr launcher acceptance. No real
provider calls were made, and no new Mac acceptance has been reported.

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

ROB-1098 verification: 1061 passed (11 properties); focused: 77 passed (11 properties).
Compile/format/source-doc diff checks passed. Oracle's fresh-VM atom and malformed
coverage findings were reproduced red and fixed; follow-up found no blockers.
Read `docs/lab/009-context-cutoff-census.md` and ROB-1098 for registration,
review and delivery state. Raw logs, including rejected preparations, remain in
`lab/results/rob-1098-context-cutoff-20261007/`. No production corpus was evaluated
and no preferred cutoff selected. Future corpus use needs fresh observations;
do not backfill missing facts or resume broader policy work automatically.

ROB-1342 adds the read-only `grep` and `glob` workspace search tools under
ROB-1106, so daily navigation no longer needs the unsandboxed `bash` tool. Both
delegate to ripgrep through the existing `Elara.Exec` argv path and are rooted at
the session cwd ROB-1332 made authoritative. A missing `rg` is one actionable
error, not a second Elixir ignore engine that could answer differently per host.
Results are sorted, capped and labelled when truncated; nothing mutates, so an
incomplete search is an error, never `indeterminate`. Read ROB-1342 and PR #67
for the plan, review and delivery state. The verify-elara harness now drives
these tools, with evidence under
`.cursor/skills/verify-elara/artifacts/tools/20261008-115317-57598/`. Linux
scripted drives are not Mac/WezTerm acceptance, and no real-model run was made.

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
