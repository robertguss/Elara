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

## Session options

`Elara.start_session/1` accepts:

| Option                   | Default                              | Purpose                                                                      |
| ------------------------ | ------------------------------------ | ---------------------------------------------------------------------------- |
| `cwd:`                   | `File.cwd!()`                        | Working directory for prompt rules, local tools, plugins, and session scope. |
| `provider:`              | resolved auth configuration          | `{provider_module, provider_config}`.                                        |
| `tools:`                 | `Elara.Tool.builtins()`              | Tools exposed to the model.                                                  |
| `plugins:`               | discovered under `.elara/plugins/`   | Explicit plugin paths; `[]` disables plugins.                                |
| `system:`                | built-in prompt plus `cwd/AGENTS.md` | Complete system prompt override.                                             |
| `max_iterations:`        | `12`                                 | Maximum provider calls in a turn.                                            |
| `tool_timeout_ms:`       | `30_000`                             | Timeout for each tool call.                                                  |
| `max_tool_output_bytes:` | `16_384`                             | Tool-result bytes retained in history.                                       |
| `persist:`               | `true`                               | Write session JSONL and flight recording; `false` keeps both in memory.      |
| `resume:`                | `nil`                                | `:latest` for the newest cwd-scoped session, or an explicit session path.    |
| `name:`                  | `nil`                                | Display name for a new persisted session.                                    |
| `allowed_capabilities:`  | `:all`                               | Capability names allowed before executor routing.                            |
| `workspace_id:`          | derived from `cwd`                   | Logical workspace identity used for remote routing.                          |
| `router:`                | `Elara.Executor.Router`              | Executor router process or registered name.                                  |

`persist: false` cannot be combined with `resume:`. The one-shot Mix task sets
`persist: false`; direct API sessions and interactive chat persist by default.

Default sessions provision a supervised durable local executor for the exact
built-in `write` tool. Its public `%{"path" => path, "content" => content}`
arguments and successful `"wrote N bytes to path"` result are unchanged, but the
write is now an atomic workspace-confined declarative operation with durable
intent, callback-attempt, and terminal evidence. Resuming a persisted session
reconciles an unresolved write without blindly retrying it. Custom tools,
`edit`, `bash`, plugins, and remote execution do not yet use this production
receipt path.

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
subscribers, retained event range, worker health, and recording path/count.

Persistent recordings are versioned `.flight` files beside session JSONL files:

```elixir
{:ok, recording} = Elara.FlightRecorder.load(status.recording_path)
{:ok, report} = Elara.replay(status.recording_path)
```

Replay invokes the pure session core only; it does not call the provider or run
tools. Pass `step: &OtherCore.step/2` to compare another implementation, or an
`inject:` map to insert, replace, or drop facts during replay.

## Coordinate child sessions

Coordinators run bounded child sessions without adding their transcripts to the
parent:

```elixir
{:ok, coordinator} =
  Elara.start_coordinator(session,
    max_concurrency: 3,
    token_budget: 20_000,
    time_budget_ms: 120_000
  )

{:ok, run} =
  Elara.Coordinator.run(
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

`Elara.Coordinator.status/1` reports children and live budgets.
`Elara.Coordinator.kill_child/2` stops one child without stopping siblings. Call
`GenServer.stop(coordinator)` when finished to stop its children and remove
temporary coding worktrees.

See [Detached sessions and remote workers](detached-and-remote.md) to route
tools by capability and workspace.
