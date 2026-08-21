# Elixir API

Use the public API when embedding Harness in another Elixir application,
targeting a directory other than the Harness checkout, customizing tools, or
using advanced runtime features.

## Start a session and ask

Start the `:harness` application, then create a session with an absolute working
directory:

```elixir
Application.ensure_all_started(:harness)

{:ok, session} =
  Harness.start_session(cwd: "/absolute/path/to/project")

{:ok, answer} = Harness.ask(session, "summarize the current changes")
```

If `provider:` is omitted, Harness resolves `HARNESS_API_KEY`, then
`XAI_API_KEY`, then saved Grok login tokens. `Harness.ask/3` blocks until the
turn ends and returns one of:

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
{:ok, session} = Harness.start_session(cwd: "/absolute/path/to/project")
:ok = Harness.subscribe(session)
:ok = Harness.ask_async(session, "run the tests and explain any failures")

receive do
  {:harness, ^session, {:turn_ended, outcome}} -> outcome
end
```

Events include `{:turn_started, prompt}`, message appends, tool starts, and
`{:turn_ended, outcome}`. Call `Harness.interrupt(session)` to cancel the active
turn. `Harness.transcript/1` returns the current message path.

Public session calls use stable string IDs. `Harness.session_pid/1` resolves an
ID only when code needs to monitor or explicitly stop the underlying process.

## Session options

`Harness.start_session/1` accepts:

| Option                   | Default                              | Purpose                                                                      |
| ------------------------ | ------------------------------------ | ---------------------------------------------------------------------------- |
| `cwd:`                   | `File.cwd!()`                        | Working directory for prompt rules, local tools, plugins, and session scope. |
| `provider:`              | resolved auth configuration          | `{provider_module, provider_config}`.                                        |
| `tools:`                 | `Harness.Tool.builtins()`            | Tools exposed to the model.                                                  |
| `plugins:`               | discovered under `.harness/plugins/` | Explicit plugin paths; `[]` disables plugins.                                |
| `system:`                | built-in prompt plus `cwd/AGENTS.md` | Complete system prompt override.                                             |
| `max_iterations:`        | `12`                                 | Maximum provider calls in a turn.                                            |
| `tool_timeout_ms:`       | `30_000`                             | Timeout for each tool call.                                                  |
| `max_tool_output_bytes:` | `16_384`                             | Tool-result bytes retained in history.                                       |
| `persist:`               | `true`                               | Write session JSONL and flight recording; `false` keeps both in memory.      |
| `resume:`                | `nil`                                | `:latest` for the newest cwd-scoped session, or an explicit session path.    |
| `name:`                  | `nil`                                | Display name for a new persisted session.                                    |
| `allowed_capabilities:`  | `:all`                               | Capability names allowed before executor routing.                            |
| `workspace_id:`          | derived from `cwd`                   | Logical workspace identity used for remote routing.                          |
| `router:`                | `Harness.Executor.Router`            | Executor router process or registered name.                                  |

`persist: false` cannot be combined with `resume:`. The one-shot Mix task sets
`persist: false`; direct API sessions and interactive chat persist by default.

## Custom tools

A tool is a `%Harness.Tool{}` with a JSON Schema and a module/function pair of
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
  Harness.Tool.builtins() ++
    [
      %Harness.Tool{
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

{:ok, session} = Harness.start_session(tools: tools)
```

The function receives `(arguments, %Harness.Tool.Ctx{})` and returns
`{:ok, text}`, `{:error, text}`, or `{:indeterminate, text}`. Duplicate tool
names are rejected at session startup.

For reloadable stateful tools, use [live plugins](plugins.md).

## Persistence operations

```elixir
Harness.list_sessions("/absolute/path/to/project")
Harness.name_session(session, "parser fix")
Harness.user_entries(session)
Harness.resume(session, session_file_path)
Harness.tree(session, user_entry_id)
Harness.fork(session, user_entry_id)
Harness.clone_session(session)
```

These operations are scoped to the same working directory and require the
session to be idle. `tree/2` branches in the current file; `fork/2` and
`clone_session/1` switch the live session to a newly created file.

## Recordings, status, and replay

```elixir
status = Harness.status(session)
recording = Harness.recording(session)

{:ok, %{status: :match}} = Harness.replay(recording)
{:ok, explanation} = Harness.why(session)
{:ok, explanation} = Harness.why(session, status.event_head)
```

`status/1` reports the current phase/effect, mailbox and task counts,
subscribers, retained event range, worker health, and recording path/count.

Persistent recordings are versioned `.flight` files beside session JSONL files:

```elixir
{:ok, recording} = Harness.FlightRecorder.load(status.recording_path)
{:ok, report} = Harness.replay(status.recording_path)
```

Replay invokes the pure session core only; it does not call the provider or run
tools. Pass `step: &OtherCore.step/2` to compare another implementation, or an
`inject:` map to insert, replace, or drop facts during replay.

## Coordinate child sessions

Coordinators run bounded child sessions without adding their transcripts to the
parent:

```elixir
{:ok, coordinator} =
  Harness.start_coordinator(session,
    max_concurrency: 3,
    token_budget: 20_000,
    time_budget_ms: 120_000
  )

{:ok, run} =
  Harness.Coordinator.run(
    coordinator,
    :candidates,
    [
      %{id: "a", role: :coding, prompt: "Implement candidate A"},
      %{id: "b", role: :coding, prompt: "Implement candidate B"}
    ],
    judge: %{
      id: "judge",
      role: :judge,
      prompt: "Return the winning candidate ID."
    }
  )
```

Supported patterns are `:parallel`, `:specialists`, `:candidates` with a
`judge:`, and `:map_reduce` with a `reducer:`. Child specs require `id:` and
`prompt:`; `role:` defaults to `:general`. Coding roles receive detached git
worktrees, so the parent `cwd` must be a Git checkout.

`Harness.Coordinator.status/1` reports children and live budgets.
`Harness.Coordinator.kill_child/2` stops one child without stopping siblings.
Call `GenServer.stop(coordinator)` when finished to stop its children and remove
temporary coding worktrees.

See [Detached sessions and remote workers](detached-and-remote.md) to route
tools by capability and workspace.
