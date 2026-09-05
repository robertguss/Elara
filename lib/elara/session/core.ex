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
            provider_settings: Elara.Provider.Visibility.settings() | nil,
            max_iterations: pos_integer(),
            max_tool_output_bytes: pos_integer()
          }
    defstruct [
      :system,
      :tools,
      :provider_settings,
      max_iterations: 12,
      max_tool_output_bytes: 16_384
    ]
  end

  @type ref :: pos_integer()

  @type phase ::
          :idle
          | {:calling_provider, ref(), iteration :: pos_integer()}
          | {:running_tool, ref(), current :: ToolCall.t(), remaining :: [ToolCall.t()],
             iteration :: pos_integer()}

  @type streaming :: %{
          id: String.t(),
          text: String.t(),
          public_content: [Elara.Provider.Visibility.public_part()],
          settings: Elara.Provider.Visibility.settings() | nil
        }

  defmodule State do
    @type t :: %__MODULE__{
            config: Config.t(),
            history: [Message.t()],
            phase: Elara.Session.Core.phase(),
            streaming: Elara.Session.Core.streaming() | nil,
            next_ref: pos_integer()
          }
    defstruct [
      :config,
      history: [],
      phase: :idle,
      streaming: nil,
      next_ref: 1,
      deferred_calls: []
    ]
  end

  @type fact ::
          {:ask, String.t()}
          | {:ask_input, User.t()}
          | {:provider_delta, ref(), Provider.delta()}
          | {:provider_settings, Elara.Provider.Visibility.settings()}
          | {:provider_result, ref(), {:ok, Message.Assistant.t()} | {:error, Provider.Error.t()}}
          | {:tool_result, ref(), Tool.outcome()}
          | {:tool_deferred, ref(), String.t()}
          | {:instruction_context, String.t()}
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
  def step(state, {:instruction_context, system}) when is_binary(system) do
    {%{state | config: %{state.config | system: system}}, []}
  end

  def step(%State{phase: :idle} = state, {:ask, prompt}) when is_binary(prompt) do
    step(state, {:ask_input, Message.user(prompt)})
  end

  def step(%State{phase: :idle} = state, {:ask_input, %User{} = user}) do
    prompt = user.text
    history = state.history ++ [user]
    {ref, state} = take_ref(%{state | history: history, deferred_calls: []})

    effects = [
      {:emit, {:turn_started, prompt}},
      {:emit, {:message_appended, user}},
      call_provider_effect(state, ref)
    ]

    {%{
       state
       | phase: {:calling_provider, ref, 1},
         streaming: new_stream(ref, state.config.provider_settings)
     }, effects}
  end

  def step(state, {:provider_settings, settings}) do
    {%{state | config: %{state.config | provider_settings: settings}},
     [{:emit, :provider_view_changed}]}
  end

  def step(%State{phase: :idle} = state, _fact), do: {state, []}

  def step(
        %State{phase: {:calling_provider, r, _}, streaming: streaming} = state,
        {:provider_delta, r, {:public_content, part}}
      ) do
    if Elara.Provider.Visibility.valid_part?(part) do
      streaming = %{
        streaming
        | public_content: Elara.Provider.Visibility.upsert(streaming.public_content, part)
      }

      {%{state | streaming: streaming}, [{:emit, :provider_view_changed}]}
    else
      {state, []}
    end
  end

  def step(
        %State{phase: {:calling_provider, r, _it}, streaming: streaming} = state,
        {:provider_delta, r, text}
      )
      when is_binary(text) and text != "" do
    streaming = %{streaming | text: streaming.text <> text}
    {%{state | streaming: streaming}, [{:emit, {:content_delta, streaming.id, text}}]}
  end

  def step(
        %State{phase: {:calling_provider, r, _it}, streaming: streaming} = state,
        {:provider_result, r, {:ok, %Assistant{} = asst}}
      ) do
    if streaming.text != "" and asst.text != streaming.text do
      error = %Provider.Error{
        kind: :bad_response,
        message: "final assistant did not match streamed content"
      }

      {%{state | phase: :idle, streaming: nil},
       [{:emit, streamed_turn_ended({:provider_error, error}, streaming)}]}
    else
      finish_provider(state, asst, streaming)
    end
  end

  def step(
        %State{phase: {:calling_provider, r, _}, streaming: streaming} = state,
        {:provider_result, r, {:error, error}}
      ) do
    stop_stream(state, streaming, {:provider_error, error})
  end

  def step(
        %State{phase: {:calling_provider, _, _}, streaming: streaming} = state,
        :interrupt
      ) do
    stop_stream(state, streaming, :interrupted)
  end

  def step(%State{phase: {:running_tool, r, call, rest, it}} = state, {:tool_deferred, r, system}) do
    state = %{
      state
      | config: %{state.config | system: system},
        deferred_calls: [call.id | state.deferred_calls]
    }

    finish_tool(
      state,
      call,
      rest,
      it,
      {:error,
       "Not executed: new scoped project instructions are now in the system context. Review them and reissue the tool call if appropriate."}
    )
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

  defp stop_stream(state, %{public_content: [_ | _]} = streaming, outcome) do
    text =
      streaming.public_content
      |> Enum.reject(&(&1["kind"] == "reasoning_summary"))
      |> Enum.map_join(& &1["text"])

    message = %Assistant{
      text: if(text == "", do: nil, else: text),
      public_content: streaming.public_content,
      request_settings: streaming.settings,
      interrupted: true
    }

    {%{state | history: state.history ++ [message], phase: :idle, streaming: nil},
     [{:emit, {:message_appended, message}}, {:emit, streamed_turn_ended(outcome, streaming)}]}
  end

  defp stop_stream(state, streaming, outcome),
    do:
      {%{state | phase: :idle, streaming: nil},
       [{:emit, streamed_turn_ended(outcome, streaming)}]}

  defp finish_provider(state, asst, streaming) do
    asst = %{asst | request_settings: streaming.settings}
    history = state.history ++ [asst]
    state = %{state | history: history, streaming: nil}

    appended =
      if streaming.text == "" do
        {:message_appended, asst}
      else
        {:message_appended, asst, :streamed}
      end

    base = [{:emit, appended}]

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
      repeated_call?(state.history, call, state.deferred_calls) ->
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

      {%{
         state
         | phase: {:calling_provider, ref, iteration},
           streaming: new_stream(ref, state.config.provider_settings)
       }, [effect]}
    end
  end

  defp call_provider_effect(state, ref) do
    request = %Provider.Request{
      system: state.config.system,
      messages: state.history,
      tools: Map.values(state.config.tools),
      settings: state.config.provider_settings
    }

    {:call_provider, ref, request}
  end

  defp take_ref(state) do
    ref = state.next_ref
    {ref, %{state | next_ref: ref + 1}}
  end

  defp new_stream(ref, settings),
    do: %{id: "assistant-#{ref}", text: "", public_content: [], settings: settings}

  defp streamed_turn_ended(outcome, %{text: ""}), do: {:turn_ended, outcome}
  defp streamed_turn_ended(outcome, %{text: _text}), do: {:turn_ended, outcome, :streamed}

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
  defp repeated_call?(history, %ToolCall{} = call, deferred_calls) do
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
      |> Enum.reject(&(&1.id in deferred_calls))
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
