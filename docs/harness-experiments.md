# Harness experiments and resulting functionality

This evidence log connects experiments to changes in Elara's harness. It is not
a second implementation queue: [ROADMAP.md](../ROADMAP.md) owns current status,
publication commits, and what is authorized next. The
[feature priorities](features-research/priorities.md) capture the original
assessment; research proposals are not implemented capabilities.

For each completed experiment, record its question, setup, observed result,
operator assistance, useful functionality, checks, and limits here or in a
linked report. Update the relevant user/API guide when behavior changes.
Separate an experiment's evidence from later fixes it inspired. Dedicated
evals and benchmarks remain deferred.

## 2026-09-06: Live plugin discovery and revision — PLUGIN-1

**Question:** Can a running agent session acquire and evolve a useful tool
without losing its state or conversation?

**Functionality added:** default-discovery sessions can explicitly rescan local
plugin files between turns. Existing plugins can change revision while keeping
their process and migrating state. The controlling TUI offers `/plugins reload`;
ordinary `/reload` still refreshes the session snapshot. The project plugin adds
`elixir_rerun_last`, which remembers structured Mix arguments.

**Evidence:** the scripted-provider acceptance ran a real failing Mix test,
used the actual edit tool, upgraded the plugin, and reran successfully. A broken
revision was rejected while the working revision and remembered state remained
usable. Focused coverage includes discovery policy, ownership, protocol, and
the actual Rust terminal. Later review fixes brought the focused set to 34
passing tests. Rust TUI and execution-stub checks passed; full-suite limits are
recorded in the roadmap.

**Learning:** live loading and state continuity are useful runtime mechanisms.
They do not establish autonomous tool selection, general core hot-upgrade
safety, or a productivity advantage. Plugins execute trusted local code;
activation is explicit, state is live-session state, and rollback cannot undo
external effects. Removal and retirement of old generations remain deferred.

Guide: [Live plugins](plugins.md). Decisions:
[plugin experiment map](../.scratch/live-plugin-runtime/map.md).

## 2026-09-06: Agent-authored diagnostic plugin — PLUGIN-2

**Question:** Does that mechanism help a real model complete a coding task?

**Observed result:** `gpt-5.5` at low effort authored a shell-liveness plugin,
used it on a live shell, and fixed a macOS test-helper assumption. The plugin
upgraded from version 1 to 2 in the same BEAM process, retaining probe 6 across
turns and revision. The historical probe stayed historical after the shell
exited; retention was not a fresh observation.

**Functionality retained:** a portable shell-test helper and regression for
inconclusive `ps` failures. All 21 shell tests passed. The diagnostic plugin is
an [archived specimen](features-research/fixtures/shell_liveness.exs), outside
automatic discovery; it is not a permanent default tool.

**Assistance and limits:** seven prompts, 50 tool results, two iteration-limit
stops, an operator-provided persistent fixture, explicit activation, cleanup
guidance, and review corrections. This was assisted success. A roughly
180-line diagnostic wrapper did not demonstrate enough repeat use to justify
keeping two more tools in every session. The run used the public session API,
not a live TUI acceptance exercise.

Report: [results and practical assessment](features-research/agent-authored-plugin-experiment.md).
Reproduction context: [exact prompts](features-research/agent-authored-plugin-prompts.md).

## 2026-09-06: Useful repeated calls — LOOP-1

**Problem exposed by PLUGIN-2:** the guard rejected identical probes and tests
anywhere within a turn, even after state changed. The model worked around it
by changing arguments or switching tools.

**Functionality added:** identical arguments are eligible again after an
intervening call or in a later model response. Consecutive identical calls
within one response remain suppressed. Scoped-instruction deferral retries and
the model-iteration budget remain supported. This is loop policy, not cached
results or an exactly-once execution guarantee.

**Evidence:** regressions failed before the fix. Afterward, 35 focused checks
passed, including real read → test → edit → identical read → identical test
within one user turn, plus matching flight-recorder replay. Review was clear.
The full suite passed 451/461, versus 447/457 before the fix: all four added
tests passed and the same ten tests failed. Their unresolved areas are listed
in the roadmap. This follow-up used deterministic scripted requests with real
tools; it was not another live-model experiment.

**Learning:** tool policy can obstruct useful work even when the underlying
runtime works correctly. The durable improvement here is in everyday harness
behavior, rather than an additional BEAM mechanism.

Guide: the execution limits and repeated-call policy in [README.md](../README.md).

## 2026-09-07: Captured check diagnosis — DIAG-1

**Question:** Can a small model-backed operation keep an explicit result contract
while Elara owns immutable evidence, execution, cancellation and acceptance?
This is the first direct slice of the [DSPy proposal](features-research/dspy-for-elara-2026-09-06.md).

**Functionality added:** the version 3 project plugin captures up to four selected
source excerpts before a check and retains its output afterward. `check_evidence`
inspects that bundle; `diagnose_check` performs one additional tool-free provider
request using `check_diagnosis/v1`, strategy `direct/v1`. The session validates
required fields and captured artifact/line references. The existing Rust tool
viewer shows and copies the report, including rejection details. Usage is
retained in the typed transcript and canonical totals, persistence and protocol.

**Runtime evidence:** real Mix failure and source-edit fixtures pass through the
public session API. The original source remains available after edits and
restart. Cancelling one gated diagnosis terminates its worker and rejects a late
result while another session finishes independently. Worker crash preserves the
capture. Rewind clears active evidence; clone/fork and resuming another session
do not retain a capture from the wrong history. Flight-recorder replay matches.
The Rust PTY exercise searches the result, redraws it at a different size, copies
the complete canonical report and submits the draft preserved during inspection.

**Initial live result: both responses were rejected.** Two assisted runs used actual
`gpt-5.5` at low effort through the subscription provider. The synthetic Mix
project's `NameHelper.normalize/1` handled strings, while a test required `nil`
to produce an empty string. Both responses correctly identified the missing
clause on manual inspection, but each cited log lines 29–45: **17 lines against
a 10-line limit**. Neither became an accepted diagnosis.

| Run | Direct request duration | Reported direct-request tokens | Outcome |
| --- | --- | --- | --- |
| Initial implementation | 7,670 ms | 1,395 input + 311 output = 1,706 | Rejected; generic validation reason. |
| With command metadata and specific rejection reasons | 7,161 ms | 1,436 input + 311 output = 1,747 | Rejected; explicitly reports the 17-line span and 10-line maximum. |

The first response also mistook the plugin's `test:...` label for a command.
That prompted retaining the actual executable/argument arrays and explaining
their meaning. The second response used those arguments. This is a local
observation across two development revisions, not evidence of a reliable
improvement. The initial implementation kept the acceptance limit intact; the follow-up
below removes it. No automatic repair or hidden retry was added.

**Assistance:** each run used a supplied minimal project, selected source files,
and two explicit owner prompts: run only the check, then diagnose that run once.
The operator inserted the missing clause after capture and separately verified
the current workspace passed after diagnosis. That deliberate edit tested
historical evidence; the model did not make the fix. Each run included four
ordinary assistant responses in addition to the one direct diagnosis request.
The full prompts, captured excerpts, raw rejected responses, final replies and
usage totals are retained in [the live records](features-research/check-diagnosis-live-runs.json).

**Learning:** inspectable evidence exposed a mistake in our acceptance policy:
the 10-line maximum rejected a complete, relevant failure block. The initial
recommendation to add curated examples was premature. Correct the unnecessary
constraint before deciding whether model optimization is warranted. Structure
and valid references still do not prove a diagnosis's causal claims.

### Citation-range correction and direct rerun

Removed the arbitrary per-reference line-count maximum from the prompt and
validator. References must still name captured artifacts and contain valid,
ordered line bounds. The one-to-five reference count, text/report byte bounds,
source/output capture bounds and 512-byte citation previews remain unchanged.
The five-field `check_diagnosis/v1` schema and `direct/v1` strategy are unchanged.

Both original saved responses now pass validation **without changing their
text or evidence**. This is offline revalidation, not two new successful live
calls; the original records above preserve their historical rejection outcomes.

One fresh assisted `gpt-5.5`/low run on the same fixture was **accepted**. It
correctly identified the missing `normalize(nil)` clause and again cited the
17-line failure block at lines 29–45. The preview was clipped to 512 bytes and
marked accordingly. The direct call took **6,659 ms**, reporting **1,428 input +
309 output = 1,737 tokens**. There was one diagnosis call, no automatic retry,
repair or curated example, plus four ordinary assistant responses.

The operator used the same source selections and two prompts, replacing only
the run ID, and again inserted the nil clause after capture. Diagnosis used the
original source; a separate current-workspace check passed both tests. The
model did not perform that fix. Full evidence, prompts, accepted report and
final reply are in [the follow-up live record](features-research/check-diagnosis-citation-fix-live-run.json).

Regression tests exercise the two original responses, invalid/out-of-range
references, and a longer accepted range with a bounded preview through the
session and Rust inspector. This shows the correction works on the recorded
case; one assisted synthetic fixture does not measure general diagnosis
quality or productivity. No example strategy, RLM, GEPA or optimizer is
implemented, and no new comparison has started.

Guide: [captured check diagnosis](check-diagnosis.md). Publication and shared
verification results: [DIAG-1 in the roadmap](../ROADMAP.md#diag-1--diagnose-a-captured-failed-check).

## 2026-09-06: Supervised test completion and agent wakeup — JOB-1

**Question:** Can a supervised test run outlive a model turn and bring the agent
back with evidence, without model polling or operator-managed shell lifetime?

**Functionality added:** the local `test_job` tool starts one focused Mix target,
returns a stable job record, supports status and explicit cancellation, and sends
completion through the existing inbox. Intent and results are stored before
execution/delivery. Admission holds one reservation per logical session and four
globally, with a 60-second limit and 16 KiB output cap. Source fingerprints expose changed source;
paused input stays paused and offline sessions require explicit reopen.

**Deterministic evidence:** real Mix fixtures cover start → idle wait → completion,
a second usable session, stable start IDs and conflicting retries, one logical
inbox acceptance after duplicate redelivery and adapter restart, paused/offline
resume, explicit cancellation, source changes, target validation, session limits/
ownership, handoff lineage, blocked inbox delivery without blocking cancellation,
rejection of queued starts from stopped callers, malformed and contradictory saved records,
lost execution epochs with explicit operator reconciliation, and runner/manager
crashes without command replay. The execution stub's cancellation API retains confirmed terminal evidence instead of killing
the caller and losing its result. Current check totals and publication status
belong to JOB-1's Result in the roadmap.

**Live evidence:** session `id7yreQ1ln5OSrXkd_5_OA` used the configured Codex
provider with an empty user-skill home, persistent history, and no plugins.
The fixture deliberately waited five seconds, then checked 17 × 23 = 391. The
model called `test_job start`, ended its turn waiting, received one completion
input, called `test_job status` once, and reported exit 0 with unchanged source.
Execution reported 5,331 ms and one passing test. There were two completed turns,
one completion input, and exactly two tool calls: start and status. No model
polling calls, corrective follow-up, manual completion injection, or rerun.
The [sanitized public transcript](fixtures/test-job-live-2026-09-06.json) retains
the exact prompt and outcomes, with no credentials or private provider state.

**Learning:** supervision and message delivery now support useful work between
model turns. This removes the need to keep a shell alive through ordinary
foreground `bash` calls or repeatedly ask a model whether a test finished. The
new behavior reuses the Rust execution stub and the inbox; it does not introduce
another model loop or replace the session reducer.

**Limits:** this was a delayed arithmetic fixture, not a sustained repository
coding task or productivity comparison. Commands still execute trusted project
code and may have effects. A lost runner/owner produces indeterminate evidence;
commands are never automatically replayed. Source hashes are observations of a
declared file set, not isolation from concurrent edits or external dependencies.
The agent must inspect current status before treating old results as current.
Results persist, but running execution does not resume after VM loss. Evidence
records accumulate on disk; automatic retention/pruning is not implemented.
Uncertain execution retains its capacity reservation until settlement is known;
losing the execution epoch requires operator confirmation that the old command
has stopped. Malformed records block new admission and require repair. Delivery
retries use a pending index rather than rescanning all retained history.

Guide and boundaries: [Supervised focused test jobs](test-jobs.md). Broader
[context/wakeup research](features-research/harness-ideas-beam-2026-09-06.md) and
[typed-operation research](features-research/dspy-for-elara-2026-09-06.md) remain
separate proposals. Evals and benchmarks remain deferred.

## 2026-09-07: Real repository repair with test-job continuation — JOB-2

**Question:** Can a real model use retained test evidence and automatic completion
to diagnose, repair, and verify an existing repository failure?

**Setup:** `gpt-5.5`, low effort, persistent session
`RA0iisPNya1AkewF5SSkrw`, no plugins or user skills, and the ordinary
read/write/edit/bash tools plus `test_job`. The host selected and reproduced the
existing nested-parent thread-integration failure, then gave the model the test
name and workflow without supplying the diagnosis or patch. This branch builds
on JOB-1 at `3f8a300`. The run used the public session API, not a live TUI
acceptance exercise.

**Observed sequence:**

| Job | Outcome | Execution time | Evidence |
| --- | --- | --- | --- |
| `job2-before` | Failed, exit 1 | 1,323 ms | `/var/...` and `/private/var/...` compared as strings despite identifying the same directory |
| `job2-after` | Failed, exit 1 | 975 ms | The model introduced nonexistent `File.realpath!/1`; the test caught it |
| `job2-after2` | Passed, exit 0 | 899 ms | Model replaced its invalid helper with physical-directory resolution; current source unchanged |

All three jobs delivered retained completion inputs, and status was inspected
once per completed job. Across the saved session there were 43 public messages,
18 tool calls (six test-job calls, three reads, five shell calls, four edits),
one initial prompt, and one explicit continuation prompt. Shell calls searched
source, inspected function availability, and formatted the patch; tests ran
through `test_job`, without polling or manual completion injection.

**Assistance and failure:** the provider returned an empty-assistant-response
error after the first repair's test was started. The experiment driver closed
the session; the second completion had already been consumed by the time it was
reopened. Resuming inputs alone did not restart inference. The host reopened the
session and supplied one continuation prompt, without a diagnosis or code fix.
The model then corrected its own invalid API choice and finished. This was
assisted success, not uninterrupted autonomous repair. The first failing run
also logged a fixture cleanup error after its path assertion failed.

**Functionality and review:** this experiment repairs test portability. The real
repository-root content integration already worked; production thread behavior
does not need to change. The original model patch and exact public prompts,
tool calls, results, and job evidence are retained in the
[evidence artifact](fixtures/test-job-repository-repair-2026-09-07.json).
Review found that normalizing both paths weakened the exact invocation-path
assertion. The host reduced the shipped patch to one line: compare `parent_cwd`
with Git's repository-root path using the existing helper, while preserving
`parent_invocation_cwd == nested`. The focused test passes independently on that
final patch; the model's passing job applies to its earlier, larger patch.
Current full-suite checks and publication status are recorded in JOB-2's Result
in [ROADMAP.md](../ROADMAP.md).

**Learning and practical value:** durable execution and completion delivery
survived a provider failure and session reopen, and test evidence prevented an
invented API from being mistaken for a successful repair. Delivered evidence
does not guarantee that the model finishes acting on it: consumed input and
failed inference are separate states. Drivers should account for a pending or
already-started continuation when handling a provider error.

The mechanism is useful for work that must outlive a model turn. These tests
took about a second each, so this trial does not establish a speed or cost
advantage over ordinary foreground execution. The next practical priority is
reliable continuation after inference failure, followed by a naturally longer
test or build task. No dedicated eval or benchmark framework was added.

## 2026-09-07: Provider failure with the driver attached — JOB-3

**Question:** Did JOB-2 expose a missing runtime recovery mechanism, or did its
driver stop before the existing continuation path could finish?

**Method:** three deterministic checks use real Mix fixtures and a controlled
provider. Two additional live cases use `gpt-5.5` at low effort, with a wrapper
that returns exactly one deliberate `bad_response` at a chosen request boundary.
The other requests reach the real provider. These are injected failures, not
observations of a natural outage. The driver stays attached. Fixtures wait for
a release marker outside the fingerprinted source set and count physical runs.

| Boundary | Live observation | Intervention |
| --- | --- | --- |
| Failure after starting a job, before completion | Session `VvASbbDp-Py6XNDK-GgR4Q`: later completion automatically starts a successful interpretation turn | No continuation prompt |
| Failure during completion interpretation | Session `T1rQU69dEEwkSHU3xz_Zpw`: input retains `failed` and its provider error; existing result remains available | Driver sends one explicit continuation prompt |

Each case recorded **one command execution, one completion input, one model
start call, and one model status call**, with a passing result and unchanged
source. The first case made four provider attempts, including the injected
failure (three real requests); the second made five (four real requests). The
short Mix fixtures reported 354 ms and 5,024 ms respectively. Those times include
fixture gating and are not performance benchmarks. The
[public evidence](fixtures/test-job-failure-recovery-2026-09-07.json) includes
prompts, outcomes, source evidence, intervention counts and invariant checks.
Both cases also passed before review; the published pair was rerun after adding
exact failed-receipt checks and successful-fixture cleanup. The earlier run's
summaries remain in the evidence. Successful fixture directories are removed
after evidence capture; failed/uncertain fixtures are retained for diagnosis.
Persisted sessions and job records remain available.

**Deterministic findings:** all 15 job checks pass, including the three new
cases. They prove automatic continuation from a later completion, failed-input
and error retention through session reopen, no retry from `resume_inputs`, an
explicit new prompt using the existing evidence, and preservation of an explicit
pause. No command is rerun. The first characterization incorrectly expected a
failed provider turn to leave the entry `consumed`; it exposed the stronger
existing behavior: the entry becomes `failed`. The test expectation was
corrected after inspecting the implementation; runtime policy was not changed.

**Functionality retained:** regression coverage, a reusable opt-in experiment
driver, and a more precise [recovery guide](test-jobs.md). Existing supervision,
inbox state transitions and explicit continuation were sufficient for these
cases. No automatic provider-retry policy or new execution mechanism was added.
JOB-2's result remains assisted; this controlled follow-up explains the boundary
without reclassifying that earlier run as autonomous success.

To repeat the live cases with the configured Codex login:

```sh
mix run test/support/test_job_recovery_live.exs /tmp/elara-recovery.json
```

This command uses real model requests and creates persistent experimental
sessions. Ordinary `mix test` runs only the offline characterization checks.
The script injects the fault and supplies the disclosed continuation in the
second case; the model does not autonomously decide to retry inference.

**Assessment:** useful confirmation of the BEAM supervision and inbox design.
Execution, evidence delivery, and inference success have separate lifetimes,
and Elara already exposes the failed-input state needed to act on them. Keep
explicit continuation for failed interpretation and preserve user pauses.
These two cases do not establish general resilience to transport outages,
streaming interruption, auth failures, or repeated provider errors. The next
experiment should use a naturally longer repository test/build task, with this
driver-lifetime lesson applied. Current checks and publication belong to JOB-3
in [ROADMAP.md](../ROADMAP.md); evals and benchmarks remain deferred.


### Integration checkpoint: JOB-1–JOB-3 with DIAG-1

On 2026-09-07, the supervised-job stack `64d27af` was integrated with main
`5c1d545`, retaining captured-check diagnosis and all three job experiments.
The merge required combining built-in tool registration and documentation; no
new runtime policy was introduced. All 70 focused integration checks pass, as
do formatting and warnings-as-errors compilation. The full merged suite passes
486/493 in 128.0 seconds, with seven previously recorded baseline failures.
The next authorized experiment uses the existing context-recovery test file.

## 2026-09-07: Longer context-recovery job and concurrent session — JOB-4

**Result:** one live run passed all checks on revision `cf29908`, based on the
fully repaired main `594384a`. The existing `test/elara/context_test.exs` ran
through `test_job` without changes to the tests or production runtime. Both
sessions used actual `gpt-5.5` at low effort. The
[full evidence](fixtures/long-context-job-live-2026-09-07.json) retains prompts,
public messages, command output, usage, source hashes and all latency samples.

| Observation | Result |
| --- | --- |
| Focused command | 11,930 ms, exit 0, 15 tests passed |
| Exact target command launches | 1, counted by a PATH shim before exec of real Mix |
| Provider error | 1 deliberately injected immediately after start returned `running` |
| Completion inputs | 1; accepted automatically by the subscribed owner |
| Owner model tool calls | 1 start, 1 status; no polling or rerun |
| Continuation prompts after failure | 0 |
| Independent real-model request | `17 * 23` → `391` in 2,060 ms; job record still `running` at reply |
| Owner status API during job | 122 samples; median 0.029 ms, maximum 0.147 ms |
| Source identity | All 139 files in the declared source set unchanged before/after and at status |
| Owner provider requests | 4 attempts, of which 3 reached the real provider and 1 was injected |
| Secondary provider requests | 1 real request |
| Reported token usage | Owner 5,758; secondary 921; total 6,679 |

Relative to driver start, the provider error was observed at 4.317 seconds,
the second session finished at 6.377 seconds, job completion was observed at
16.265 seconds, and the owner finished interpreting it at 20.884 seconds. No
real owner provider request occurred between the injected error and observed
completion. The completion timestamp comes from host observation of the durable
record, not an exact process-exit timestamp. The command duration comes from
the execution result. The error log inside the target's output is an expected
crash-recovery fixture; its final result is 15 passed.

**What this establishes:** the admitted job survives a failed provider turn,
its retained completion starts another turn without an operator prompt, and a
second session can complete useful inference while the job is outstanding.
This exercises separate job, session and inference lifetimes using the existing
BEAM supervisors, processes and inbox delivery. No runtime change was needed.

**Limits and assistance:** the driver supplied the target, stable job ID,
completion instructions and secondary arithmetic prompt. The provider failure
was synthetic and occurred after admission, not a natural transport outage or
a crash of the owning VM. The exact-command counter does not count the target's
expected nested subprocesses as duplicate target launches. The driver sampled
local APIs; these are not TUI/network latency measurements. Twelve seconds is
longer than the earlier five-second fixture, but is not a multi-minute stress
run or evidence of superiority over another runtime. Source hashes cover the
declared files, not all dependencies or transient filesystem changes.

The opt-in driver is reproducible with the existing Codex login:

```bash
mix run --no-start test/support/long_context_job_live.exs OUTPUT.json
```

`--no-start` is required: the driver installs its launch-count environment before
starting Elara's Rust execution process. Review caught and fixed the initial
post-start instrumentation mistake before any live request. Review also changed
the overlap assertion to inspect the job state at the secondary reply, rather
than infer it from a later sampled completion timestamp. The run retains its
private session/job records and launch log in the reported temporary directory;
both sessions are stopped after evidence capture. Ordinary ExUnit remains
offline and does not load this driver. See JOB-4 in [ROADMAP.md](../ROADMAP.md)
for final verification and publication.


## 2026-09-07: Owner session crash with retained job completion — JOB-5

**Result:** one live run on `d0b8b16` passed all eight checks. The existing
`test/elara/context_test.exs` executed once and passed all 15 tests in 11,878 ms.
The driver deliberately killed the idle owning session after observing the
command launch. The job remained running across the kill, finished while its
owner stayed offline, and retained its terminal result with delivery pending.
Explicit reopen of the same saved session, followed by subscription, delivered
one completion input and triggered successful interpretation. No production
runtime change was needed. The [full evidence](fixtures/session-crash-job-live-2026-09-07.json)
includes before/after-kill records, the offline terminal record, public
transcripts, source fingerprints and latency samples.

| Observation | Result |
| --- | --- |
| Target command launches | 1, exact argv counted by PATH shim before exec |
| Target result | 11,878 ms, exit 0, 15 passed |
| Owner lifecycle | Killed PID replaced only by explicit reopen; same session ID |
| Retained offline evidence | Passed, delivery pending |
| Completion after reopen | 1 input, consumed; delivery accepted; slot released |
| Model job actions | 1 start, 1 status; no polling or rerun |
| Additional owner prompts | 0; driver explicitly reopened and subscribed |
| Secondary real-model response | `17 * 23` → `391` in 1,384 ms, job still running |
| Secondary status API during job | 108 samples; median 0.029 ms, maximum 0.635 ms |
| Source identity | 140 declared files unchanged before/after and at final status |
| Reported usage | Owner 7,157 tokens; secondary 911; total 8,068 |

Relative to driver start, the owner was confirmed killed at 3.659 seconds,
the secondary response arrived at 5.048 seconds, terminal evidence was observed
at 14.037 seconds, the owner was explicitly reopened at 14.046 seconds, and its
final interpretation arrived at 19.693 seconds. Both sessions used real
`gpt-5.5` at low effort. There was no injected provider failure in this run.
The error log inside the target output is an expected context-recovery fixture;
the target's final result is 15 passed.

**What this establishes:** job execution and retained completion survive loss
of the conversation process within a surviving BEAM VM. The existing temporary
session restart policy is intentional: the supervisor does not recreate the
owner. Reopen is an explicit host/operator action, after which completion drives
the model without another prompt. This confirms useful isolation and durable
result delivery within the current architecture.

**Limits and assistance:** the driver supplied both prompts, the exact target,
the kill and the explicit reopen. It killed an idle session after its waiting
reply, not an in-flight inference or tool call. The PATH shim observes command
launch before exec, not the first test assertion. Durable running records were
checked before and after the kill; these are host observations rather than
precise OS execution timestamps. This is one controlled run, not proof of
recovery from loss of the execution stub, runner, entire VM or machine. Those
boundaries retain their existing indeterminate/no-retry policy. API samples
measure local secondary-session status latency, not TUI latency or comparative
runtime performance. Source identity covers the declared file set. Private
session/job records and the launch log remain in the driver's reported temporary
directory; both live sessions stop after capture.

The offline characterization uses a real controlled Mix fixture, waits for its
execution marker before killing the owner, releases the job while the owner is
absent, and verifies one consumed completion after reopen. A forced delivery
retry produces no duplicate input or model request. All 16 job tests and both
roadmap tests pass; the full suite passes **498/498** in 129.5 seconds. Formatting,
compilation with warnings denied, static driver compilation and independent
review pass. Review found no blocking issues. The live driver requires explicit
invocation and remains excluded from ordinary ExUnit:

```bash
mix run --no-start test/support/session_crash_job_live.exs OUTPUT.json
```

**Next candidate:** exercise cancellation and capacity release under several
concurrent jobs. This is a proposal, not an authorized queue item; broader job
types and optimizer work remain deferred.


## Experiment ID reconciliation at integration

Main already used JOB-4 for the concurrent context job and JOB-5 for owner
session crash recovery. On integration, the separate basic repository run
becomes **JOB-8** (formerly branch-local JOB-4), and line-range reads become
**JOB-9** (formerly branch-local JOB-5). JOB-6 and JOB-7 are unchanged. This
log and the roadmap use canonical IDs; original artifacts, scripts and commit
messages preserve their historical labels. Pre-integration test failures in
those reports precede main's TEST-1 fixes. Main's JOB-4 intentionally uses a
provider wrapper for fault injection and an explicit 272,000 context limit;
that does not preserve normal provider visibility or uncertainty accounting.
Its concurrency/job results remain bounded evidence, not a normal-provider
context-pressure experiment. JOB-5 uses the configured provider directly. The integration checkpoint in
[ROADMAP.md](../ROADMAP.md#2026-09-07-integration-checkpoint) owns current results.



## 2026-09-07: Naturally longer repository test job — JOB-8

**Question:** Does the supervised wait/completion workflow hold up on existing
repository tests whose runtime comes from real BEAM recovery work?

**Result:** Actual `gpt-5.5`/low session `iKlIQVY6UkH283wBlyGuIw` started
`mix test test/elara/context_test.exs` through one `test_job`, ended its turn,
received one automatic completion and inspected status once. All **15 tests
passed in 11,570 ms**, exit 0. The job retained all 754 output bytes and released
its settled reservation. Before/after fingerprints matched across 139 source
files, and the final status still reported unchanged source.

| Observation | Result |
| --- | --- |
| Total live workflow | 23,890 ms |
| Provider requests | 4 |
| Model test-job calls | 1 start, 1 status |
| Completion inputs / public messages | 1 / 8 |
| Waiting turn ended → completion request began | 8,715 → 17,507 ms; 8,792 ms with no new provider request |
| Provider errors / continuation prompts / polling calls | 0 / 0 / 0 |
| Artificial delays / injected faults | None |

The test file exercises persisted handoff, pause and continuation ownership,
terminal interaction, and recovery in fresh BEAM processes at six durable
stages. Its crash fixture logs an intentionally killed task; the final ExUnit
result remains a pass. The file was selected after passing on the merged tree.
It is longer than JOB-2's roughly one-second repair checks and JOB-1's delayed
fixture, but it is still an 11.57-second local job within the existing 60-second
limit. This establishes neither multi-minute reliability nor comparative
productivity. The host supplied the exact target and workflow; the model did
not discover the work or write a feature. One start and one durable job record
are observed; no physical execution counter was added to repository tests.

**Functionality added:** an opt-in reproducible live driver,
`test/support/test_job_repository_live.exs`. It requires a clean committed
checkout, records public messages and provider request timings, and stays
attached across provider errors. If interpretation fails, it can supply one
explicit continuation using retained evidence and disclose that assistance.
That fallback was not exercised in this run; JOB-3 retains the controlled
failure evidence. No harness runtime policy changed and ordinary tests remain
offline. Persisted session/job records are retained; the temporary empty skill
home was removed.

**Learning:** BEAM ownership and inbox delivery worked usefully on real restart
and handoff checks: the model could finish a turn while the command continued,
then resume with a bounded, source-identified result. The next useful experiment
is a small real feature from prompt to reviewed patch, using this workflow.
There is no observed need here for another job type or automatic retry policy.
Dedicated evals remain deferred.

The driver is published in `0b58b99` on `codex/longer-repository-test-job`, based
on main merge `63d3dab`. All five live acceptance checks pass; formatting and two
roadmap tests pass. The merge's broader checks are recorded above. Full prompt,
public transcript, job output, hashes and timings are in the
[evidence artifact](fixtures/test-job-repository-context-2026-09-07.json).


## 2026-09-07: Live line-range read feature — JOB-9

**Question:** Can a live Elara session take a small harness feature from a
supplied contract through failing tests, implementation and supervised
verification, leaving a useful patch for host review?

**Feature added:** `read` accepts optional positive integer `offset` and `limit`.
Offsets are one-based; once either field is supplied, missing values default to
1 and 200. Path-only reads retain their old whole-file behavior. Selected bytes
preserve LF/CRLF, Unicode and an unterminated last line; offsets past EOF return
empty content. Validation errors and file errors remain ordinary tool results.
The existing output cap applies; the implementation still reads the file into
memory. Read is now tool version 2, so worker version checks reject incompatible
peers rather than silently ignoring range arguments. See the README usage.

**Overall result: assisted feature completion, not one autonomous success.**

| Stage | Observed outcome |
| --- | --- |
| Initial live session `MEnvaTWeZn28OE_2ha9oOw` | Authored six regressions; one 539 ms job produced five expected failures and one compatibility pass. No runtime implementation yet. |
| Driver failure | A context handoff emitted interruption; the driver tried another prompt, received `busy`, and exited. The test and terminal job record survived. |
| First recovery | Reopened the successor and repeated the assignment. Its next handoff remained paused, as persisted input policy required; the driver waited without resuming it. |
| Second recovery | Explicit input resume and owner-following progressed through the chain, but repeated context reads reached the existing eight-handoff limit without implementation. Two generic continuation prompts did not help. |
| Fresh configured-provider session `M8baLOpgdqLVGeD55RdJnQ` | Supplied concise red-test evidence and instructions to avoid a full README reread. Authored the implementation/schema/docs, passed six tests in one 743 ms supervised job, inspected status and finished. 62,241 ms total, 13 assistant responses, 28 public messages, no handoff or further prompt. |
| Host review | Preserved the selection algorithm; strengthened schema, docs and tests, and added version-2 worker compatibility enforcement. |
| Final live tool exercise `IGAX0wnt1YKFITHnmbaDeg` | Normal configured model used read exactly once with offset 2/limit 2, receiving exact `α\r\nβ\n` bytes. Two assistant responses; pass. |

The first and fresh sessions each had one test-job start and one logical
completion. Recovery inspected the original job repeatedly across sessions but
did not execute it again. One start and durable record are observed per job;
repository tests were not instrumented with a physical execution counter.

### What the failed attempt teaches

The temporary counting provider wrapper was **not transparent**. The current
`Provider.Visibility.settings/1` recognizes the concrete Codex provider module;
the wrapper falls through to unknown settings. `Context.budget/2` therefore uses
its 128,000 fallback limit with greater uncertainty, while the normal configured
provider selects this checkout's 272,000 catalog limit. These are local harness
accounting values, not a measurement of actual provider capacity. Repeated full
reads and handoff indexes consumed the conservative budget. The successful run
changed both provider configuration and prompt/history, so it does not isolate
which intervention caused the improvement or prove normal sessions would hit
the same rollover loop.

The driver also assumed one session ID for a logical task and initially treated
handoff interruption as a provider failure. Fixing owner following was necessary
but insufficient: resumed input delivery retained its pause, and explicit input
resume was required. These are driver integration failures and useful harness
observations. They do not justify weakening pause preservation or raising the
handoff limit. Further context-policy changes need an unwrapped reproduction.

### Review, practicality and next step

The live model supplied the regression suite and all line-selection logic.
Host review found that the default-200 and final-line behavior needed stronger
coverage. Added checks cover binary/newline preservation, file errors and the
public session path. The remote worker resolves tools by name/version; leaving
read at version 1 would allow an older peer to ignore new arguments. Host work
added version 2, a real remote range test, wrong-version rejection and schema
minimums. No provider, pause, job or handoff policy changed.

This is useful functionality: agents can request a source excerpt without a
shell command or returning the whole file to model context. Its implementation
is portable Elixir code, not evidence of a unique BEAM advantage. The supervised
job retained its failed result through driver loss and later produced a verified
passing result; the difficult part of this exercise was carrying the live
workflow across context and driver boundaries.

The next recommended experiment is to make the live driver follow logical
ownership and preserve provider metadata through observation, then repeat a
small coding task. The driver follow-up is recorded below as JOB-6. Dedicated evals remain deferred.
The [public records](fixtures/read-range-feature-live-2026-09-07.json) retain
prompts, the original model patch/tests, job outputs, recovery details and the
fresh successful transcript. Provider-private state is omitted. Canonical check
counts and publication status belong to [JOB-9](../ROADMAP.md#job-9--live-feature-implementation-with-supervised-tests).


**Final verification:** 48 focused tests pass, including local/session behavior
and remote execution/version rejection. Formatting and warnings-as-errors
compilation pass. Full suite: **494/502** in 176.7 seconds; all nine added tests
pass. The eight remaining failures match the preceding 493/501 run and earlier
baseline categories, including intermittent queued-mutation recovery. All 76
local documentation links checked resolve. Temporary empty experiment homes
were removed; persisted sessions and terminal jobs remain intentional evidence.

**Publication:** implementation, tests and evidence pushed in `af9778d` on
`codex/read-line-ranges`, stacked on JOB-8 `c333213`. At that branch checkpoint it was not yet merged.

## 2026-09-07: Transparent live observation and ownership — JOB-6

**Question:** Can experiment tooling observe the normal configured provider and
follow a logical task across handoffs without altering context accounting or
silently resuming paused work?

**Functionality added:** an experiment-support observer and a refactored live
repository script. Provider configuration goes directly to `Elara.start_session`;
there is no counting provider wrapper. The observer follows durable ownership
once the successor has started and uses retained replay to handle successors
that finish before attachment. It records busy submissions, provider errors,
pauses, explicit initial resume, unavailable sessions and deadlines. It does
not change production provider, context, inbox or retry policy.

**Deterministic evidence:** the original seven regressions failed against a
stub. The completed set has 12 passing checks: normal-provider metadata and
catalog budgeting, fast finished successors, paused successor and explicit
resume, handoff during observation, busy submission, stale markers with new
prompts and active later turns, timeout without cancellation, one real job
completing after a provider error, stopped sessions, evicted replay, and a later
user pause after initial resume. The broader integration run passed 43 tests
before the final pause regression was added; the final driver-only run passed
all 12. A stale-marker regression was also observed failing before its fix.

**Learning so far:** delivery ownership is durable before the successor process
is ready, so attachment must respect activation. An old completion marker is
not enough when a newer turn has started. Provider instrumentation that changes
the provider's identity is an experimental confound. These are practical driver
corrections; the existing runtime supports the tested continuation and pause
behavior without a new scheduler or retry mechanism.

**Live verification:** normal `gpt-5.5`/low, session
`Z4RVjnphCgN00gHfyY8Nbg`, on committed driver revision `5fbd299`. The existing
15 context tests passed in **13,142 ms**; the complete interaction took
**19,805 ms**. One job start, one automatic completion, one status call, four
assistant messages, no provider errors and no added prompt or resume. All six
acceptance checks pass. The job is settled, its slot released and source hashes
unchanged. Both initial and final snapshots retain model/effort and this
checkout's **272,000** conservative catalog budget. No live handoff was needed;
this run verifies integration, while deterministic tests cover handoff races.

The observer recorded 104 events and two single-sequence gaps (28 and 31).
Protocol-v1 suppresses live inbox-change events; these gaps remain visible in
the evidence rather than being silently called a complete event history. Event
timestamps mean observation time; replay timestamps do not reconstruct the
original event time. Message counts do not measure physical provider requests.

**Assessment:** worthwhile as experiment infrastructure. The runtime already
provided durable jobs, logical ownership, retained replay and pause semantics;
the driver now uses those mechanisms without changing provider identity. This
makes subsequent coding experiments easier to interpret. It does not establish
better coding quality, faster inference, a unique BEAM productivity advantage,
or successful normal-provider continuation under heavy context pressure.

**Final checks and publication:** 12 driver regressions pass. Full suite:
**506/514** in 182.6 seconds, with the same eight named baseline failures as
JOB-9. Formatting, warnings-as-errors compilation and local review pass. Code
is pushed in `dbc832a` and `5fbd299` on `codex/live-driver-ownership`, stacked on
JOB-9; not yet merged at that branch checkpoint. The temporary empty home is removed and persistent
session/job evidence is retained. The [public artifact](fixtures/live-driver-ownership-2026-09-07.json)
contains the prompt, per-session public transcript, metadata, job output, gaps
and check results. Canonical status belongs to
[JOB-6](../ROADMAP.md#job-6--live-driver-metadata-and-logical-ownership).
Dedicated evals remain deferred. The follow-up coding experiment is recorded below as JOB-7, retaining the full
attempt and explicit assistance to reassess the JOB-9 workflow.

## 2026-09-07: Live exact-text replace-all feature — JOB-7

**Question:** With provider identity preserved and logical ownership observed,
can a live Elara session complete a small harness feature from a supplied
contract through red tests, implementation and green verification?

**Result: one successful bounded coding attempt.** On driver commit `5dd4a7f`,
normal `gpt-5.5`/low session `v6glZVyihHmzf1VGsCpSWA` completed the assignment in
**86,051 ms**. There was one initial host prompt, no continuation prompt, no
provider error, no resume and no handoff. The model authored all runtime/schema
changes and the initial five regressions. Host review retained its implementation.

| Stage | Observed evidence |
| --- | --- |
| Tests first | New focused test file; red job ran in 514 ms: four expected failures and one compatibility pass. |
| Red completion | One automatic inbox input and one status call; implementation followed the retained failure evidence. |
| Implementation | Opt-in boolean `replace_all`, empty-pattern and invalid-flag errors, edit tool version 2, schema and README usage. |
| Green completion | New job ran in 716 ms: all five tests passed, followed by one automatic completion and one status call. |
| Host review | Added four local/public tests, one authenticated remote-worker test and fuller usage/limits documentation. All 26 focused checks pass. |
| Fresh-process live acceptance | Session `vmpuZNCszWse51-ctnqM-g` invoked edit version 2 once with `replace_all: true`; exact result `new\r\nα new\nnew`, all five checks pass in 3,924 ms. |

The attempt produced 15 assistant messages across three inputs (4, 9 and 2),
15 tool calls (four reads, one write, five edits, one formatting command and
four test-job calls), and two durable completion inputs. Both jobs settled and
released their slot. Source stayed unchanged during each job. The red result
correctly became stale after implementation; the green result matched current
source at capture. These are observed starts and durable records; no physical
execution counter was inserted into repository tests.

**Functionality added:** `edit.replace_all` is optional and defaults to false.
Default/false still requires one exact match. True replaces every non-overlapping
literal occurrence in one pass, including deletion via empty `new_text`.
Invalid flags, empty `old_text`, missing matches and ambiguous default requests
fail without mutation. Empty patterns previously raised from `:binary.matches`;
they now produce an ordinary tool error. File bytes and line endings are
preserved. The remote check performs a version-2 edit in the worker workspace
and rejects a version-1 request without further mutation. This remains a
whole-file, non-atomic read/write with existing capabilities and confinement;
there is no new transactional or crash-recovery guarantee. See [README usage](../README.md#built-in-tools).

**Assistance and limits:** the host selected the feature, supplied a detailed
contract, source pointers, a test-first sequence and fixed job IDs. The session
had five selected tools, an empty user-skill catalog and a 32-iteration turn
limit; no turn used more than nine assistant responses. The host reviewed and
strengthened the patch afterward. This was not an unassisted discovery task or
an eval/benchmark. No context handoff was needed: the conservative estimate grew
from 9,843 to 60,976 within the retained 272,000 local catalog limit. The observer
recorded 186 events and five sequence gaps; protocol-v1 omits live inbox changes.
We do not infer complete event history or physical network counts from these
observations.

**Assessment:** useful functionality and encouraging workflow evidence. A normal
session carried two supervised jobs from red to green without operator recovery,
and its implementation survived review. The supervised job/inbox mechanisms
supported the workflow; replace-all itself is ordinary portable Elixir code.
The different feature, detailed prompt and bounded context mean this is not a
controlled comparison proving that the JOB-6 driver caused success or that
heavy-context handoff issues are resolved. Keep the driver and feature; there
is no new evidence here requiring a different runtime scheduler or retry policy.

The [public artifact](fixtures/edit-replace-all-live-2026-09-07.json) retains the
exact prompt, original model patch and test file, public transcript, job output,
metadata, acceptance script and host checks. Provider-private state is omitted.
For historical red→green reproduction, use a separate checkout of `5dd4a7f`
and run `mix run test/support/edit_replace_all_live.exs /tmp/edit-replace-all.json`;
each invocation performs real model calls and creates a new coding attempt.
The current feature checkout already contains the implementation.

**Final verification:** 26 focused tests pass. Full suite: **516/524** in
182.0 seconds; all ten added tests pass and the same eight named JOB-6 baseline
failures remain. Formatting, warnings-as-errors compilation, local review and
81 local documentation links pass. Temporary fixture/home directories are
removed; the original coding session and terminal jobs remain as evidence.
Feature and review checks are pushed in `e9bf355` on `codex/edit-replace-all`,
stacked on JOB-6 at that branch checkpoint. Canonical checkpoint:
[JOB-7](../ROADMAP.md#job-7--live-edit-replace_all-feature).
Dedicated evals remain deferred.


## 2026-09-07: Combined experiment integration

Merge `306ca87`, pushed to main, combines main `59aefa7` with feature stack `5bef91a`.
The complete combined suite passes **529/529 Mix tests** and **121 Rust tests**;
72 focused integration checks pass. Main's TEST-1 fixes resolve the eight
failures retained in the earlier branch reports. No runtime merge conflict or
new provider/context policy change was required. The two documentation ID
collisions are reconciled above; original artifacts remain unchanged. Test
fixture isolation and exact support-script discovery filters were aligned with
main. See the [integration checkpoint](../ROADMAP.md#2026-09-07-integration-checkpoint)
for publication status and verification limits. No new live inference was run.
