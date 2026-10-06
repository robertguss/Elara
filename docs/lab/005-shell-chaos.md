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

After ROB-1216's independently reviewed fixture repair merged in PR #40 at
`5448d84`, the unchanged child lab code was rebased and all four preparation
source hashes matched. Integrated verification at candidate `d1473e3` passed
924 (11 properties, 913 tests), seed 1085, in 275.4 seconds. Full output is
`full-suite-integrated.log`; the earlier failures and controls remain retained.
This adds no registered measurement rows. Exact reviewed delivery is in Linear.

### Test-job recovery preparation (2026-10-06)

This preparation at base `1d330c9` is excluded from the pilot and required
>=1000 schedules. `job_recovery` uses public job start/status/idempotent replay,
a real focused Mix fixture, a held source callback and queued B/C inputs.
The provider serves only the declared inputs and independently known report.
No provider credentials or network request is used. Fresh dev VMs retain
production restart intensity 3; ExUnit uses the separate test setting.

The hypothesis is that session or job-owner failure preserves one job identity
and physical launch, does not consume inputs twice, preserves uncertainty and
settles owned actors and native work. Three checkpoints are implemented:

- `session_running`: kill the source while its job runs and provider is held.
  Reopen from disk with B/C paused. A has a durable failed receipt; the original
  runner/execution remains running. Release the fixture and resume B/C. The
  original job passes and its report is interpreted; A stays failed.
- `runner_running`: kill the actual runner while the command is held. The job
  becomes indeterminate and its slot releases after executor settlement. The
  source, B/C and known report finish; native work stops before cleanup.
- `manager_running`: kill the named manager which actually links the runner.
  Its supervised replacement recovers the record as indeterminate. The linked
  runner and native command stop; source and known queued/report inputs finish.

Before injection, read the active input, completed `job-A` receipt, queued
B/C identities, source Task monitor, manager/runner link and running execution.
Native cwd ownership uses inode/device equality. The witnessed process group
must differ from the controller's group and contain the native PID. Immediately
before injection, recheck the held callback, live runner/native group and
unchanged execution. Released callbacks, premature death and finished jobs
invalidate the fault. Two real monitors witness killed DOWN for the declared
role after one injection. Killing the wrong role fails even when every other
progress and cleanup check passes.

The observer independently derives the expected report from the known terminal
job record, including its key, owner, evidence body and receipt identity. Each
input requires its own persisted terminal and tool results. A start-tool return,
launch marker or interpreted indeterminate report cannot prove job success.
Public start replay with the same logical ID retains key/status/execution and
physical launch count one. All observations precede cleanup.

Seeds vary B/C order and provider work from 1 to 20 ms. Setup has a separate
10-second bound. Recovery has a 5-second bound from the reopening/recovery
origin; continuation, B/C and one report settle within 9 seconds, including
at most four 1-second work allowances. Late evidence cannot repair the clocks.

Cleanup closes admission and settles admitted callbacks, then uses a bounded
serialized public job-status barrier before cancellation/settlement. It checks
the witnessed PID/group have no live members, runner death, released slot,
executor job count zero and the manager's active/pending/delivery work empty
before session/helper cleanup and root release. Unknown ownership cannot become
absence. Forced failures directly verify observed actors and the actual native
group stop. An unavailable barrier retains one row and stops a requested second
repetition even when native cleanup succeeded. Bypassing the guard falsely
confirmed cleanup and permitted two rows; the control rejected that mutation.
Exact source was restored after every mutation.

Final focused verification passed 76 tests, seed 1085. Three fresh dev VMs each
produced one complete row with all 14 checks and cleanup true, one launch and
native work stopped before cleanup. Recovery was 10–1037 ms; backlog settlement
103–1085 ms. Dirty-source hashes, base SHA, rows, controls and failed invocations
are retained in `lab/results/rob-1085-job-preparation-20261005/`. An initial
wrong-target selector excluded every test and establishes no evidence. The
subsequent all-file mutation failed 1/9 on fault identity with all other checks
true. These are preparations, not measurement or a runtime fix.

Limits: this witnesses the focused Mix command group on this host. Arbitrary
escaped descendants, executor/stub epoch recovery, client/worker death,
whole-VM restart and the full transport matrix remain unfinished. Final suite,
review and delivery are recorded on ROB-1085.

Integrated verification passed all 933 checks (11 properties, 922 tests),
seed 1085, in 251.2 seconds. Guidance 3, compile with warnings as errors,
format and diff checks passed. The full output is `full-suite.log` in the
preparation namespace. No registered measurement rows were added.

### Executor and native-stub recovery preparation (2026-10-06)

At base `c6c41df`, extend `job_recovery` with two same-VM checkpoints. This is
preparation, excluded from registered measurement. `executor_running` kills
the actual Exec process while its focused command runs; `stub_running` sends
KILL to the living native stub PID identified by that process's connected
Port. Capture the real owner/Port/os_pid, old execution token and native
group-leader/guardian/stub parent chain. Recheck the running job, held callback,
token, connected Port and actual native PID before one injection. The root and
coordinator independently monitor the actual process or Port. Native-stub
death also requires successful scoped kill submission and observed old OS PID
death. Port DOWN alone cannot prove native work stopped. Stale Port DOWN is
rejected.

The hypothesis is that executor/stub loss neither repeats the job nor consumes
inputs twice, preserves indeterminate outcome and holds capacity for an unknown
execution epoch, then permits scoped acknowledgment after actual native stop.
Executor death changes process/incarnation; stub death preserves the process
and incarnation while increasing generation. The old job execution remains
unchanged. Capture the replacement token/PID/os_pid and durable held/unknown
job before acknowledgment. The known report and A/B/C inputs require their own
terminals; interpreting the report does not establish job success.

The focused command group, native PID, old stub and guardian must stop before
acknowledgment. Public `acknowledge_stopped` applies only to this disposable
fixture's parent/job ID, after independent OS observations, and leaves the job
indeterminate while releasing its slot. Replay retains the original execution
and one physical launch. This does not complete a human/account acceptance gate.
Recovery remains bounded at 5 seconds, including the held/unknown/native-stop
observations; backlog, acknowledgment and report finish within 9 seconds.

Failed-flow cleanup may acknowledge only the same known synthetic job after
actual native/group/guardian stop. It still requires the serialized ownership
barrier, dead runner, released slot and idle executor/manager before root
release. Cleanup cannot repair the pre-cleanup input, slot or progress checks.
Forced failures directly verify source/runner/native/guardian teardown.

A stronger control suspends the positively owned guardian before stub KILL.
The fault is witnessed but native work remains alive, so pre-cleanup slot must
remain held/unknown and no acknowledgment may occur. Resume is registered
before suspension and runs before cleanup. This exposed a harness poll which
treated a negative native map as readiness; the separate acknowledgment guard
still blocked release. Both affected polls now require a positive Boolean.
The corrected control reaches the bounded native-stop timeout. A mutation
which bypasses both native-stop checks acknowledges early and records a
released slot while native work lives; the control rejects it. Source is
restored exactly. All failed assertions and raw control rows remain retained.

Final focused verification passed 83 tests, seed 1085. Two fresh dev VMs,
explicitly requiring production restart intensity 3, each produced a complete
row with all 18 checks and cleanup true: recovery 115–117 ms, backlog 215–220 ms,
one launch, old stub and guardian stopped. Raw rows, source hashes, controls
and logs are in `lab/results/rob-1085-native-preparation-20261006/`. Positive
preparations and deliberately suspended-guardian controls are separate and
add no registered measurement rows. Final suite/review/delivery are on ROB-1085.

Limits: this proves the witnessed focused command group and native parent
chain on this host. Managed extra/escaped descendants, TCP client/worker
faults, whole-VM restart and the expanded registered matrix remain pending.

Integrated verification passed all 940 checks (11 properties, 929 tests),
seed 1085, in 256.8 seconds. Guidance 3, compile with warnings as errors,
format and diff checks passed. Complete output is `full-suite.log` in the
native preparation namespace. No registered measurement rows were added.

### Ordinary command-group preparation (2026-10-06)

At base `62cbaace5904d7f33df54e9ebe75809bd6cce290`, `group_recovery` uses
public `Elara.Exec.run` to start a shell with an ordinary sleep child in the
assigned native process group. The hypothesis is that caller, executor or
native-stub death settles the actual command group without repeating execution
or claiming certainty across an execution epoch change. `owner_running`,
`executor_running` and `stub_running` are separate checkpoints. This is an
executor infrastructure family; it creates no accepted session inputs or
test-job slots and makes no receipt, acknowledgment or report claim.

Before injection, independently read the actual root/child PID, child parent,
living state, cwd inode/device and assigned group membership. Both PIDs must
belong to the same group, which must differ from the controller's. Capture the
Exec process, token, connected Port/os_pid and root/guardian/stub parent chain.
Recheck ownership, epoch and living caller immediately before one injection.
The root and coordinator independently monitor the actual process or Port;
stub injection also records scoped OS kill submission. Premature child loss
invalidates nomination. Seeds vary the fault delay from 1 to 20 ms; setup has
a separate 10-second bound and recovery has a 5-second bound from target DOWN.

Recovery observes the root, ordinary child, entire assigned group, guardian,
caller and public idle executor before cleanup. Caller death retains the same
settled epoch. Executor death changes process/incarnation; stub death preserves
the process/incarnation and increases generation. Both changed epochs retain
unknown settlement even after physical stop. Actual caller Task terminal
evidence distinguishes killed caller, GenServer call exit and indeterminate
stub response. A physical launch marker must occur exactly once.

Cleanup closes effect admission, settles the actual Task and bounded executor
cancellation, then requires native stop and public idle state before stopping
helpers/coordinator and releasing the root. Failed probes remain unknown.
Forced failures directly inspect owned native actors after cleanup. Suspending
the owned guardian before stub death leaves the ordinary child alive: the
fault is witnessed, but pre-cleanup recovery must fail. Resume is registered
before suspension and runs before cleanup. A mutation reporting native stop
without the OS witnesses fails this independent control (6/7 tests passed).
An unavailable-executor control retains the first root and stops a requested
second repetition. Bypassing the cleanup settlement guard falsely allows two
rows and fails that control. Exact source is restored after both mutations.

The earlier BEAM Port-child attempt at local commit `627c5e7` created a separate
process group, as already documented in `docs/test-jobs.md`. Cancellation
correctly left the job indeterminate with capacity held. That experiment is
retained under `lab/results/rob-1085-descendant-preparation-20261006/` and makes
no ordinary-group or detached-child cleanup claim. The first ExUnit fixture
root was removed by per-run test cleanup on VM exit; its logs remain. A fresh
dev diagnostic preserved a raw row and copied retained root. Its subsequent
metadata call failed, so it is not evidence of successful diagnostic teardown.
The sleep child later disappeared; no harness kill is claimed for it. Detached
children remain the existing explicit policy exclusion.

Focused verification passed 90 tests, seed 1085. Ordinary-group source hashes,
fresh production-default VM rows, controls and copied unavailable-executor
root are in `lab/results/rob-1085-group-preparation-20261006/`. Preliminary
rows precede the final typed-owner assertion; `production-reviewed-*` rows
use final source. Earlier compile and fixture failures are retained separately.
These preparations add no registered measurement rows. Client/worker/whole-VM
families and the expanded >=1000 seeded matrix remain unfinished. Final suite,
review and delivery are recorded on ROB-1085.

Integrated ordinary-group verification passed all 947 checks (11 properties,
936 tests), seed 1085, in 262.6 seconds. Guidance 3, compile with warnings as
errors, format and diff checks passed. Three fresh final-source dev VMs with
restart intensity 3 passed all checks (10 for caller/executor, 11 for stub),
complete/cleanup true and one launch; recovery was 40–150 ms. The full output
is `full-suite.log` in the group preparation namespace. No registered
measurement rows were added.

### Direct transport recovery preparation (2026-10-06)

At base `b1ce5c511a5338395f76349f0f12b7c6185e9e97`, the hypothesis is that
death of the actual remote-command client, TCP handler or worker preserves
accepted input and mutation intent, reports uncertainty without replay and
settles the witnessed command group. `transport_recovery` has separate
`client_running`, `handler_running` and `worker_running` checkpoints. It uses
public sessions, authenticated loopback Worker/Remote execution and a disposable
brain/worker workspace. The provider emits one declared remote bash call for A;
B/C have their own fixed terminal responses. Seeds vary queue order and 1–20 ms
provider/fault work. These are preparations, excluded from measurement.

Before injection, the worker handler is held at its trusted local lifecycle
hook with one native command already running. Pair actual TCP endpoints and
connected ownership; the client must be the source's monitored tool Task and
router checkout. Independently witness the worker job's Exec monitor, native
root and shell-owned child, parent/cwd/device/group and Port/guardian chain.
Accepted A must be active with its exact tool call, argument and durable
controller intent; B/C remain queued without transcript consumption. Recheck
the living actors, held point, TCP owner and native epoch before one fault.
Root and coordinator independently monitor the nominated process. Independent
positive tests check the actual source Task ownership and stage's target role.

Within 5 seconds of target DOWN, A must have its own terminal and exactly one
indeterminate tool result, the worker handler/job/TCP guardian must be dead,
and the native group/guardian must be stopped with Exec idle and the same
settled epoch. B/C must stay durably visible or have their own terminal.
All three complete within 5 seconds plus two queued inputs times the selected
per-input work, at most 5040 ms. The intent remains unchanged and physical
launch marker remains exactly one. An independent public remote read proves
worker service, replacing the owned worker when its linked lifecycle stopped.
No generic executor receipt or acknowledgment is claimed for this direct path.

Cleanup closes admission, stops owned workers, requires native/Exec settlement,
and stops the actual source and all tracked helpers before releasing the root.
Released handler admission and premature worker loss invalidate nomination.
Forced failure independently checks every owned BEAM/native actor. Selecting
the worker for the client stage fails the independent role control (5/6 pass).
A fresh dev VM with unavailable Exec settlement retains one row/root and stops
requested repetition 2. Bypassing its cleanup guard falsely permits two rows
and fails that control. Exact source is restored. The initial ExUnit version
of this control expected `evidence_dir` instead of the runner's `retained_dir`;
its KeyError log is retained, and the control now uses disposable dev VMs.

The optional explicit LocalExecutor receipt path is a separate finding. Killing
its actual TCP-owning callback leaves an accepted record after one attempt.
A reaches an indeterminate tool result and terminal, but B/C stay queued behind
the nonterminal receipt barrier even after actual native cleanup. The candidate,
failed focused output and a fresh dev raw row are preserved, not converted to
passing direct-path evidence. ROB-1104 tracks receipt recovery with supported
writer/incarnation boundaries; native stop alone cannot invent a causal receipt
terminal or authorize callback replay. These same-VM providers contain gate
PIDs and cannot be reused after whole-VM restart.

Raw rows, controls and source provenance are in
`lab/results/rob-1085-transport-recovery-preparation-20261006/`. Final focused,
integrated suite, production-default VM preparation and delivery evidence are
recorded on ROB-1085. Whole-VM recovery and the registered >=1000 schedule matrix
remain unfinished.

The initial integrated transport candidate passed 952/953 checks (11/11
properties, 941/942 tests), seed 1085, in 284.5 seconds. The existing concurrency
retained-ledger test at line 378 expected a task still alive after a 2500 ms
provider stall but observed zero. The raw full-suite log remains intact; no
causal scheduling measurement was retained for that failure. A separate
synchronization repair is selected in Linear before transport delivery.
Focused verification passed 99; the three fresh dev-VM rows require production
restart intensity 3 and pass all 13 checks, complete/cleanup true, one launch:
recovery 75–116 ms, backlog 81–117 ms. These are preparations only.

ROB-1325's separate fixture synchronization repair merged in PR #45 at
`445e0df`, after concurrency 44 and full 948 passed. Original transport candidate
`d501a4c` is retained at `archive/rob-1085-transport-held-d501a4c`. Resolving the rebase conflict changed
only continuation text; all seven transport runtime/test hashes match the
original final-source manifest. The combined transport tree passed all 954
checks (11 properties, 943 tests), seed 1085, in 262.4 seconds. Its output is
`full-suite-rebased.log`; the original 952/953 log is preserved unchanged.

The original receipt diagnostic root was copied to
`receipt-client-retained-copy/`. Read-only SQLite inspection after VM exit
matches the raw checkpoint's job ID and operation digest: accepted, one
admission, one callback attempt, zero terminals. `receipt-ledger-readback.json`
records the method and copied ledger hash. This is durable disk evidence,
not a live Executor.query; the old report timed out before its later query.
No receipt state was changed. Final clean-head preparations and exact review,
CI and merge evidence are on ROB-1085.

### External whole-VM preparation (2026-10-06)

Base `83f21ea`; `vm_recovery` declares `provider_running` and
`mutation_running`. A reusable external-VM owner launches the peer through an
actual Port, registers its controller monitor before launch, and refuses PID
kills after its Port exits. The peer uses only path/mode/stage/work provider
configuration and production supervisor intensity 3/period 5, read from the
actual initialization flags. The controller independently matches Port/os_pid,
BEAM image, cwd inode/device and bounded parent chain through observed
`erl_child_setup` to itself. For a mutation it also witnesses the connected
Exec/native guardian/root/child/group chain. A fresh nonce probes the actual
source callback Task immediately before one external SIGKILL; released points
and premature loss are ineligible. Exit status 137, actual Port DOWN and OS
stop are required. The ordinary group, guardian and old stub stop before
controller cleanup. Detached descendants and disk damage remain excluded.

A is consumed with its own exact User; B/C have durable queued receipts. Public
reopen in a new BEAM preserves all identities, fails A with a durable restart
receipt and exposes B/C paused through input_status. After public resume, B/C
must have their own declared terminals; no request or mutation is replayed.
Recovery includes reopen, disk observation and public status reads within
5000 ms. Backlog is two inputs with seeded order and 1–20 ms simulated work,
bounded by 5000 + 2*work_ms. The provider-only case has no native launch; the
mutation case has one physical launch and one indeterminate bash result.
The default direct route has no receipt backend. The replacement's live
journal can be absent while the original intent remains durable: an independent
read-only SQLite comparison matches exact job/digest/arguments before fault
and after progress. This does not create live executor authority.

Raw rows, source copies, logs and copied failed/retained roots are under
`lab/results/rob-1085-vm-preparation-20261006/`. Preserve the initial missing
scenario, direct-parent, nil-journal and live-journal comparison failures.
The first diagnostic copy hook tried to copy an already removed successful
root and failed; its provider-failure copy remains. It is not a mutation row.
Focused 39 passed; final VM tests 6 passed, seed 1085. Killing the stub instead
of the VM fails both positive cases (3/5); disabling controller-death handling
fails its control (0/1), with independent fixture cleanup. Missing serialized
VM ownership retains one row/root and stops n=2 even after independently
observed OS stop; bypassing that predicate falsely permits two confirmed rows
and fails the control. All mutations are restored. The frozen tree passed
full 960 (11 properties, 949 tests), seed 1085, in 270.7 seconds, compile with
warnings as errors, format and diff checks. Final clean-head production-default
preparations, exact review and delivery are recorded in ROB-1085. These rows
are excluded from the >=1000 registered matrix, which
still requires a reviewed finite schedule plan and measurement.

### Finite matrix infrastructure (2026-10-06)

`Matrix.plan/2` declares 24 checkpoints across seven delivered families:
session (3), handoff (5), child (3), focused job/native epochs (5), ordinary
group (3), direct transport (3), and whole VM (2). Fifty round-major repetitions
give 1200 rows with unique consecutive seeds 1085000–1086199. A separate
24-row qualification uses 1084900–1084923 and is excluded from measurement.
This is a finite set of checkpoints, not an exhaustive fault cross-product.

`MatrixRunner` launches one fresh externally owned peer per row with two BEAM
schedulers and observed production supervisor intensity 3/period 5. Source,
application/dependency BEAMs, consolidation blobs, loaded application/dependency
module MD5s and native hashes are frozen in a registration.
Peers verify them before application admission and after shutdown. The peer
runs from the pinned repository; HOME, TMPDIR, sessions and fixtures live under
the disposable row root. The registered launcher invokes no repository compiler;
the focused Mix command remains the job family's declared fixture workload.
The scenario gets a 60-second outer deadline; VM exit and stub settlement have
separate bounded cleanup waits. A row root is never overwritten or reused.

Raw peer output, boot/observed/finished reports, controller Port/OS witnesses and
the final row record are retained. Failed scenario checks already retain their
fixture through `Lab`; unconfirmed cleanup retains its original root. The
controller requires exact row identity, every declared check, clean source,
the fixed settings, causal fault evidence, a matched owned launcher and physical
outer cleanup. A witnessed false outcome stays eligible and is counted as a
failure. Missing provenance/causal evidence or unconfirmed cleanup stops the
matrix. Earlier preparations, controls and the qualification are never pooled
into the measurement. Existing family recovery/backlog bounds remain unchanged.

Preparation and mutation logs are in
`lab/results/rob-1085-matrix-preparation-20261006/`. A deliberately disabled
outer cleanup fails actual OS-stop controls; independent fixture cleanup remains
registered. The final clean-head checks, review, delivery and immutable
registration are recorded on ROB-1085. No 1200-row measurement is claimed here.

The first clean-head preparation was rejected before application admission:
disposable HOME removes the user's global Git ignores, exposing Finder metadata
that the controller ignored. Its raw preflight rejection remains retained.
Repository `.DS_Store` ignores now make that exclusion explicit; artifact source
checks disable the global excludes file and report their actual source state.
The preparation does not count as a fault schedule or measurement.

### Registered finite matrix result (2026-10-06)

The one registered measurement completed at source
`15e000c15321a545d087ed85255d209c50f1cfd4`: **1200/1200 eligible and passed**,
50 rows at each of 24 checkpoints, round-major seeds 1085000–1086199.
All 20,350 recorded check values are true; there are zero outcome failures,
ineligible rows or unconfirmed cleanups. The separate 24-row qualification
passed and is excluded, as are every earlier pilot, preparation and control.
No failing measurement row requires minimization or a runtime fix.

Independent readback matches every row/cell/seed to the frozen registration,
clean source, two schedulers, actual intensity 3/period 5, owned Port/os_pid,
exit 0/Port DOWN/OS stop and the observed native stub generations. Registration
and source/compiled/native hashes still match after the run. The maximum outer
row duration is 2366 ms. Recovery and backlog observations below are milliseconds;
percentiles describe this finite corpus and do not estimate a population.

| Family | Rows | Recovery p50 / p95 / max | Backlog p50 / p95 / max |
| --- | ---: | ---: | ---: |
| Session | 150 | 16 / 17 / 28 | 105 / 106 / 116 |
| Handoff | 250 | 134 / 196 / 229 | 136 / 198 / 233 |
| Child | 150 | 13 / 16 / 18 | 97 / 242 / 280 |
| Focused job/native epochs | 250 | 107 / 1051 / 1127 | 227 / 1103 / 1178 |
| Ordinary command group | 150 | 47 / 152 / 157 | Not applicable |
| Direct transport | 150 | 88 / 138 / 150 | 89 / 138 / 150 |
| Whole VM | 100 | 34 / 36 / 57 | 47 / 68 / 70 |

Every recorded family bound passed. This supports the registered safety and
progress hypotheses at these checkpoints with simulated/scripted providers and
ordinary owned native groups. It does not extend to arbitrary fault positions,
disk damage, detached descendants, real-model behavior or owner TUI acceptance.
The optional explicit receipt-client barrier remains the separate ROB-1104
finding; physical cleanup creates no generic receipt or replay authority.

Raw evidence is retained in
`lab/results/rob-1085-matrix-measurement-20261006-a1/`, including every peer log,
boot/observed/finished/record file, copied registration, per-case summary and
independent readback with per-record hashes. The registration manifest SHA256 is
`bbe689027c60ed364d43f54c7c6cbc3d6aed32bf27e94e038fd0694a74640a41`;
measurement summary SHA256
`f92e30959ce5c3a33cccad4e4612957e530755517c9e2b22a6cc7a6c81efdc20`.
The launcher, generator, their hashes, qualification, postflight artifact check
and host observations remain in adjacent `rob-1085-matrix-*-20261006-a1` files.
Linear holds the final registration, admission decision, review and delivery.

The host was Apple M3 Max/96 GiB, OTP 29/Elixir 1.20.4, on AC power, with no BEAM
in the pre-registration process check. An unrelated Phoenix VM was identified
outside Elara at postflight; its start time during the run was not measured.
Timing is host-specific, with incidental activity, and is not a controlled
throughput comparison. LAB-3's measurement pause and host protocol remain.
