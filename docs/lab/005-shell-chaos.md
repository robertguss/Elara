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
- **Status:** harness accepted in PR #9 at `017db4d`; no accepted pilot
  measurement. Attempts 1, 2 and 3 are invalid historical evidence. The
  serialization fix and one re-run of the registered command are authorized by
  the owner on 2026-10-03, with a smoke pre-check. The parent LAB-5 remains
  unfinished.

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

Two invalid sweep attempts exist. They are not one 30-run measurement and
neither is accepted pilot evidence. No further registered or supplementary
measurement was run after attempt 2.

Attempt 1, candidate `b9a9ec0`, is invalid. All 30 children exited 1 before
writing a result line because `Elara.Lab.write_results/2` could not JSON-encode
`Elara.Message.User`. Its directory
`/tmp/elara-lab-1085/session_recovery/20261002T015912688401Z-sweep-fault-seed42`
was deleted before attempt 2. All 30 children errored, zero result records were
written, and the raw evidence is lost. The surviving narrative is
[attempt-1-INVALID-HARNESS.md](../../lab/results/rob-1085/attempt-1-INVALID-HARNESS.md).

Attempt 2, candidate `8a2c2c5`, finished without the required pre-review gate
and was not rerun. Its observer and causal protocol admitted false positives,
so all completion and timing flags in those records are invalid. The original
bytes, including erroneous flags, are retained under
[attempt-2](../../lab/results/rob-1085/attempt-2-8a2c2c5-20261002T020227820148Z)
and governed by the [invalidation manifest](../../lab/results/rob-1085/INVALIDATION.md).

The raw attempt-2 summary reported completed turns and bounded recovery, but
those claims are withdrawn. In particular, all 10 `provider_streaming` records
and all 10 `tool_running` records lack C's non-interrupted terminal assistant
while claiming backlog completion. The harness also injected provider faults
before its claimed barrier and fabricated or omitted death and timing evidence.

### Attempt 3 — registered pilot at f631254 (2026-10-03), invalid

Attempt 3 ran exactly once from a clean tree at `f631254` under `MIX_ENV=dev`:

    MIX_ENV=dev mix elara.lab sweep session_recovery \
      --over fault=provider_started,provider_streaming,tool_running \
      --n 10 --seed 42 \
      --results lab/results

Preflight passed 27 focused `session_recovery` tests, dev compile was clean,
and no BEAM was running. The sweep exited 1 and tee exited 0. All 30 children
exited 1 before writing a result; `repetitions.jsonl` has 30 error-only rows
with reason `missing_result`. Child logs show `Protocol.UndefinedError`,
`JSON.Encoder` not implemented for Tuple, value `{:rule, 0}`. Evidence under
`lab/results/session_recovery/`: `rob-1085-pilot-prelaunch.log`,
`rob-1085-pilot-sweep.out`, and
`20261003T131521458102Z-sweep-fault-seed42/` (`repetitions.jsonl`,
`summary.json`, `logs/`, `results/`, `tmp/`).

The cause is source-traced, oracle-verified by inspection, and still to be
confirmed by the ROB-1085 2/3 regression test.
`lib/elara/provider/simulated.ex:139` creates `{:rule, index}` and line 115
sends it to the collector. `lib/elara/lab.ex:283` keeps raw choices in lists
keyed by simulator id. `lib/elara/lab/scenarios/session_recovery.ex:355` puts
those lists into cleanup, line 1418 puts cleanup into the result, and
`lib/elara/lab.ex:318` JSON-encodes it. The carrier is
`.cleanup.choices[simulator_id][]`.

Attempt 3 produced no serialized scenario-result records and supplies no
accepted pilot measurements of checks, bounds, timings or A outcomes. Retained
session artifacts under the sweep's `tmp/` have not been validated as recovery
evidence. Serialization failed after the scenario returned; those artifacts are
retained but not analyzed or rehabilitated here. The accepted PR #9 harness
JSON round-trip test used a constructed witness, not a rule-matched run through
`write_results/2`.

## Interpretation

Attempt 1 supports no recovery conclusion. Attempt 2 does not establish
completed B/C turns, bounded recovery, bounded backlog, the registered causal
protocol, or accepted reproduction of the registered finding.

The only retained scientific observation is narrower: marker records contain
A's input receipt `"session restarted"` and the associated persisted typed tool
outcome `{:error, "interrupted"}`. This is a negative against causal
indeterminacy. It is not evidence of correct protocol execution or completed,
bounded backlog recovery.

## Changes

Registration `328de9c`, original scenario `b9a9ec0`, serialization repair
`8a2c2c5`, and corrected harness in ROB-1085. The correction changes only lab
observation/orchestration and historical interpretation; it does not change
runtime recovery behavior and adds no replacement measurement records.
ROB-1085 2/3 is planned to fix and test the rule-choice serialization path
before any replacement measurement.

## Limits and next

The original pilot remains incomplete and this is not full LAB-5. The future
matrix still includes children, handoff, jobs, client, worker, stub, whole-VM
and process-group faults, and schedules of at least 1000 runs. A future pilot
requires a separately reviewed measurement brief and explicit authorization.
ROB-1085 3/3 is the authorized single re-run of the registered command, after
the fix and smoke pre-check.
