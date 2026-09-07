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

**Live result: both responses were rejected.** Two assisted runs used actual
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
improvement. The acceptance limit was kept intact; no automatic repair or
hidden retry was added.

**Assistance:** each run used a supplied minimal project, selected source files,
and two explicit owner prompts: run only the check, then diagnose that run once.
The operator inserted the missing clause after capture and separately verified
the current workspace passed after diagnosis. That deliberate edit tested
historical evidence; the model did not make the fix. Each run included four
ordinary assistant responses in addition to the one direct diagnosis request.
The full prompts, captured excerpts, raw rejected responses, final replies and
usage totals are retained in [the live records](features-research/check-diagnosis-live-runs.json).

**Learning:** supervised execution, immutable evidence and explicit acceptance
make a failed model operation inspectable. They do not make its output comply
with a schema or prove its causal claims. The direct strategy has not produced
an accepted live result in this exercise. A useful next comparison would add a
few curated examples while preserving the contract and recording failures as
well as successes. No example strategy, RLM, GEPA or optimizer is implemented,
and there is no broad evaluation program or throughput claim.

Guide: [captured check diagnosis](check-diagnosis.md). Publication and shared
verification results: [DIAG-1 in the roadmap](../ROADMAP.md#diag-1--diagnose-a-captured-failed-check).

## Separate candidate: supervised test completion and agent wakeup

**Proposal, not implementation authorization.** Run one focused test command as
an explicitly owned background job. Let the agent wait without polling the
model; deliver its completion through the existing inbox so the agent can
inspect the evidence and continue the coding task.

This follows the observed failure to retain fixtures through ordinary `bash`
calls. Keep that tool's process-group cleanup intact. A managed job needs an
explicit lifetime and cancellation contract; adding `nohup` is not that contract.
Existing thread waits, completion delivery, stable input IDs and wake budgets
are the starting points. General execution-job completion delivery is new work.

**First useful slice:** one local Mix test target, a stable job ID, bounded
output, recorded exit status, a workspace/source identity, explicit cancellation,
and one logical completion input. Display the job and outcome through existing
tool results and history before designing a new inspector.

**Acceptance exercise:**

1. Start the focused job and wait. Another session stays usable and the waiting
   agent makes no model requests merely to poll for completion.
2. Deliver completion twice. Accept one logical input and retain inspectable
   output; do not run the test command a second time.
3. Pause/stop the recipient before completion. Preserve evidence without waking
   it against the owner's instruction; explicit resume can consume the result.
4. Cancel or crash the runner. Report cancellation/failure/uncertainty honestly;
   supervision must not blindly replay a command with possible side effects.
5. Change the relevant source while the job runs. Mark the result as evidence
   for the captured source identity, not proof that the new source passes.

**Feasibility:** medium for this bounded slice. The difficult parts are lifetime,
delivery, cancellation and source identity, not spawning a Task. Initially
limit execution to one live Elara runtime; VM loss must not imply automatic
command retry. Durable resumption of execution, arbitrary daemons, cron,
distributed jobs and generic exactly-once effects are separate work.

**BEAM question:** can independently supervised work and message delivery make
agent waiting useful and understandable without adding another authority for
session state? **Practical question:** can a test finish and bring the agent
back with sufficient evidence, without operator-managed fixtures or repeated
polling? Passing these exercises would justify trying the workflow on real
coding work; it would not establish comparative speed or cost savings.

This recommendation favors friction observed in the live experiment. Earlier
[harness research](features-research/harness-ideas-beam-2026-09-06.md) also proposes
background context preparation and a completion-event adapter. The newer
[DSPy investigation](features-research/dspy-for-elara-2026-09-06.md) proposes a
typed evidence-analysis operation. Those remain distinct candidates; neither
has been implemented or silently substituted into the roadmap queue.
