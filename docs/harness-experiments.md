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


## 2026-09-07: Naturally longer repository test job — JOB-4

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
