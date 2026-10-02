# 005 — Bounded session recovery pilot

- **Question:** RQ-1 / LAB-5 first candidate. After one accepted input is
  faulted at a named point, do two positively witnessed queued inputs drain
  with stable identities, or does recovery misclassify a started mutation?
- **Hypothesis:** provider-task deaths settle A as failed and then complete B
  and C once each. An ordinary direct `lab_marker` death, reopened with
  `effect_executor: nil`, currently inserts an `interrupted` error instead of
  leaving the started mutation indeterminate. That second claim is a predicted
  finding, not a pass condition and not a runtime fix.
- **Queue item:** LAB-5 · **Date:** 2026-10-02 · **Base:** `ca01d8a8`
- **Status:** registered before implementation and before the 30-run pilot.
  This note does not claim the pilot has been run.

## Method

Scenario `session_recovery` (`Elara.Lab.Scenarios.SessionRecovery`), simulated
provider only. It reuses `Elara.Lab.Faults`, `Elara.Provider.Simulated` and
`Elara.Lab.Sweep`. No real-model requests and no LAB-3 measurement.

The registered path is the ordinary direct tool path: `Tools.marker/0` with
`effect_executor: nil` (and therefore `effect_executor_explicit?: false`). The
marker writes its label, then reaches `:tool_running`. There is no explicit
executor, no sidecar, and no new recovery seam.

Exactly three unique normal inputs, A, B and C. The selected hook is gated in
the calling task: the scenario witnesses arrival, confirms B and C are queued,
then releases the one-shot injection. A repeated request key must not inject
again. Provider cases kill the first answer task at `:provider_started` or
after the first delta at `:provider_streaming`. The marker case kills the
session after A writes and before the marker hook can return; the old session
must be DOWN before reopen. Reopen uses `pause_inputs: true` and a distinct
deterministic simulator id. No new normal input is submitted while paused. B
and C are resumed explicitly.

Stable logical labels are `A`, `B` and `C`. Accepted input ids, the
corresponding user-message and call-result identities, and physical label
counts are evidence. `consumed` is not terminal: each input needs a settled
persisted receipt, settled history, and a cleared `active_input_id`. Events
are wakeups only. Marker bytes are not causal completion proof. A started
mutation whose receipt is missing must stay indeterminate.

Timing bounds, measured from the named origin:

- provider target DOWN to A settled failed: 5 s;
- session immediately before reopen to responsive paused recovery status: 5 s;
- backlog completion from explicit resume (session) or target DOWN (provider
  automatic drain): 5 s plus observed backlog count times 1 s.

Fixed scripted input work is at most 2 provider requests, TTFT 10 ms, 2 answer
deltas at 10 ms, and one local marker. The 1 s term is a simulated-work
allowance, not a claim that the scripted work takes 1 s. Deadlines are
scenario-local monitored probes. Cleanup is bounded and includes tasks the
scenario owns. A timeout is a structured failure. Cleanup is not reported
confirmed if anything owned is still unsettled. The runner's retention rule
stands: an unconfirmed VM is not reused.

Sweep schedule, committed before any pilot run:

    MIX_ENV=dev mix elara.lab sweep session_recovery \
      --over fault=provider_started,provider_streaming,tool_running \
      --n 10 --seed 42 \
      --results lab/results

That is the cross product of those three faults with seeds 42 through 51:
30 runs, one fresh OS process each. Dev restart intensity is the production
default of 3; the test config's 100 is not the measurement environment.
Registration and implementation must be committed clean before this command
runs, and it is not rerun toward a green summary.

## Results

Not yet run. The pilot retains raw `repetitions.jsonl` lines, including the
schedule, witnessed firing and death, accepted ids, receipts, history-count
evidence, marker counts, timing origins and measurements. Success directories
are deleted, so paths alone are not evidence. Custom curve fields are
`recovery_ms`, `backlog_ms` and `marker_count`.

## Interpretation

Not yet available. A reproduced interrupted marker receipt refutes the strong
recovery claim and is reported as a finding. It does not authorize a runtime
change or a weaker observer.

## Changes

None yet. This registration is the method commit.

## Limits and next

This pilot is not full LAB-5. The future matrix still includes children,
handoff, jobs, client, worker, stub, whole-VM and process-group faults, and
schedules of at least 1000 runs. Those are out of scope here.
