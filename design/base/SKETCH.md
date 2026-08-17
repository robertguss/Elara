# Sketch. Event-sourced session core, mechanical shell

The whole agent is one pure function.

```elixir
@spec step(State.t(), fact()) :: {State.t(), [effect()]}
```

A fact is something that happened (user asked, provider replied, tool finished, tool crashed, timeout fired, interrupt). An effect is something to do (call the provider, run a tool, emit an event). The ReAct loop is not written as a loop. It is the fixpoint of feeding effect results back in as facts. The GenServer shell owns no decisions. It turns mailbox messages into facts, calls `step`, and executes effects in order.

```
mix harness.ask ──argv──▶ Mix.Tasks.Harness.Ask ──▶ Harness.CLI
                                                        │ subscribe + ask_async
                                                        ▼
                                              Harness.Session (GenServer shell)
                                              │ fact ──▶ Session.Core.step ──▶ effects
                                              │              (pure, no IO)
                                              ├── {:call_provider, ...} ──▶ Task: Provider.OpenAI.chat (Req)
                                              ├── {:run_tool, ...} ───────▶ Task: apply(m, f, [args, ctx])
                                              └── {:emit, ...} ───────────▶ send to subscribers (CLI prints)
```

Call chain from CLI to provider is three hops. CLI to Session to the provider adapter task. The core is a sideways consult inside the session, not a hop toward the provider.

## App skeleton

```elixir
# mix.exs
defmodule Harness.MixProject do
  use Mix.Project

  def project do
    [app: :harness, version: "0.1.0", elixir: "~> 1.20", deps: deps()]
  end

  def application do
    [mod: {Harness.Application, []}, extra_applications: [:logger]]
  end

  # One dependency. JSON encode/decode uses the stdlib JSON module (Elixir >= 1.18).
  # If this Req version auto-decodes via Jason, pass decode_body: false and decode with JSON.
  defp deps, do: [{:req, "~> 0.5"}]
end
```

```elixir
defmodule Harness.Application do
  use Application

  # Sessions are :temporary. A crashed session is gone, not restarted empty.
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Harness.TaskSup},
      {DynamicSupervisor, name: Harness.SessionSup, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Harness.Supervisor)
  end
end
```

## Module map

| Module | File | Owns |
|---|---|---|
| `Harness` | `lib/harness.ex` | Public API. Hides the GenServer protocol |
| `Harness.Application` | `lib/harness/application.ex` | Supervision tree |
| `Harness.Message` | `lib/harness/message.ex` | Message sum type, `ToolCall`, constructors |
| `Harness.Event` | `lib/harness/event.ex` | Event sum type, turn outcome type |
| `Harness.Tool` | `lib/harness/tool.ex` | Tool struct, `Ctx`, builtin table |
| `Harness.Tools` | `lib/harness/tools.ex` | read, write, bash implementations |
| `Harness.Session.Core` | `lib/harness/session/core.ex` | The state machine. Facts in, effects out. Single writer of history |
| `Harness.Session` | `lib/harness/session.ex` | GenServer shell. Task and timer bookkeeping, event fanout |
| `Harness.Provider` | `lib/harness/provider.ex` | Provider behaviour, `Request`, `Error` |
| `Harness.Provider.OpenAI` | `lib/harness/provider/open_ai.ex` | Wire mapping and the one Req call |
| `Harness.Config` | `lib/harness/config.ex` | Env boundary for `HARNESS_*` |
| `Harness.CLI` | `lib/harness/cli.ex` | Subscribe, print, render. Exit status |
| `Mix.Tasks.Harness.Ask` | `lib/mix/tasks/harness.ask.ex` | argv boundary |

## Domain types

### Messages

```elixir
defmodule Harness.Message do
  @moduledoc """
  History is a list of these three structs, oldest first. Nothing else.
  Every struct serializes with the stdlib JSON module, which keeps the
  file/DETS persistence experiment additive.
  """

  defmodule ToolCall do
    # args are parsed at the provider boundary. {:malformed, raw} keeps the raw
    # string so the model can be told exactly what it sent.
    @type args :: {:ok, map()} | {:malformed, String.t()}
    @type t :: %__MODULE__{id: String.t(), name: String.t(), args: args()}
    defstruct [:id, :name, :args]
  end

  defmodule User do
    @type t :: %__MODULE__{text: String.t()}
    defstruct [:text]
  end

  defmodule Assistant do
    @typedoc "Invariant: text and tool_calls are never both empty. Enforced by assistant/2."
    @type t :: %__MODULE__{text: String.t() | nil, tool_calls: [ToolCall.t()]}
    defstruct text: nil, tool_calls: []
  end

  defmodule ToolResult do
    @type t :: %__MODULE__{call_id: String.t(), name: String.t(), outcome: Harness.Tool.outcome()}
    defstruct [:call_id, :name, :outcome]
  end

  @type t :: User.t() | Assistant.t() | ToolResult.t()

  @doc "The only way to build an Assistant message. Rejects the empty message."
  @spec assistant(String.t() | nil, [ToolCall.t()]) :: {:ok, Assistant.t()} | {:error, :empty_assistant}
  def assistant(_text, _tool_calls), do: raise("not implemented")

  @spec user(String.t()) :: User.t()
  def user(_text), do: raise("not implemented")

  @spec tool_result(ToolCall.t(), Harness.Tool.outcome()) :: ToolResult.t()
  def tool_result(_call, _outcome), do: raise("not implemented")
end
```

### Tools

A tool is data. The `run` field is a `{module, function}` pair, never a closure. External calls resolve to the current module version at call time, so a reloaded plugin module takes effect on the next call without touching session state. A closure captured from an old module version dies when that version is purged. The type makes the safe choice the only choice, and it keeps the whole tool table serializable, which is what lets a future hands node receive it.

```elixir
defmodule Harness.Tool do
  defmodule Ctx do
    @type t :: %__MODULE__{cwd: String.t()}
    defstruct [:cwd]
  end

  @type outcome :: {:ok, String.t()} | {:error, String.t()}

  @typedoc """
  parameters is a raw JSON Schema map, passed to the provider as is.
  run points at f(args :: map(), ctx :: Ctx.t()) :: outcome().
  """
  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters: map(),
          run: {module(), atom()}
        }
  defstruct [:name, :description, :parameters, :run]

  @spec builtins() :: [t()]
  def builtins, do: raise("not implemented")
  # [read(), write(), bash()] built from Harness.Tools

  @doc "Table keyed by name. Duplicate names are an ArgumentError at session start."
  @spec table([t()]) :: %{String.t() => t()}
  def table(_tools), do: raise("not implemented")
end
```

```elixir
defmodule Harness.Tools do
  @moduledoc "Built-in tool implementations. Three functions, one file, no behaviour."

  alias Harness.Tool.Ctx

  @spec read(map(), Ctx.t()) :: Harness.Tool.outcome()
  def read(_args, _ctx), do: raise("not implemented")
  # File.read(Path.expand(path, ctx.cwd)); :enoent and friends become {:error, human_text}

  @spec write(map(), Ctx.t()) :: Harness.Tool.outcome()
  def write(_args, _ctx), do: raise("not implemented")
  # File.mkdir_p then File.write; returns {:ok, "wrote N bytes to path"}

  @spec bash(map(), Ctx.t()) :: Harness.Tool.outcome()
  def bash(_args, _ctx), do: raise("not implemented")
  # System.shell(cmd, cd: ctx.cwd, stderr_to_stdout: true)
  # exit 0 -> {:ok, out}; nonzero -> {:error, "exit N\n" <> out}
end
```

### Events

```elixir
defmodule Harness.Event do
  @type turn_outcome ::
          {:completed, String.t()}
          | :turn_limit
          | :interrupted
          | {:provider_error, Harness.Provider.Error.t()}

  @type t ::
          {:turn_started, String.t()}
          | {:message_appended, Harness.Message.t()}
          | {:tool_started, Harness.Message.ToolCall.t()}
          | {:turn_ended, turn_outcome()}
end
```

Tool completion is observed as `{:message_appended, %ToolResult{}}`. One source of truth, no separate tool_finished variant to keep in sync.

## The core

```elixir
defmodule Harness.Session.Core do
  @moduledoc """
  The state machine. Pure. No IO, no processes, no clocks, no make_ref.
  Refs are a monotonic counter in state so every transition is reproducible
  in a test by feeding facts.

  Invariants, checked by the test suite:
    I1. Only step/2 appends to history. The shell cannot construct State.
    I2. History is wire-legal after every step. Every Assistant tool_call has
        exactly one ToolResult before any further provider call, on every
        path including interrupt, crash, and timeout.
    I3. Every fact sequence ends in phase :idle with a turn_ended event.
        There is no stuck phase.
    I4. A fact carrying a ref that does not match the current phase's ref is
        dropped with no state change. Late task results after an interrupt
        converge to the same end state.
    I5. iteration never exceeds config.max_iterations for an issued
        call_provider effect.
  """

  alias Harness.{Event, Message, Provider, Tool}
  alias Harness.Message.ToolCall

  defmodule Config do
    @type t :: %__MODULE__{
            system: String.t(),
            tools: %{String.t() => Tool.t()},
            max_iterations: pos_integer(),
            max_tool_output_bytes: pos_integer()
          }
    defstruct [:system, :tools, max_iterations: 12, max_tool_output_bytes: 16_384]
  end

  @typedoc "Correlates an issued effect with the fact that answers it."
  @type ref :: pos_integer()

  @typedoc """
  The phase is the state machine. Each variant carries exactly the data that
  phase needs, so an impossible combination has no representation.
  """
  @type phase ::
          :idle
          | {:calling_provider, ref(), iteration :: pos_integer()}
          | {:running_tool, ref(), current :: ToolCall.t(), remaining :: [ToolCall.t()],
             iteration :: pos_integer()}

  defmodule State do
    @type t :: %__MODULE__{
            config: Config.t(),
            history: [Message.t()],
            phase: Harness.Session.Core.phase(),
            next_ref: pos_integer()
          }
    defstruct [:config, history: [], phase: :idle, next_ref: 1]
  end

  @type fact ::
          {:ask, String.t()}
          | {:provider_result, ref(), {:ok, Message.Assistant.t()} | {:error, Provider.Error.t()}}
          | {:tool_result, ref(), Tool.outcome()}
          | {:tool_crashed, ref(), reason :: term()}
          | {:tool_timeout, ref()}
          | :interrupt

  @type effect ::
          {:call_provider, ref(), Provider.Request.t()}
          | {:run_tool, ref(), ToolCall.t(), Tool.t()}
          | {:emit, Event.t()}

  @spec new(Config.t()) :: State.t()
  def new(_config), do: raise("not implemented")

  @spec idle?(State.t()) :: boolean()
  def idle?(_state), do: raise("not implemented")

  @spec step(State.t(), fact()) :: {State.t(), [effect()]}
  def step(_state, _fact), do: raise("not implemented")

  # Private helpers the transitions share:
  #
  # dispatch_next(state, [call | rest], iteration)
  #   Unknown tool name or {:malformed, raw} args append an error ToolResult
  #   immediately and recurse on rest. The first valid call moves phase to
  #   {:running_tool, ref, call, rest, iteration} and returns
  #   [emit tool_started, run_tool]. An emptied list falls through to
  #   next_provider_call(state, iteration + 1).
  #
  # next_provider_call(state, iteration)
  #   iteration > max_iterations ends the turn as :turn_limit. Otherwise
  #   phase {:calling_provider, ref, iteration} and effect
  #   {:call_provider, ref, %Provider.Request{system, messages: history,
  #   tools: Map.values(tools)}}.
  #
  # truncate(text, max_bytes)
  #   Appends "\n[truncated N bytes]" when over the cap, before the result
  #   enters history. Applies to every tool, including future plugins.
end
```

### Transition table

The table is the design. Each row is one `step/2` clause. `emit` rows omit the tuple noise.

| # | Phase | Fact | New phase | Effects and appends |
|---|---|---|---|---|
| 1 | `:idle` | `{:ask, prompt}` | `{:calling_provider, r1, 1}` | append User; emit turn_started, message_appended; call_provider |
| 2 | `:idle` | any task fact or `:interrupt` | `:idle` | none (stale or no-op) |
| 3 | `{:calling_provider, r, it}` | `{:provider_result, r, {:ok, asst}}`, no tool calls | `:idle` | append Assistant; emit message_appended, turn_ended `{:completed, asst.text}` |
| 4 | `{:calling_provider, r, it}` | `{:provider_result, r, {:ok, asst}}`, with tool calls | via `dispatch_next` | append Assistant; emit message_appended; then row 4a or 4b |
| 4a |  | first valid call `c` | `{:running_tool, r2, c, rest, it}` | emit tool_started; run_tool |
| 4b |  | all calls invalid | `{:calling_provider, r2, it + 1}` or `:idle` | append error ToolResults; emit each; then call_provider or turn_ended `:turn_limit` |
| 5 | `{:calling_provider, r, _}` | `{:provider_result, r, {:error, e}}` | `:idle` | emit turn_ended `{:provider_error, e}` |
| 6 | `{:running_tool, r, c, rest, it}` | `{:tool_result, r, outcome}` | via `dispatch_next(rest)` | append ToolResult (truncated); emit message_appended; then next tool, next provider call, or turn_limit |
| 7 | `{:running_tool, r, c, rest, it}` | `{:tool_crashed, r, reason}` | as row 6 | outcome is `{:error, "tool crashed: ..."}` |
| 8 | `{:running_tool, r, c, rest, it}` | `{:tool_timeout, r}` | as row 6 | outcome is `{:error, "timed out after Nms"}` |
| 9 | `{:running_tool, r, c, rest, _}` | `:interrupt` | `:idle` | append `{:error, "interrupted"}` ToolResults for `c` and all of `rest` (keeps I2); emit each, then turn_ended `:interrupted` |
| 10 | `{:calling_provider, _, _}` | `:interrupt` | `:idle` | emit turn_ended `:interrupted` |
| 11 | any | fact with mismatched ref | unchanged | none (I4) |

Doom-loop detection is one future row before `next_provider_call` that compares recent tool calls. Token streaming is one future fact variant `{:provider_delta, ref, chunk}` mapped to one future event. Neither ships in v1.

## The shell

```elixir
defmodule Harness.Session do
  @moduledoc """
  Mechanical shell around Core. Holds no domain state and makes no domain
  decisions. Bookkeeping only: which task ref answers which core ref, one
  timer per running tool, monitored subscribers, the deferred reply for a
  synchronous ask.

  The mailbox is never blocked by a turn. Provider calls and tool runs are
  Task.Supervisor.async_nolink tasks whose results come back as facts, so
  subscribe and interrupt work mid-turn and a crashing tool is isolated
  from the session (brains survive the hands).
  """

  use GenServer

  @type shell :: %{
          core: Harness.Session.Core.State.t(),
          provider: {module(), Harness.Provider.config()},
          cwd: String.t(),
          tool_timeout_ms: pos_integer(),
          subscribers: %{pid() => reference()},
          pending_reply: GenServer.from() | nil,
          tasks: %{reference() => {:provider | :tool, Harness.Session.Core.ref()}},
          timers: %{Harness.Session.Core.ref() => reference()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: raise("not implemented")

  # handle_call {:ask, prompt}         -> busy? reply {:error, :busy}
  #                                       else stash from, feed {:ask, prompt}, {:noreply, ...}
  # handle_call {:ask_async, prompt}   -> busy? {:error, :busy} else :ok, feed fact
  # handle_call :subscribe             -> monitor caller, add to subscribers
  # handle_cast :interrupt             -> feed :interrupt
  # handle_info {task_ref, result}     -> demonitor, cancel timer, feed
  #                                       {:provider_result, ref, result} or {:tool_result, ref, result}
  # handle_info {:DOWN, task_ref, ...} -> if still tracked: feed {:tool_crashed, ref, reason}
  #                                       or provider_result {:error, %Error{kind: :crash}}
  # handle_info {:DOWN, sub_ref, ...}  -> prune subscriber
  # handle_info {:tool_deadline, ref}  -> if still tracked: untrack, kill task, feed {:tool_timeout, ref}
  #
  # feed(fact, shell):
  #   {core, effects} = Core.step(shell.core, fact)
  #   Enum.reduce(effects, %{shell | core: core}, &run_effect/2)
  #
  # run_effect({:emit, event}, shell)
  #   send {:harness, self(), event} to every subscriber.
  #   On {:turn_ended, outcome} with a pending_reply: GenServer.reply with
  #   {:ok, text} for :completed and {:error, outcome} otherwise.
  # run_effect({:call_provider, ref, req}, shell)
  #   Task.Supervisor.async_nolink(Harness.TaskSup, mod, :chat, [cfg, req])
  # run_effect({:run_tool, ref, call, tool}, shell)
  #   {:ok, args} = call.args  # core only dispatches valid calls
  #   async_nolink apply(m, f, [args, %Ctx{cwd: cwd}]); Process.send_after deadline
end
```

```elixir
defmodule Harness do
  @moduledoc "Public API. Callers never see GenServer message shapes or wire types."

  @type ask_error :: :busy | :turn_limit | :interrupted | {:provider_error, Harness.Provider.Error.t()}

  @spec start_session(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(_opts \\ []), do: raise("not implemented")
  # Validates opts, builds Core.Config, DynamicSupervisor.start_child(SessionSup, ...), :temporary

  @spec ask(pid(), String.t(), timeout()) :: {:ok, String.t()} | {:error, ask_error()}
  def ask(_session, _prompt, _timeout \\ :infinity), do: raise("not implemented")

  @spec ask_async(pid(), String.t()) :: :ok | {:error, :busy}
  def ask_async(_session, _prompt), do: raise("not implemented")

  @spec subscribe(pid()) :: :ok
  def subscribe(_session), do: raise("not implemented")

  @spec interrupt(pid()) :: :ok
  def interrupt(_session), do: raise("not implemented")
end
```

## Provider boundary

```elixir
defmodule Harness.Provider do
  @moduledoc """
  The LLM boundary. HTTP and vendor JSON die behind chat/2. The rest of the
  app sees only Message and ToolCall structs.
  """

  defmodule Request do
    @type t :: %__MODULE__{
            system: String.t(),
            messages: [Harness.Message.t()],
            tools: [Harness.Tool.t()]
          }
    defstruct [:system, :messages, :tools]
  end

  defmodule Error do
    @type kind :: :http | :transport | :bad_response | :crash
    @type t :: %__MODULE__{kind: kind(), message: String.t()}
    defstruct [:kind, :message]
  end

  @type config :: term()

  @callback chat(config(), Request.t()) ::
              {:ok, Harness.Message.Assistant.t()} | {:error, Error.t()}
end
```

```elixir
defmodule Harness.Provider.OpenAI do
  @behaviour Harness.Provider

  @type config :: %{api_key: String.t(), base_url: String.t(), model: String.t()}

  @impl true
  def chat(_config, _request), do: raise("not implemented")
  # Req.post(base_url <> "/chat/completions", auth: bearer, json: build_body(...))
  # |> parse_response()

  @doc "Pure. Request to OpenAI wire body. Tested against fixtures, no network."
  @spec build_body(config(), Harness.Provider.Request.t()) :: map()
  def build_body(_config, _request), do: raise("not implemented")
  # system -> role system message first
  # User -> role user
  # Assistant -> role assistant; args {:ok, map} re-encode with JSON.encode!,
  #              {:malformed, raw} pass raw through unchanged (fidelity)
  # ToolResult -> role tool, tool_call_id; {:error, text} becomes "ERROR: " <> text
  # tools -> function declarations from name/description/parameters (run is never serialized)

  @doc "Pure. Wire response to domain. Malformed args become {:malformed, raw} here."
  @spec parse_response({:ok, Req.Response.t()} | {:error, Exception.t()}) ::
          {:ok, Harness.Message.Assistant.t()} | {:error, Harness.Provider.Error.t()}
  def parse_response(_result), do: raise("not implemented")
  # non-200 -> %Error{kind: :http, message: status + body snippet}
  # transport exception -> :transport
  # missing choices / empty assistant (via Message.assistant/2) -> :bad_response
end
```

The test fake implements the same behaviour with a scripted reply queue held in its config.

```elixir
defmodule Harness.Provider.Scripted do
  @moduledoc "Test-only provider. Config is a pid holding a queue of canned chat/2 returns."
  @behaviour Harness.Provider

  @impl true
  def chat(_config, _request), do: raise("not implemented")
end
```

## Config boundary

```elixir
defmodule Harness.Config do
  @moduledoc "The only module that reads HARNESS_* variables."

  @spec from_env(%{String.t() => String.t()}) ::
          {:ok, Harness.Provider.OpenAI.config()} | {:error, {:missing_env, [String.t()]}}
  def from_env(_env), do: raise("not implemented")
  # HARNESS_API_KEY and HARNESS_MODEL required, both reported together when missing.
  # HARNESS_BASE_URL defaults to https://api.openai.com/v1.
end
```

## CLI

```elixir
defmodule Harness.CLI do
  @spec main([String.t()]) :: :ok | no_return()
  def main(_argv), do: raise("not implemented")
  # argv is the prompt (joined). Config.from_env(System.get_env()) or exit
  # with the missing-variable message. start_session, subscribe, ask_async,
  # then receive {:harness, _, event} until {:turn_ended, outcome}.
  # exit({:shutdown, 1}) on anything but :completed.

  @doc "Pure. One event to iodata. Tested without a terminal."
  @spec render(Harness.Event.t()) :: iodata()
  def render(_event), do: raise("not implemented")
  # turn_started   -> "[turn] " <> prompt
  # tool_started   -> "  -> name: one-line arg summary"
  # ToolResult     -> "  <- ok (N lines)" or "  <- error: first line"
  # Assistant text -> the text
  # turn_ended     -> "[done] N model calls" or the failure reason
end
```

```elixir
defmodule Mix.Tasks.Harness.Ask do
  @shortdoc "Ask the coding agent a question about this repo"
  @requirements ["app.start"]
  use Mix.Task

  @impl true
  def run(argv), do: Harness.CLI.main(argv)
end
```

The Mix task is the argv boundary and carries the Mix behaviour and docs. Logic lives in `Harness.CLI` so ExUnit can drive it without Mix.

## Test plan

No live network anywhere. The core tests need no processes at all.

| File | Drives | Covers |
|---|---|---|
| `test/harness/session/core_test.exs` | `Core.step/2` directly | every transition table row: happy text-only turn, multi-tool turn, turn limit, unknown tool, malformed args, provider error, interrupt mid-tool with synthetic results (I2), stale ref dropped (I4), output truncation |
| `test/harness/message_test.exs` | constructors | `assistant/2` rejects the empty message; serialization round-trip |
| `test/harness/session_test.exs` | GenServer with `Provider.Scripted` and an MFA fake tool | sync ask returns final text; event order; busy rejection; tool crash isolates (session survives, error result appended); timeout fires |
| `test/harness/provider/open_ai_test.exs` | `build_body/2`, `parse_response/1` | wire mapping both directions against fixture JSON, malformed args path, error classification |
| `test/harness/config_test.exs` | `from_env/1` | required, defaulted, both-missing reported together |
| `test/harness/cli_test.exs` | `render/1` | one assertion per event shape |

## Doors left open, in the types

- Hot swap (Pi). Tools are `{module, function}` data in core state. Reloading a module changes behavior on the next call. A future `/reload` is a cast that replaces entries in `config.tools` between turns. No loader ships in v1.
- Client-server (OpenCode). A client is a subscriber pid plus the four public calls. A future HTTP layer is one more subscriber process translating events to SSE. Nothing in the session changes.
- Distribution (Livebook). `run_effect({:run_tool, ...})` is the one line that picks where hands run. Core state and the tool table are plain serializable data, so pointing that line at a `Task.Supervisor` on another node moves execution without touching the core. Persistence is one more effect consumer writing history after each `message_appended`.
