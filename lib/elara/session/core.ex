defmodule Elara.Session.Core do
  @moduledoc """
  The state machine. Pure. No IO, no processes, no clocks, no make_ref.
  Refs are a monotonic counter in state so every transition is reproducible
  in a test by feeding facts.
  """

  alias Elara.{Message, Provider, Tool}
  alias Elara.Message.{Assistant, ToolCall, ToolResult, User}

  defmodule Config do
    @type t :: %__MODULE__{
            system: String.t(),
            tools: %{String.t() => Tool.t()},
            max_iterations: pos_integer(),
            max_tool_output_bytes: pos_integer()
          }
    defstruct [:system, :tools, max_iterations: 12, max_tool_output_bytes: 16_384]
  end

  @type ref :: pos_integer()

  @type phase ::
          :idle
          | {:calling_provider, ref(), iteration :: pos_integer()}
          | {:running_tool, ref(), current :: ToolCall.t(), remaining :: [ToolCall.t()],
             iteration :: pos_integer()}

  defmodule State do
    @type t :: %__MODULE__{
            config: Config.t(),
            history: [Message.t()],
            phase: Elara.Session.Core.phase(),
            next_ref: pos_integer()
          }
    defstruct [:config, history: [], phase: :idle, next_ref: 1]
  end

  @type fact ::
          {:ask, String.t()}
          | {:provider_result, ref(), {:ok, Message.Assistant.t()} | {:error, Provider.Error.t()}}
          | {:tool_result, ref(), Tool.outcome()}
          | {:tool_crashed, ref(), reason :: String.t()}
          | {:tool_timeout, ref()}
          | :interrupt

  @type effect ::
          {:call_provider, ref(), Provider.Request.t()}
          | {:run_tool, ref(), ToolCall.t(), Tool.t()}
          | {:emit, Elara.Event.t()}

  @spec new(Config.t()) :: State.t()
  def new(%Config{} = config) do
    new(config, [])
  end

  @spec new(Config.t(), [Message.t()]) :: State.t()
  def new(%Config{} = config, history) when is_list(history) do
    %State{config: config, history: repair_history(history), phase: :idle, next_ref: 1}
  end

  @spec rebase_history(State.t(), [Message.t()]) :: State.t()
  def rebase_history(%State{phase: :idle} = state, history) when is_list(history) do
    %{state | history: repair_history(history)}
  end

  @spec replace_tools(State.t(), %{String.t() => Tool.t()}) :: State.t()
  def replace_tools(%State{phase: :idle} = state, tools) when is_map(tools) do
    %{state | config: %{state.config | tools: tools}}
  end

  @spec repair_history([Message.t()]) :: [Message.t()]
  def repair_history(history) when is_list(history) do
    {trailing_results, rest} =
      history
      |> Enum.reverse()
      |> Enum.split_while(&is_struct(&1, ToolResult))

    case rest do
      [%Assistant{tool_calls: calls} | _] when calls != [] ->
        completed =
          trailing_results
          |> Enum.map(& &1.call_id)
          |> MapSet.new()

        interrupted =
          calls
          |> Enum.reject(&MapSet.member?(completed, &1.id))
          |> Enum.map(&Message.tool_result(&1, {:error, "interrupted"}))

        history ++ interrupted

      _ ->
        history
    end
  end

  @spec idle?(State.t()) :: boolean()
  def idle?(%State{phase: :idle}), do: true
  def idle?(%State{}), do: false

  @spec step(State.t(), fact()) :: {State.t(), [effect()]}
  def step(%State{phase: :idle} = state, {:ask, prompt}) when is_binary(prompt) do
    user = Message.user(prompt)
    history = state.history ++ [user]
    {ref, state} = take_ref(%{state | history: history})

    effects = [
      {:emit, {:turn_started, prompt}},
      {:emit, {:message_appended, user}},
      call_provider_effect(state, ref)
    ]

    {%{state | phase: {:calling_provider, ref, 1}}, effects}
  end

  def step(%State{phase: :idle} = state, _fact), do: {state, []}

  def step(
        %State{phase: {:calling_provider, r, _it}} = state,
        {:provider_result, r, {:ok, %Assistant{} = asst}}
      ) do
    history = state.history ++ [asst]
    state = %{state | history: history}
    base = [{:emit, {:message_appended, asst}}]

    case asst.tool_calls do
      [] ->
        text = asst.text || ""
        effects = base ++ [{:emit, {:turn_ended, {:completed, text}}}]
        {%{state | phase: :idle}, effects}

      calls ->
        {state, more} = dispatch_next(%{state | phase: :idle}, calls, elem(state.phase, 2))
        {state, base ++ more}
    end
  end

  def step(
        %State{phase: {:calling_provider, r, _}} = state,
        {:provider_result, r, {:error, error}}
      ) do
    {%{state | phase: :idle}, [{:emit, {:turn_ended, {:provider_error, error}}}]}
  end

  def step(%State{phase: {:calling_provider, _, _}} = state, :interrupt) do
    {%{state | phase: :idle}, [{:emit, {:turn_ended, :interrupted}}]}
  end

  def step(%State{phase: {:running_tool, r, call, rest, it}} = state, {:tool_result, r, outcome}) do
    finish_tool(
      state,
      call,
      rest,
      it,
      truncate_outcome(outcome, state.config.max_tool_output_bytes)
    )
  end

  def step(%State{phase: {:running_tool, r, call, rest, it}} = state, {:tool_crashed, r, reason}) do
    outcome = {:error, "tool crashed: #{reason}"}
    finish_tool(state, call, rest, it, outcome)
  end

  def step(%State{phase: {:running_tool, r, call, rest, it}} = state, {:tool_timeout, r}) do
    finish_tool(state, call, rest, it, {:error, "timed out"})
  end

  def step(%State{phase: {:running_tool, _r, call, rest, _it}} = state, :interrupt) do
    interrupted = [call | rest]

    {history, emits} =
      Enum.reduce(interrupted, {state.history, []}, fn c, {hist, evs} ->
        result = Message.tool_result(c, {:error, "interrupted"})
        {hist ++ [result], evs ++ [{:emit, {:message_appended, result}}]}
      end)

    effects = emits ++ [{:emit, {:turn_ended, :interrupted}}]
    {%{state | history: history, phase: :idle}, effects}
  end

  def step(%State{} = state, _fact), do: {state, []}

  defp finish_tool(state, call, rest, it, outcome) do
    result = Message.tool_result(call, outcome)
    history = state.history ++ [result]
    state = %{state | history: history, phase: :idle}
    {state, more} = dispatch_next(state, rest, it)
    {state, [{:emit, {:message_appended, result}} | more]}
  end

  defp dispatch_next(state, [], iteration) do
    next_provider_call(state, iteration + 1)
  end

  defp dispatch_next(state, [call | rest], iteration) do
    cond do
      repeated_call?(state.history, call) ->
        reject_call(state, call, rest, iteration, "repeated tool call")

      match?({:malformed, _}, call.args) ->
        {:malformed, raw} = call.args
        reject_call(state, call, rest, iteration, "malformed arguments: #{raw}")

      not Map.has_key?(state.config.tools, call.name) ->
        reject_call(state, call, rest, iteration, "unknown tool: #{call.name}")

      true ->
        tool = Map.fetch!(state.config.tools, call.name)
        {ref, state} = take_ref(state)

        effects = [
          {:emit, {:tool_started, call}},
          {:run_tool, ref, call, tool}
        ]

        {%{state | phase: {:running_tool, ref, call, rest, iteration}}, effects}
    end
  end

  defp reject_call(state, call, rest, iteration, reason) do
    result = Message.tool_result(call, {:error, reason})
    {state, more} = dispatch_next(%{state | history: state.history ++ [result]}, rest, iteration)
    {state, [{:emit, {:message_appended, result}} | more]}
  end

  defp next_provider_call(state, iteration) do
    if iteration > state.config.max_iterations do
      {%{state | phase: :idle}, [{:emit, {:turn_ended, :turn_limit}}]}
    else
      {ref, state} = take_ref(state)
      effect = call_provider_effect(state, ref)
      {%{state | phase: {:calling_provider, ref, iteration}}, [effect]}
    end
  end

  defp call_provider_effect(state, ref) do
    request = %Provider.Request{
      system: state.config.system,
      messages: state.history,
      tools: Map.values(state.config.tools)
    }

    {:call_provider, ref, request}
  end

  defp take_ref(state) do
    ref = state.next_ref
    {ref, %{state | next_ref: ref + 1}}
  end

  defp truncate_outcome({:ok, text}, max), do: {:ok, truncate(text, max)}
  defp truncate_outcome({:error, text}, max), do: {:error, truncate(text, max)}
  defp truncate_outcome({:indeterminate, text}, max), do: {:indeterminate, truncate(text, max)}

  defp truncate(text, max) when is_binary(text) do
    cond do
      not String.valid?(text) ->
        "[binary #{byte_size(text)} bytes; not valid UTF-8]"

      byte_size(text) <= max ->
        text

      true ->
        kept = utf8_prefix(text, max)
        overflow = byte_size(text) - byte_size(kept)
        kept <> "\n[truncated #{overflow} bytes]"
    end
  end

  defp utf8_prefix(_text, max) when max <= 0, do: ""

  defp utf8_prefix(text, max) do
    kept = binary_part(text, 0, max)
    if String.valid?(kept), do: kept, else: utf8_prefix(text, max - 1)
  end

  # Same name+args as a tool call that already has a result in this turn.
  defp repeated_call?(history, %ToolCall{} = call) do
    turn =
      history
      |> Enum.reverse()
      |> Enum.take_while(fn
        %User{} -> false
        _ -> true
      end)

    fingerprint = call_fingerprint(call)

    prior_calls =
      turn
      |> Enum.flat_map(fn
        %Assistant{tool_calls: calls} -> calls
        _ -> []
      end)
      |> Enum.filter(fn tc ->
        Enum.any?(turn, fn
          %ToolResult{call_id: id} -> id == tc.id
          _ -> false
        end)
      end)

    Enum.any?(prior_calls, fn tc -> call_fingerprint(tc) == fingerprint end)
  end

  defp call_fingerprint(%ToolCall{name: name, args: args}), do: {name, args}
end
