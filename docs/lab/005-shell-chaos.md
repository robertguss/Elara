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
- **Status:** registered, implemented, and measured twice. Attempt 1 is an
  invalid harness failure. Attempt 2 is the only recovery measurement and was
  not rerun. Parent LAB-5 remains unfinished.

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

Two sweep attempts exist. They are not one 30-run measurement. Attempt 1 is an
invalid harness failure and must not be replaced by attempt 2. No further
registered or supplementary measurement was run after attempt 2.

Attempt 1, candidate `b9a9ec0`, is invalid. All 30 children exited 1 before
writing a result line because `Elara.Lab.write_results/2` could not JSON-encode
`Elara.Message.User`. Its directory
`/tmp/elara-lab-1085/session_recovery/20261002T015912688401Z-sweep-fault-seed42`
was deleted before attempt 2. The retained record is
[attempt-1-INVALID-HARNESS.md](evidence/rob-1085/attempt-1-INVALID-HARNESS.md).

Attempt 2, candidate `8a2c2c5`, finished and was not rerun. Raw files are in
[attempt-2](evidence/rob-1085/attempt-2-8a2c2c5-20261002T020227820148Z). Mix
exited non-zero because `tool_running` failed `indeterminate_without_receipt`
in 10/10 seeds. That is the registered finding, not a harness pass.

| Fault | Present | Exit | Failed check | Recovery ms | Backlog ms | Marker count |
| ----- | ------- | ---- | ------------ | ----------- | ---------- | ------------ |
| `provider_started` | 10/10 | 0 | none | 0–1 | 0–1 | 2 |
| `provider_streaming` | 10/10 | 0 | none | 27–41 | 99–108 | 2 |
| `tool_running` | 10/10 | 1 | `indeterminate_without_receipt` 10/10 | 7–12 | 68–73 | 3 |

Every `tool_running` receipt for A was `%{state: failed, error: "session restarted"}`.
B and C were consumed, with labels and bytes `A`, `B`, `C`. Provider A errors
were the provider-task crash. Bounds `recovery` and `backlog` aggregated
`holds` at every value; the sweep still failed because the check failed.

## Interpretation

The predicted finding is reproduced on attempt 2: ordinary direct-marker reopen
inserts `session restarted` rather than leaving the started mutation
indeterminate. Provider-task deaths in that same attempt settled A failed and
completed B and C inside the registered bounds. Attempt 1 shows nothing about
recovery.

The following observer seams are recorded for review and were not patched
after the Lead named them:

- `await_provider_death/2` discards `_death` and returns `down: true` after a
  firing is received.
- `provider_hook/3` is not itself gated on the witnessed backlog.
- `Elara.status/1` and `Elara.start_session/1` use the 5-second GenServer call
  default, so a probe can consume the registered deadline.
- `user_message_id` is copied from the accepted id rather than read from a
  persisted user-message identity.

Those seams are not a runtime fix and were not patched in this handoff.

## Changes

Registration `328de9c`, scenario `b9a9ec0`, JSON encoding `8a2c2c5`. No runtime
recovery change. The handoff commit records both sweep attempts and the
unpatched review seams.

## Limits and next

This pilot is not full LAB-5. The future matrix still includes children,
handoff, jobs, client, worker, stub, whole-VM and process-group faults, and
schedules of at least 1000 runs. Those are out of scope here.
