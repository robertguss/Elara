# Diagnose a captured failed check

Elara can retain a project check's output and selected source excerpts, then
diagnose that evidence with one additional model request. The first strategy
is `direct/v1`, with the fixed result contract `check_diagnosis/v1`. This is the
first implemented slice of the [DSPy research proposal](features-research/dspy-for-elara-2026-09-06.md).

## Try it

Start Elara from the updated checkout. The project plugin must be loaded at
version 3; see [plugin discovery and reload](plugins.md) for another Mix project.
`/plugins reload` activates a revised plugin between turns in a session using
default discovery. Restart Elara to load changes to the harness itself.

Ask the agent:

> Run `elixir_test` for `test/example_test.exs:12`, selecting
> `lib/example.ex` and `test/example_test.exs` as `evidence_paths`.
> If it fails, use `diagnose_check` once with the returned `evidence_run_id`.
> Explain the observed failure, likely cause, supporting evidence, unknowns,
> and suggested next check.

Replace those paths with a small relevant test and implementation. Explicitly
selecting files matters: a focused test captures its test file by default;
it does not automatically find the implementation. `elixir_check` also accepts
`evidence_paths`. `elixir_rerun_last` uses the remembered arguments and captures
the files again before running the command again.

The agent can use these built-in tools:

| Tool | Input | Result |
| --- | --- | --- |
| `check_evidence` | `{}` | Latest captured run ID and artifact manifest, including clipping and line counts. |
| `check_evidence` | `run_id`, `artifact_id`, optional `start_line` | Up to 20 original captured lines. |
| `diagnose_check` | Required `run_id` | One direct diagnosis, or an explicit failure. |

In the Rust TUI, press Tab to focus the transcript, search for `diagnose_check`,
finish the search with Escape, and press `f` to open its tool viewer. Search for
`direct/v1`, inspect the result and cited excerpts, or press `y` to copy the
retained report. Escape returns to the transcript; Tab returns to the composer.
The same generic inspector handles `check_evidence` results. There is no new
custom panel or strategy selector in this slice.

## Evidence and acceptance

Selected source is read **before** the command, using the native bounded file
reader. It retains at most four workspace-relative regular UTF-8 files, with
4,096 bytes per excerpt. Unsafe or unreadable selections reject the check
before execution. Duplicate selections retain one artifact.

The completed check retains at most 8,192 bytes of combined output and command
metadata, using head/tail excerpts with an explicit omission marker. Invalid
output bytes are replaced with U+FFFD and `output_encoding_repaired` records
that repair. `command` is the project plugin's label; `commands` contains the
actual executable and argument arrays. Aggregate `elixir_check:all` output
includes each constituent check's exit status.

Each run has a unique ID. Artifact IDs hash the captured name, kind, content
and clipping flag. They identify the retained excerpt, not a Git commit or the
whole file. Source observations compare the excerpts before and after the
command. `unchanged_in_captured_excerpt` says nothing about later edits or bytes
outside the excerpt. This is not an atomic workspace snapshot.

The diagnosis receives only that bundle, numbered lines, the session's captured
instructions/settings, and **no tools**. The accepted `result` has exactly:

| Field | Contract |
| --- | --- |
| `observed_failure` | Nonempty text, at most 1,000 UTF-8 bytes. |
| `likely_cause` | A hypothesis of at most 1,000 bytes, or `null`. |
| `supporting_evidence` | One to five artifact/line references, each wholly within its captured artifact. |
| `unknowns` | Up to six nonempty strings, at most 500 bytes each. |
| `next_check` | A suggestion of at most 1,000 bytes, or `null`; it is not executed. |

Missing fields, extra fields, invalid references, oversized text and proposed
tool calls are rejected. A passed check is not sent for failure diagnosis.
Missing or mismatched run IDs fail before making a model request. The host
checks structure and reference bounds; it cannot establish that a cause is
correct or that a cited passage actually supports the claim.

The report records contract/strategy revisions, invocation and run IDs,
request settings, response model, request duration, reported usage, and cited
excerpts. Each citation preview is capped at 512 UTF-8 bytes and marked when
clipped; a valid reference may span any captured line range. Use `check_evidence`
to inspect the retained evidence beyond that preview. Invalid model text remains
inspectable up to 2,048 bytes with a rejection reason. There is no automatic repair, retry, or acceptance based on
the model's confidence. Private provider state and reasoning are not copied
into the report.

## Lifetime, cancellation and cost

The session owns evidence and acceptance. The existing supervised tool task
performs the model request; other sessions can continue independently. Interrupt
terminates that diagnosis worker. Results and provider updates must come from
the currently tracked worker and invocation; a cancelled or older invocation
cannot publish a late accepted result. Crash, timeout and cancellation leave
the captured evidence available for a later explicit attempt.
Local cancellation cannot guarantee that the provider stops remote computation.

One `diagnose_check` invocation adds one provider call. Ordinary agent requests
before and after it are additional calls. The usual tool deadline applies
(30 seconds by default; API `tool_timeout_ms` can raise it). Reported diagnosis
usage enters the canonical transcript, persistence and TUI totals, including
invalid responses and interruption after usage has arrived. Usage that the
provider never returns remains unknown. There is no new global token budget.

Only the latest completed capture is active in a session. Persistent sessions
retain it across restart and later source edits. A new capture replaces it;
old tool reports and their included excerpts remain in history. Rewind clears
the active capture, and clone/fork start without one. Resuming another saved
session adopts that session's capture. These conservative rules avoid treating
evidence from an abandoned branch as current; rerun a check to capture again.

The project plugin still executes Mix through its existing `System.cmd` path.
The evidence limits bound retained excerpts, not that command's full output
allocation or external effects. This feature does not add background command
ownership or automatic command recovery.

## Experiment scope

See [the recorded experiment](harness-experiments.md#2026-09-07-captured-check-diagnosis--diag-1)
for live observations and assistance. Scripted integration tests exercise real
Mix failure, source mutation, restart, history changes, invalid output,
concurrent sessions, cancellation, worker crash and recorder replay. A real
Rust PTY check searches, redraws and copies the diagnosis and submits the
preserved draft. Physical-key acceptance remains separately owner-deferred.

Curated examples, an RLM implementation, GEPA, strategy selection and automatic
optimization remain unimplemented. Removing the arbitrary citation-span limit
accepted both saved responses on revalidation and one fresh direct live response.
That corrects an acceptance-policy mistake; this single assisted fixture does
not establish general diagnostic quality or a need for curated examples.
