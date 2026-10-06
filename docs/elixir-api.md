# Elixir API

Use the public API when embedding Elara in another Elixir application, targeting
a directory other than the Elara checkout, customizing tools, or using advanced
runtime features.

## Start a session and ask

Start the `:elara` application, then create a session with an absolute working
directory:

```elixir
Application.ensure_all_started(:elara)

{:ok, session} =
  Elara.start_session(cwd: "/absolute/path/to/project")

{:ok, answer} = Elara.ask(session, "summarize the current changes")
```

If `provider:` is omitted, `ELARA_PROVIDER=openai-codex` explicitly selects
saved ChatGPT/Codex subscription credentials. Otherwise Elara resolves
`ELARA_API_KEY`, then `XAI_API_KEY`, then saved Grok login tokens. `Elara.ask/3`
blocks until the turn ends and returns one of:

```elixir
{:ok, final_text}
{:error, :busy}
{:error, :turn_limit}
{:error, :interrupted}
{:error, {:provider_error, error}}
```

One session runs one turn at a time. Use separate sessions for parallel turns.

## Subscribe to events

```elixir
{:ok, session} = Elara.start_session(cwd: "/absolute/path/to/project")
:ok = Elara.subscribe(session)
:ok = Elara.ask_async(session, "run the tests and explain any failures")

receive do
  {:elara, ^session, {:turn_ended, outcome}} -> outcome
end
```

Events include `{:turn_started, prompt}`, message appends, tool starts, and
`{:turn_ended, outcome}`. Call `Elara.interrupt(session)` to cancel the active
turn. `Elara.transcript/1` returns the current message path.

Public session calls use stable string IDs. `Elara.session_pid/1` resolves an ID
only when code needs to monitor or explicitly stop the underlying process.

Repository plugins require explicit approval of their exact source bytes,
including when selected through `plugins:`. See [plugin trust](plugins.md).
`Elara.Server.start/1` and `start_link/1` require `token:` (32–512 bytes) or
`ELARA_SERVER_TOKEN`; clients include that token on their first request.

## Session options

`Elara.start_session/1` accepts:

| Option                   | Default                            | Purpose                                                                            |
| ------------------------ | ---------------------------------- | ---------------------------------------------------------------------------------- |
| `cwd:`                   | `File.cwd!()`                      | Working directory for prompt rules, local tools, plugins, and session scope.       |
| `provider:`              | resolved auth configuration        | `{provider_module, provider_config}`.                                              |
| `tools:`                 | `Elara.Tool.builtins()`            | Tools exposed to the model.                                                        |
| `plugins:`               | discovered under `.elara/plugins/` | Explicit plugin paths; `[]` disables plugins.                                      |
| `system:`                | built-in coding-agent prompt       | Base prompt override; scoped project instructions and skill metadata are appended. |
| `skill_paths:`           | `ELARA_SKILL_PATHS`                | Ordered explicit skill directories/containers, ahead of project and user skills.   |
| `home:`                  | `System.user_home!()`              | User skill discovery home; useful for isolated embedded sessions/tests.            |
| `max_iterations:`        | `12`                               | Maximum provider calls in a turn.                                                  |
| `tool_timeout_ms:`       | `30_000`                           | Timeout for each tool call.                                                        |
| `max_tool_output_bytes:` | `16_384`                           | Tool-result bytes retained in history.                                             |
| `persist:`               | `true`                             | Write session JSONL and flight recording; `false` keeps both in memory.            |
| `resume:`                | `nil`                              | `:latest` for the newest cwd-scoped session, or an explicit session path.          |
| `name:`                  | `nil`                              | Display name for a new persisted session.                                          |
| `allowed_capabilities:`  | `:all`                             | Capability names allowed before executor routing.                                  |
| `workspace_id:`          | derived from `cwd`                 | Logical workspace identity used for remote routing.                                |
| `router:`                | `Elara.Executor.Router`            | Executor router process or registered name.                                        |

`persist: false` cannot be combined with `resume:`. The one-shot Mix task sets
`persist: false`; direct API sessions and interactive chat persist by default.

Default sessions provision a supervised durable local executor for the exact
built-in `write` tool. Its public `%{"path" => path, "content" => content}`
arguments and successful `"wrote N bytes to path"` result are unchanged, but the
write is now an atomic workspace-confined declarative operation with durable
intent, callback-attempt, and terminal evidence. Resuming a persisted session
reconciles an unresolved write without blindly retrying it. Custom tools,
`edit`, `bash`, plugins, and remote execution do not yet use this production
receipt path. The confinement is enforced by the session/declarative-write path,
not by calling the low-level `Elara.Tools.write/2` helper directly.

Receipt callbacks run in workers linked to the single serial executor writer.
Worker loss while that writer survives commits an indeterminate terminal;
writer loss leaves an attempted receipt unresolved and prevents reinvocation.
This lifetime rule does not prove whether external side effects completed.

## Bounded command output

`Elara.Exec.run(argv, cwd: path)` defaults to killing the command at the output
cap. For a trusted background job, `output_policy: :head_tail` keeps draining
until exit, deadline or cancellation and retains a bounded prefix and suffix:

```elixir
Elara.Exec.run(["mix", "test", "test/example_test.exs"],
  cwd: "/absolute/project", output_policy: :head_tail,
  max_bytes: 16_384, timeout_ms: 60_000)
```

The result's `output_capped` flag identifies omitted bytes; head/tail output
joins two retained parts when capped. `bytes_total` counts drained output and
`bytes_sent` counts retained bytes, including the terminal suffix. The actual
exit/deadline/cancellation still determines termination. An older execution
stub rejects head/tail before submission and remains usable with the default.

## Durable local jobs

The built-in `job` tool and `Elara.Jobs.run/2` start, inspect or cancel a declared
local job in a persistent session's workspace. `start` takes a stable `job_id`,
`profile` and JSON `arguments`; status/cancel need only action and job ID.
The built-in `mix_test` profile takes `%{"target" => "test/example_test.exs"}`,
uses `mix test` with a 60-second deadline and 16,384-byte head/tail reporting.
The existing `test_job` tool remains an alias with its original target argument.
Both entries share identity, capacity, durable records and completion delivery.

Trusted owner configuration can add `%Elara.Jobs.Profile{}` declarations through
`:elara, :job_profiles` or the manager's `profiles:` start option. Each supplies
`name`, `validate`, `argv`, `timeout_ms`, `max_bytes`, `output_policy` and optional
`fingerprint`. Validation/argv callbacks take `(cwd, arguments)`; validation
returns `:ok` or `{:error, reason}`, and argv returns strings without NUL bytes.
An optional fingerprint callback takes cwd and returns
`%{"sha256" => digest, "files" => count, "scope" => scope}` or an error map.
These callbacks are trusted local code and should only validate/build argv or
read source evidence. Tool arguments cannot register executable declarations.
Invalid declarations or duplicate names, including `mix_test`, prevent startup.

New v2 records freeze the profile, arguments, argv, deadline, reporting policy
and correlation ID before dispatch. Duplicate starts return the same record;
a different profile or arguments with the same owner/job ID conflict. v1
records retain their original completion payload and never replay uncertain
execution. Command/runner loss is indeterminate; an output cap does not make
head/tail jobs successful or stop their process. Native output remains bounded;
not-started/indeterminate diagnostics have a separate text bound. A missing or
unavailable source fingerprint, or comparing different source scopes, reports
`"unknown"`. Admission and callback fingerprints remain fixed for the run.
Completions use the durable inbox and one correlated wait path:

```elixir
Elara.Completion.wait(session_id, "job", "test-1")
Elara.Completion.wait(parent_id, "thread", child_id)
Elara.Threads.Communication.wait(parent_id, child_id) # includes thread status
```

These observer calls return `{:ok, response}` without consuming the input. The
model-facing `completion_wait` tool takes `source` and `job_id` or `thread_id`;
`thread_wait` aliases the thread path. Only the executing session's live tool
claim consumes its report, atomically with the saved ToolResult. Results carry
`awaited`, `already_consumed`, `correlation`, `input_id`, receipt state/error and
an explicitly bounded untrusted preview. Cancelled input returns an error;
failed processing keeps its original receipt. Repeated observations do not
replay work. Own-job and direct-related-thread checks remain authoritative.

Attached protocol v2 clients can send `job_status` with `job_id` to inspect
their own logical session's job; observers are allowed. The controller-only
`job_acknowledge_stopped` command additionally requires `confirm_stopped: true`
and the operator's confirmation that the command and descendants have stopped.
Both return `job_result` with the existing record under `result`; IDs are
nonempty strings of at most 128 bytes. `Elara.Jobs.acknowledge_stopped/2` remains
the settlement authority: it rejects known pending execution and releases only
an indeterminate reservation. Status/outcome and original inbox evidence remain
unchanged; acknowledgment never retries a command or consumes its completion.

There is no ordinary tool execution deadline on a completion wait. Interrupt
cancels waiting without cancelling the job; caller/target/transport loss retires
subscriptions. VM loss never replays uncertain execution. Thread identity uses
the logical source and active User entry ID; handoff carries that occurrence,
and new input gets another ID. Missing legacy outer correlation can be added
to an identical retained input; bodies, evidence and typed agent provenance
remain unchanged. Conflicting correlation rejects rather than replacing it.

## Custom tools

A tool is a `%Elara.Tool{}` with a JSON Schema and a module/function pair of
arity 2:

```elixir
defmodule ProjectTools do
  def test(_arguments, context) do
    {output, status} =
      System.shell("mix test", cd: context.cwd, stderr_to_stdout: true)

    if status == 0, do: {:ok, output}, else: {:error, output}
  end
end

tools =
  Elara.Tool.builtins() ++
    [
      %Elara.Tool{
        name: "test",
        description: "Run the project test suite.",
        parameters: %{
          "type" => "object",
          "properties" => %{},
          "additionalProperties" => false
        },
        run: {ProjectTools, :test},
        capabilities: ["shell"],
        mutating: true
      }
    ]

{:ok, session} = Elara.start_session(tools: tools)
```

The function receives `(arguments, %Elara.Tool.Ctx{})` and returns
`{:ok, text}`, `{:error, text}`, or `{:indeterminate, text}`. Duplicate tool
names are rejected at session startup.

For reloadable stateful tools, use [live plugins](plugins.md).

## Persistence operations

```elixir
Elara.list_sessions("/absolute/path/to/project")
Elara.name_session(session, "parser fix")
Elara.user_entries(session)
Elara.resume(session, session_file_path)
Elara.tree(session, user_entry_id)
Elara.fork(session, user_entry_id)
Elara.clone_session(session)
```

These operations are scoped to the same working directory and require the
session to be idle. `tree/2` branches in the current file; `fork/2` and
`clone_session/1` switch the live session to a newly created file.

## Recordings, status, and replay

```elixir
status = Elara.status(session)
recording = Elara.recording(session)

{:ok, %{status: :match}} = Elara.replay(recording)
{:ok, explanation} = Elara.why(session)
{:ok, explanation} = Elara.why(session, status.event_head)
```

`status/1` reports the current phase/effect, mailbox and task counts,
subscribers, retained event range, worker health, and recording path/count. It
also reports `instructions` (absolute paths mapped to loaded text or a read
diagnostic) and `skills` (metadata-only selected sources and discovery
diagnostics). See
[instruction and skill behavior](../README.md#project-instructions-and-agent-skills).
Skill instructions enter ordinary tool-result history only when the `skill` tool
is used. They obey `max_tool_output_bytes`; unusually large skills should split
supporting material into references that the model can read on demand.

Persistent recordings are versioned `.flight` files beside session JSONL files:

```elixir
{:ok, recording} = Elara.FlightRecorder.load(status.recording_path)
{:ok, report} = Elara.replay(status.recording_path)
```

Replay invokes the pure session core only; it does not call the provider or run
tools. Pass `step: &OtherCore.step/2` to compare another implementation, or an
`inject:` map to insert, replace, or drop facts during replay.

## Delegate child sessions

Use the durable Threads lifecycle to delegate an assignment:

```elixir
{:ok, child} = Elara.Threads.start_child(session, "Inspect the failing test")
Elara.Threads.list(session)
```

Pass `coding: true` for a managed Git branch/worktree. Children remain independent
of parent stop/detach; stopping a child does not remove its workspace. See the
[delegation and integration boundaries](../README.md#persistent-delegated-children) before
integrating changes or cleaning up a worktree.

The former `Elara.start_coordinator/2` and `Elara.Coordinator` API were retired
under ROB-1095/LAB-6. Its batch concurrency/token/time budgets, automatic
candidate judging and map/reduce are deliberately removed. Threads does not
provide those batch patterns or aggregate budgets.

See [Detached sessions and remote workers](detached-and-remote.md) to route
tools by capability and workspace.
