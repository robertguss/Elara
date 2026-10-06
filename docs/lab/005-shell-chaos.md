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
- **Status:** harness accepted in PR #9 at `017db4d`; serialization repaired
  in ROB-1231 (`c82a17f`). Attempts 1, 2 and 3 are invalid historical evidence.
  Attempt 4, the registered pilot at `c82a17f` (2026-10-03), is valid: claim 1
  held in 20/20 provider runs and the predicted finding held in 10/10 marker
  runs. The parent LAB-5 remains unfinished.

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

### Addendum — smoke pre-check (2026-10-03, ROB-1085 option c)

Added after attempt 3; the registration above is unchanged. The owner chose
option (c) on 2026-10-03 (ROB-1085 comments): repair result serialization, run
one smoke child per fault, then run the registered command once more. Before
that run, exactly once:

    MIX_ENV=dev mix elara.lab sweep session_recovery \
      --over fault=provider_started,provider_streaming,tool_running \
      --n 1 --seed 42 \
      --results lab/results/rob-1085-smoke

Its three pairs are each fault at seed 42. Output is retained under
`lab/results/rob-1085-smoke/session_recovery/<stamp>-sweep-fault-seed42/`. It
is excluded from the pilot and never counted or reported as pilot evidence.

Launch criterion for the registered run: exactly those three pairs are present.
Each is a scenario result row, not an error-only row, decodes as JSON, and has
`.host.commit` equal to the full run SHA and `.host.dirty` false. Malformed or
error-only rows, or evidence that cannot be trusted, block the launch. Exit
status and checks are not criteria: the predicted `tool_running` finding fails
a check, so the sweep exits non-zero. Smoke and pilot run at the same merged
revision with no tracked edits between them. The smoke is not retried without
further owner authorization.

## Results

Two invalid sweep attempts exist. They are not one 30-run measurement and
neither is accepted pilot evidence. No further registered or supplementary
measurement was run after attempt 2.
(2026-10-03: this paragraph predates attempts 3 and 4 below.)

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

### Attempt 4 — registered pilot at c82a17f (2026-10-03)

The accepted PR #9 harness plus the ROB-1231 result-boundary repair
(`finalize/1`: host provenance and JSON-safe conversion; checks, bounds and
recovery/backlog timing unchanged), run against runtime revision `c82a17f`. It
is not a runtime identical to PR #9's. The smoke pre-check met its launch
criterion (3 result rows, provenance `c82a17f`/clean, no error rows); it is not
pilot evidence. The registered command then ran once, from a clean tree at
`c82a17f` under `MIX_ENV=dev`. The sweep exited 1 and tee exited 0. All 30 lines
are scenario results with `.host.commit` `c82a17f…` and `.host.dirty` false,
and cover each fault at seeds 42–51 once.

| Fault                | Runs | Exit ≠ 0 | Complete | Cleanup | Retained | Evidence | Recovery / backlog bound | `recovery_ms` n, min/med/max | `backlog_ms` n, min/med/max | Markers | Failed checks                       |
| -------------------- | ---- | -------- | -------- | ------- | -------- | -------- | ------------------------ | ---------------------------- | --------------------------- | ------- | ----------------------------------- |
| `provider_started`   | 10   | 0        | 10       | 10      | 0        | 0        | 10 / 10 holds            | 10, 16/27/40                 | 10, 104/232/294             | 2 ×10   | none                                |
| `provider_streaming` | 10   | 0        | 10       | 10      | 0        | 0        | 10 / 10 holds            | 10, 16/17/28                 | 10, 104/133.5/279           | 2 ×10   | none                                |
| `tool_running`       | 10   | 10       | 10       | 10      | 0        | 10       | 10 / 10 holds            | 10, 13/14/44                 | 10, 102/171/266             | 3 ×10   | `indeterminate_without_receipt` ×10 |

Fields: `.sweep.exit_status`, `.complete`, `.cleanup.confirmed`, presence of
`.retained_dir` and `.evidence_dir`, `.bounds`, `.recovery_ms`, `.backlog_ms`,
`.marker_count` (every row complete, so no placeholder counts), and `.checks`.
Bounds: recovery 5 s; backlog 5 s plus 2 × 1 s.

| Fault                | A receipt (`.recovery.receipts.A`)  | A tool outcome (`.recovery.tool_outcomes.A`) | A history after its user entry            | B, C                         |
| -------------------- | ----------------------------------- | -------------------------------------------- | ----------------------------------------- | ---------------------------- |
| `provider_started`   | `failed`, provider crash ×10        | unobserved (null) ×10                        | none ×10                                  | settled ×10, markers B, C    |
| `provider_streaming` | `failed`, provider crash ×10        | unobserved (null) ×10                        | none ×10                                  | settled ×10, markers B, C    |
| `tool_running`       | `failed`, `"session restarted"` ×10 | `error`, `"interrupted"` ×10                 | tool call, then error `"interrupted"` ×10 | settled ×10, markers A, B, C |

"Provider crash" is the receipt error `{:provider_error, %Elara.Provider.Error{kind:
:crash, message: "provider task crashed: :killed"}}` (status nil).
"Settled" means the observer's composite rule held: a `consumed` receipt with no
error, history identity, and a cleared `active_input_id` (`.checks`). `.death`
matched with reason `killed` in all 30 rows; `completed_turns` is 2 in all 30.

Representative single-case reproduction: (`tool_running`,
`indeterminate_without_receipt`), seed 42. Pilot evidence is kept in the
sweep's `tmp/2-tool_running-seed42/`. One re-run, outside the measurement,
reproduced the same failed check, receipt and outcome at `c82a17f`/clean:

    MIX_ENV=dev mix elara.lab run session_recovery --n 1 --seed 42 --set fault=tool_running --results lab/results/session_recovery/rob-1232-repro-tool_running-42

Evidence under `lab/results/session_recovery/`:
`20261003T141414704662Z-sweep-fault-seed42/` (with `report.tsv`,
`points.tsv`), `rob-1232-prelaunch.log`, `rob-1232-pilot-sweep.out`,
`rob-1232-smoke.out` and `rob-1232-repro-tool_running-42/`. The smoke is under
`lab/results/rob-1085-smoke/session_recovery/20261003T141357242701Z-sweep-fault-seed42/`.

### Fix verification (ROB-1235, 2026-10-03)

This is not a LAB-5 measurement and is not counted. ROB-1235 changed restart repair so that, on reopen, the first unresolved call (the only one that can have started) is a typed `indeterminate` whenever its arguments parsed; later unresolved calls stay `error` "interrupted", and every repair is persisted in one save. The unchanged registered workload then ran once from a clean tree at the fix commit `c8678b64ca47b317458ca9b9f8d8715d42114a31` (PR #24's fix commit), on 2026-10-03 at 17:32:54–17:33:20Z:

    MIX_ENV=dev mix elara.lab sweep session_recovery \
      --over fault=provider_started,provider_streaming,tool_running \
      --n 10 --seed 42 --results lab/results/rob-1235

The sweep and tee both exited 0. All 30 lines carry `host.commit` `c8678b6…` and `host.dirty` false, and are `complete` with every check true. The 20 provider-fault rows settled A `failed` with the provider-crash error and no tool outcome, as in attempt 4. In all 10 `tool_running` rows, A's receipt is still `failed` "session restarted", but A's marker outcome is now `indeterminate` ("session restarted while this call may have been running; its outcome is unknown and it may have partially changed the workspace"), so `indeterminate_without_receipt` holds 10/10. Recovery took at most 46 ms and backlog completion at most 366 ms, so both bounds held. Evidence: `lab/results/rob-1235/` (`rob-1235-prelaunch.log`, `rob-1235-sweep.out`, `session_recovery/20261003T173255392112Z-sweep-fault-seed42/`).

Limits: one seeded sweep with a simulated provider, on the ordinary direct path only (`effect_executor: nil`). It says nothing about the rest of the LAB-5 matrix, about real providers, or about exactly-once effects. Indeterminate is deliberately conservative: a read-only call cut off by a restart is also reported indeterminate, because the reopened session's tool set cannot prove what the call was. A death while executor-backed recovery is still writing its results can make a never-started call indeterminate on a later reopen (docs/sessions.md).

## Interpretation

Attempt 1 supports no recovery conclusion. Attempt 2 does not establish
completed B/C turns, bounded recovery, bounded backlog, the registered causal
protocol, or accepted reproduction of the registered finding.

The only retained scientific observation is narrower: marker records contain
A's input receipt `"session restarted"` and the associated persisted typed tool
outcome `{:error, "interrupted"}`. This is a negative against causal
indeterminacy. It is not evidence of correct protocol execution or completed,
bounded backlog recovery.
(2026-10-03: the two paragraphs above predate attempt 4.)

Attempt 4, claim 1: supported. In all 20 provider-fault runs, A settled
`failed` with a provider-crash error and no persisted assistant or tool
history, then B and C each settled once with exactly one marker each, inside
both bounds (recovery at most 40 ms, backlog at most 294 ms).

Attempt 4, claim 2: the predicted finding held in 10/10. The witnessed
`tool_running` hook occurs after A's marker write, and A's bytes are also
present. Recovery with `effect_executor: nil` nevertheless recorded A's receipt as `failed` "session restarted" and its typed tool outcome
as `error` "interrupted". It was not left indeterminate. This is against the
fail-closed rule for uncertain mutations. The marker bytes do not prove
completion, so the honest classification was indeterminate. Recovery itself
was bounded, and B and C still settled.

The pilot does not show: behaviour under the rest of the LAB-5 fault matrix
(children, handoff, jobs, client, worker, stub, whole VM, process groups);
choice-schedule variation (see Limits); behaviour under an explicit effect
executor; or anything about real providers.

## Changes

Registration `328de9c`, original scenario `b9a9ec0`, serialization repair
`8a2c2c5`, and corrected harness in ROB-1085. The correction changes only lab
observation/orchestration and historical interpretation; it does not change
runtime recovery behavior and adds no replacement measurement records.
ROB-1085 2/3 is planned to fix and test the rule-choice serialization path
before any replacement measurement.
ROB-1231 makes session_recovery result lines JSON-safe at the scenario's result
boundary, after every digest is computed, and adds per-line `host` provenance
(`commit`, `dirty`). Checks, bounds and recovery/backlog timing measurements
are unchanged; the runner's `elapsed_ms` now includes host collection and
conversion.

## Limits and next

The original pilot remains incomplete and this is not full LAB-5. The future
matrix still includes children, handoff, jobs, client, worker, stub, whole-VM
and process-group faults, and schedules of at least 1000 runs. A future pilot
requires a separately reviewed measurement brief and explicit authorization.
ROB-1085 3/3 is the authorized single re-run of the registered command, after
the fix and smoke pre-check.
(2026-10-03: the paragraph above predates attempt 4, which completed the
original 30-run pilot. Full LAB-5 is still unfinished.)

Attempt 4 limits:
- One run per fault and seed, with no variance isolation.
- Each fault produced the same recorded choice-category sequence across seeds
  42–51, but seeded answer text differed. These runs repeat the same
  fault/workload structure without isolating timing variance or demonstrating
  broader choice-schedule coverage. `choices_digest` also includes per-run input
  identities, so differing digests do not establish differing choice
  schedules.
- The host carried external load: load averages about 9–12 (1 min) and 23–47
  (5/15 min) during the run, and one unrelated BEAM in another checkout; see
  `rob-1232-prelaunch.log`.

ROB-1234 correction (2026-10-05): future recovery reports hash the selected
fault and raw simulator choices without per-run input identities. Repeated
same-seed executions of all three faults now reproduce the digest despite
fresh persisted identities. The historical pilot and fix-verification files
retain their original digests and limits; no measurements were rerun or
rewritten for this correction.

The predicted finding was fixed and separately verified by ROB-1235 above.
The remaining matrix and the at-least-1000 schedules remain. The owner selected
autonomous implementation on 2026-10-05; the active agent may choose and review
technical work, while retained measurement registrations and evidence still
govern scientific claims.

### Transport preparation (2026-10-05)

These are deterministic regression controls, not additional pilot rows or the
registered full matrix. Base `8e0f628`; raw output is retained under
`lab/results/rob-1085-transport-20261005/`.

The worker's unlink/kill interval had a reproducible ownership gap. With only
trusted local lifecycle hooks added, a real TCP disconnect held the handler
after unlink; killing that handler left the job alive through the 3-second
DOWN deadline (`worker-red.log`). An independent monitor now kills the job on
handler death and retires on job death. Links still propagate abrupt worker
loss; deliberate cancellation still unlinks before killing, preserving worker
availability. Four public TCP/Exec regressions check the gap, worker death,
normal completion, monitor retirement, and disappearance of witnessed native
shell descendants.

Peer FIN alone passed on this host and did not establish the reported socket
setup failure. The deterministic error-path control witnesses that FIN, then
explicitly closes the passive socket before active setup. Restoring the old
match raises on `{:error, :einval}` and kills the worker; the serving assertion
fails (`socket-match-control.log`). Handling the setup error as cancellation
keeps the worker available. The lifecycle hooks come only from trusted local
start options, never request data, and ordinarily do nothing.

The protocol deadline code was already correct. A sustained-fragment test
witnesses multiple received chunks and sends continuing past its 200 ms
deadline. A second test starts with a buffered partial line at zero remaining
time. Removing the post-fragment deadline check makes the buffered case
incorrectly complete (`omit-deadline-control.log`). Renewing the deadline per
chunk stretches the sustained case to 3194 ms, failing its <1000 ms bound
(`renew-deadline-control.log`). Both mutations were removed; no protocol
runtime change is delivered.

The nine lifecycle/deadline tests and the full suite of 894 (11 properties,
883 tests) passed at seed 1085. A forced failure before
fault release triggered owned-process and native-fixture cleanup with only the
intentional assertion failure (`cleanup-failure-control.log`). Full output is
`full-suite.log`; delivery evidence is recorded in ROB-1085. These checks do not establish
production-intensity VM recovery, input receipt safety across the remaining
matrix, or the required seeded measurement.

### Handoff observer preparation (2026-10-05)

This is harness preparation, excluded from the pilot and the required >=1000
schedule matrix. Base is `3cb4d35`; delivery and final verification are recorded
in ROB-1085. Raw controls are in
`lab/results/rob-1085-expanded-preparation-20261005/`.

`handoff_recovery` gates A's first provider request, positively observes queued
B/C receipts before releasing A, and kills the monitored source at one of five
public handoff lifecycle hooks. It also reads the durable checkpoint before
injection: prepared has no successor, created/transferred have an inactive
successor, activated still has source stage transferred with an activated
successor, and started has source stage started. An activated hook is not a
durable stage named activated. Both target monitors must observe killed after
the one nominated injection, while that hook remains held.

The read-only observer follows persisted successor links, including successors
that finished before recovery attachment. It validates parent/workspace and
receipt identities, the declared input roster, unique history/call IDs, linear
history, at-most-once User consumption, and matching tool results in each
input's own segment. These are closed fixtures with distinct User payloads,
not an observer for arbitrary branched production histories. A consumed
receipt alone is insufficient. Successful completion requires that input's
own non-interrupted persisted terminal and settled tools. A durable failed
receipt, an interrupted turn, and a paused queue remain separate outcomes.

Normal source handoff emits interrupted without necessarily appending a
terminal Assistant. Its own observed User followed by exactly one interrupted
event, matching its persisted consumed receipt with no active input or pending
tool, can establish interruption. This cannot establish success. The collector
subscribes before A; short-lived probe helpers never own its subscription.
Physical marker labels are independent effect counts and never completion
proof. Stale/wrong-session/duplicate events, wrong terminals, unexpected input
history/receipts, repeated consumption, and misplaced tool results are rejected.

Queue order and bounded provider timing vary by seed. Each input has at most
one marker, and no marker is replayed by the continuation. The recovery clock
starts before reopening; its bound is 5 seconds. Continuation plus two queued
inputs must settle within 7 seconds of reopening (5 seconds plus two bounded
1-second input allowances). Late observations cannot repair a missed clock.
The reported digest hashes the selected schedule, including its seed; digest
differences alone do not prove schedule diversity or timing variance.

Cleanup is installed before waits. Gate admission closes atomically before
collecting callers. Provider and marker callbacks must be admitted before
doing work; admitted callers are monitored, killed, and awaited separately
from session/helper/script cleanup. Forced failures with the provider or
source held confirm their observed actors die. A released hook or target
death before injection is an invalid fault row. Temporary wrong-code controls
which promoted consumed-only completion or accepted premature death both
failed and were restored. An additional red control exposed previously
unaccounted inputs; the observer now rejects them.

The initial nil-Boolean reporting failure, mismatched scripted streamed text,
activated checkpoint name-equality failures, and full-suite registry-list
failure are retained as harness/fixture failures, not runtime findings. Final
focused verification passed 38 tests, seed 1085. The reviewed preparation
produced five complete rows in five fresh dev VMs with production restart
defaults, all 21 checks and cleanup true: recovery 16–243 ms and backlog
settlement 18–245 ms. Raw rows and source hashes are in `production-reviewed/`.
These rows use dirty source at the stated base and are preparatory observations.

Limits: this family uses a same-VM scripted provider and textual inputs. It
does not prove whole-VM restart, child/test-job/native process-group safety,
executor slot/acknowledgment behavior, or the complete transport matrix.
Those families and the expanded registered measurement remain unfinished.

Integrated verification after the separately delivered ROB-1324 fixture repair
passed all 914 full-suite checks (11 properties, 903 tests), seed 1085, in
238.4 seconds. Its raw output is `full-suite-integrated.log`. The handoff lab
code and preparation source hashes are unchanged; these tests add no registered
measurement rows. Earlier failed suite output remains retained.

### Child recovery preparation (2026-10-05)

This is harness preparation at base `a4bbef1`, excluded from the pilot and the
required >=1000 schedules. `child_recovery` uses the public delegation, child
resume, review, acknowledgment and integration APIs in a disposable clean Git
fixture. Local hooks and signing are disabled in that fixture. Its stateless
provider serves only the declared inputs; no real-model or whole-VM claim is
made. A coding child inherits the provider and tool wrappers through actual
delegation. No local executor is opened by this roster.

The hypothesis is that a parent or child crash neither creates another child
nor consumes an accepted input twice, preserves uncertainty for unreceipted
mutations, and settles child capacity. Three checkpoints are implemented:

- `parent_delegated`: real child creation completed but the parent's delegation
  callback has not returned. The failed parent input preserves `delegate-A`
  as indeterminate; its queued B/C inputs and the child's original assignment
  finish without another delegation.
- `child_provider`: the child's first provider callback is held before a tool
  plan. The assignment fails without a marker; queued B/C inputs finish.
- `child_marker`: a marker has written in the child worktree but its callback
  has not returned. The assignment fails with `child-marker-A` indeterminate.
  Integration is blocked until the exact review digest/call IDs are
  acknowledged, then succeeds. Marker bytes do not prove input success.

Before injection, the fixture reads the durable source checkpoint, active
input and pending calls, the actual source Task monitor, held caller ownership,
queued B/C receipts with no User consumption, parent links and registered
child slot. Two real monitors witness the exact target's killed DOWN after
one injection. A released callback or premature death invalidates the row.
Typed uncertainty and parent/child observations are captured before cleanup.
Automatic parent reports are declared from each known completed child input's
own persisted terminal ID; they are not inferred from arbitrary parent inputs.
The closed observer rejects unrelated, repeated or stale inputs and receipts.

Seeds vary B/C queue order and provider TTFT from 1 to 20 ms. Recovery starts
before public reopening and has a 5-second bound. All queued work and reports,
including marker acknowledgment/integration, must settle within 9 seconds:
the base 5 seconds plus at most four 1-second input/report/remaining-work
allowances. Digests hash this declared schedule; differing digests alone are
not evidence of timing variance.

Cleanup closes both admissions and settles admitted creators first, then uses
a bounded serialized Threads barrier to discover/register child ownership.
It settles sessions/helpers and verifies capacity is zero. A failed barrier
cannot become an empty child roster or confirmed cleanup. Forced failures
with delegation and marker held directly prove the observed actors die. A
fresh-VM unavailable-barrier control retained one row and stopped a requested
second repetition. Temporarily omitting parent barrier ownership falsely
reported two clean rows and failed that control; the source was restored.
Those failed controls, logs and retained roots are preserved.

Focused verification passed 46 tests, seed 1085. Three fresh dev VMs using
production restart defaults each produced a complete row with all 16 checks
and cleanup true: recovery 11–13 ms, backlog 103–213 ms. Exact source hashes
and rows are in `production-reviewed/` under
`lab/results/rob-1085-child-preparation-20261005/`. These rows used dirty
source at the stated base. Earlier annotation/cwd/compile fixture failures
remain retained and establish no runtime finding.

This family does not prove native process-group, test-job, whole-VM, or full
transport recovery. Remaining families and registered measurement stay open
on ROB-1085. Final suite, review and delivery evidence are recorded there.

The first integrated suite completed 920/922 (11/11 properties, 909/911 tests)
in 244.2 seconds, seed 1085. Both failures are the 2-second loopback provider
fixture timeouts tracked by ROB-1216; no child preparation assertion failed.
The complete original output is `full-suite.log`. This candidate is held for
the separately tracked investigation and subsequent integrated verification.
