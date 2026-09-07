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
