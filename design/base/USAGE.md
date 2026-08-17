# Harness usage

Harness is a coding agent loop as a Mix app. You type a prompt. A session process calls an OpenAI-compatible model, runs the tools it asks for (read, write, bash), and prints every step as it happens. One node, one dependency (Req), no server.

## Configuration

Three environment variables, parsed once at startup. Missing required values fail fast with a named error before any session starts.

| Variable | Required | Meaning |
|---|---|---|
| `HARNESS_API_KEY` | yes | Bearer token for the provider |
| `HARNESS_MODEL` | yes | Model name sent on every request |
| `HARNESS_BASE_URL` | no | Defaults to `https://api.openai.com/v1` |

Works with OpenAI, gateways, and local servers (for example `HARNESS_BASE_URL=http://localhost:11434/v1` for Ollama).

## CLI quickstart

```
$ export HARNESS_API_KEY=sk-... HARNESS_MODEL=gpt-4.1
$ mix harness.ask "what files are in this repo?"

[turn] what files are in this repo?
  -> bash: ls -la
  <- ok (14 lines)
The repo is a fresh Mix app. Top level has mix.exs, lib/, test/,
.gitignore, and README.md. lib/ contains harness.ex ...
[done] 2 model calls
```

Every tool call prints when it starts and when it finishes, so you watch the agent work instead of staring at a spinner. Exit status is 0 on a completed answer and 1 on provider error, turn limit, or interrupt.

## Library quickstart

The CLI is one client of the public API. Any process can be another.

```elixir
{:ok, session} = Harness.start_session()
{:ok, answer} = Harness.ask(session, "what files are in this repo?")
IO.puts(answer)
```

`ask/2` blocks until the turn ends and returns the model's final text. A busy session returns `{:error, :busy}` immediately. One session runs one turn at a time; run parallel work as separate sessions.

## Call site 1: a release script

```elixir
# scripts/changelog.exs
{:ok, session} = Harness.start_session(cwd: File.cwd!())

case Harness.ask(session, "Summarize git log HEAD~10..HEAD as a changelog entry.") do
  {:ok, text} -> File.write!("CHANGELOG.draft.md", text)
  {:error, reason} -> Mix.raise("harness failed: #{inspect(reason)}")
end
```

## Call site 2: registering a project-specific tool

A tool is a value, not a subsystem. Name, description, JSON schema, and an `{module, function}` pair with arity 2.

```elixir
defmodule MyApp.HarnessTools do
  def run_tests(_args, ctx) do
    {out, status} = System.shell("mix test --max-failures 1", cd: ctx.cwd, stderr_to_stdout: true)
    if status == 0, do: {:ok, out}, else: {:error, out}
  end
end

tools =
  Harness.Tool.builtins() ++
    [
      %Harness.Tool{
        name: "run_tests",
        description: "Run the test suite. Returns the summary output.",
        parameters: %{"type" => "object", "properties" => %{}, "required" => []},
        run: {MyApp.HarnessTools, :run_tests}
      }
    ]

{:ok, session} = Harness.start_session(tools: tools)
{:ok, _} = Harness.ask(session, "fix the failing test")
```

## Call site 3: watching a session from another process

Subscribing is how the CLI itself is built. A second client is just a second subscriber, which is the client-server door the actor model leaves open.

```elixir
{:ok, session} = Harness.start_session()
:ok = Harness.subscribe(session)
:ok = Harness.ask_async(session, "add typespecs to lib/parser.ex")

# Each event arrives as {:harness, session_pid, event}:
#   {:turn_started, prompt}
#   {:message_appended, %Harness.Message.User{} | %Harness.Message.Assistant{} | %Harness.Message.ToolResult{}}
#   {:tool_started, %Harness.ToolCall{}}
#   {:turn_ended, {:completed, text} | :turn_limit | :interrupted | {:provider_error, err}}
```

Subscribers are monitored. A dead subscriber is pruned, never crashes the session.

## Session options

All optional. Defaults are chosen so the two-line quickstart works.

| Option | Default | Meaning |
|---|---|---|
| `:cwd` | `File.cwd!()` | Directory tools operate in |
| `:tools` | `Harness.Tool.builtins()` | Tool table for this session |
| `:system` | built-in tiny prompt | System prompt |
| `:max_iterations` | 12 | Hard cap on model calls per ask |
| `:tool_timeout_ms` | 30_000 | Per tool call; a timeout becomes an error result |
| `:max_tool_output_bytes` | 16_384 | Tool output beyond this is truncated before entering history |
| `:provider` | `{Harness.Provider.OpenAI, config}` | Any module implementing `Harness.Provider` |

## Failure behavior, guaranteed

- A tool error, crash, or timeout never ends the turn. It becomes an error result the model sees and can react to.
- A provider error ends the turn as `{:error, {:provider_error, err}}`. History keeps everything appended so far. Asking again starts a fresh turn on the same history.
- The turn limit ends the turn as `{:error, :turn_limit}` with history left consistent.
- `Harness.interrupt(session)` ends the current turn as `:interrupted` and is a no-op on an idle session.
- History is always wire-legal. Every tool call the model makes gets exactly one result before the next model call, on every path including interrupt.
