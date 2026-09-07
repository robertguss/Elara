# Supervised focused test jobs

JOB-1 in [ROADMAP.md](../ROADMAP.md) owns implementation status.
This is the bounded contract authorized after the
[harness experiments](harness-experiments.md).

## Interface and lifetime

The local `test_job` tool takes `action` (`start`, `status`, or `cancel`)
and a stable `job_id`. Start also requires one relative `target`, an existing
`test/*_test.exs` file optionally followed by a positive line number.
It executes `mix test TARGET` in the session's working directory, with a
60-second deadline and 16 KiB output cap. No arbitrary command or extra flags.
Tests are trusted code and may mutate files; the tool requires shell and
filesystem-read capabilities.

Start requires a persistent session. Admission reserves at most one job per logical session and
four globally, including uncertain jobs whose execution has not settled. Repeating the same ID/target returns its existing record,
even if source has since changed; a different target conflicts. A new ID is an
explicit new execution. Admission occurs when durable intent is written. Requests
still queued after their caller stops are rejected; after admission the job
intentionally outlives its tool call. If a tool call times out near admission,
inspect the same job ID before deciding whether anything started. Status and cancellation are scoped to the owning
session, including its handoff lineage.

For example, ask the agent to start this tool call and end its turn waiting:

```json
{"action":"start","job_id":"parser-check-1","target":"test/parser_test.exs:24"}
```

On completion, inspect the same identity with
`{"action":"status","job_id":"parser-check-1"}`. To stop execution, use
`{"action":"cancel","job_id":"parser-check-1"}`. A repeated start with that
ID retrieves the earlier job; use a new ID for an intentional test rerun.
Tool results and completion evidence appear in ordinary session history/TUI.

The job outlives the initiating tool call. After start, finish the current turn
and wait for the completion inbox input. No model calls are needed to poll.
Other sessions remain usable. Cancelling requests process-group termination
through the existing Rust stub and retains its terminal response. Cancellation
races may finish normally; missing terminal evidence is indeterminate.

## Evidence and delivery

Persist intent before execution, and terminal evidence before delivery. Retain
job identity, target, working directory, source fingerprints, bounded output,
exit code/signal and termination reason. Do not restart commands after runner,
manager, or VM loss. A prepared record recovered before dispatch becomes not_started. A dispatched
record recovered without terminal evidence becomes indeterminate; a surviving
terminal record is redelivered without executing.

An indeterminate job retains its reservation while its runner or process-group
cleanup is outstanding. The execution manager checks the saved runner identity
within the same execution epoch before releasing it. Losing that epoch leaves
`slot: "held"` and `settlement: "unknown"`, preventing overlapping replacement
jobs. Status exposes this condition. After independently confirming that the
old command and descendants have stopped, an operator can call
`Elara.TestJobs.acknowledge_stopped(session_id, job_id)` from IEx. This releases
the reservation, records `operator_confirmed`, and leaves the result
indeterminate. It cannot override execution known to be pending, is not a
model-facing tool action, and never retries the command.

Use one stable inbox ID and non-owner evidence provenance. Duplicate acceptance
does not create another input. Paused input remains paused, existing wake budgets
apply, and an offline recipient receives the evidence after explicit reopen.
Do not resurrect stopped sessions. Ordinary session interrupt pauses input;
explicit job cancellation separately stops the background command.

Inbox acceptance, input consumption, and successful model completion are
different milestones. A completion input becomes `consumed` when inference
starts. If that provider turn fails, the input becomes `failed` and retains its
error; the job's execution result stays separate.

| Failure or pause boundary | What happens next |
| --- | --- |
| Provider fails while the job is still running | A later completion can start a new turn automatically if the session stays attached, idle and unpaused, within its wake budget |
| Provider fails while interpreting a completion | The input retains `failed` status; reopening or `resume_inputs` does not retry it; explicitly continue the session using its retained evidence |
| User pauses before completion | Evidence remains queued/accepted until explicit resume; provider failure does not override the pause |

Use `Elara.input_status/2` to inspect an input's state and error. An explicit
continuation starts a new owner turn; it does not rewrite the earlier failed
input as successful. A new job ID requests another command execution and is
unnecessary when only interpretation needs to continue. The
[recovery experiment](harness-experiments.md) verifies these boundaries. Drivers
should stay subscribed after a provider error when job completion is still
pending so the later result can drive a new turn.

Source identity covers Mix files and project lib/config/test contents, excluding
generated build/dependency directories. Capture before and after execution and
compare again on status. Changed or unreadable source is visibly stale/unknown.
These are observations, not a filesystem snapshot: transient changes, external
services and dependencies outside the captured set are not proven unchanged.
A later completion input must direct the agent to check current status before
claiming the current source passes.

Records live under the session-store root's `_test_jobs/` directory. They are
private JSON files containing bounded output; automatic retention/pruning is not
implemented. Startup/recovery validates saved records and indexes only pending
delivery and held reservations; periodic retries do not rescan all history.
A separate supervised delivery task handles slow inbox recipients so they cannot
block the manager from admitting or cancelling other jobs. Accepted inbox IDs
remain stable across delivery-task or manager restarts.
Malformed records block new-job admission without crashing the manager. Inspect
and repair or archive the affected `_test_jobs/*.json` file, then restart
`Elara.TestJobs` to reload the index. Preserve uncertain execution records until
their commands have independently been confirmed stopped. Store-root changes
are not supported during active execution. `source_changed_now` is `true`, `false`, or `"unknown"`. A command
exit is retained even when its source is stale; a passing old result does not
become a pass for a changed workspace. Recorded statuses distinguish passed,
failed, cancelled, timed_out, truncated, not_started and indeterminate.

## Acceptance and checks

Use ExUnit with real Mix fixtures and the public session path. Prove start →
idle wait → one completion input, no polling inference, deduplication, another
usable session, paused/offline delivery, explicit cancellation, crash without
retry, and changed-source evidence. Re-run `mix test`, `mix format
--check-formatted`, and `mix compile --warnings-as-errors`; compare known
baseline failures rather than hiding them. Record one live-model exercise
separately from deterministic regression checks.

Implementation belongs in the supervised `Elara.TestJobs` owner, with source
identity isolated in its workspace helper and durable schema in its record helper. Reuse `Elara.Exec` for processes and
`Elara.submit_input/2` for delivery. The session reducer, Rust protocol, and
generic effect-recovery guarantees do not need a replacement. No cron, remote
jobs, automatic command replay, new UI framework, or dedicated eval framework.
