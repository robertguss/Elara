defmodule Elara.Session.Core do
  @moduledoc """
  The state machine. Pure. No IO, no processes, no clocks, no make_ref.
  Refs are a monotonic counter in state so every transition is reproducible
  in a test by feeding facts.
  """

  alias Elara.{Message, Provider, Tool}
  alias Elara.Message.{Assistant, ToolCall, ToolResult, User}
  alias Elara.Provider.Retry

  defmodule Config do
    @type t :: %__MODULE__{
            system: String.t(),
            tools: %{String.t() => Tool.t()},
            provider_settings: Elara.Provider.Visibility.settings() | nil,
            provider_catalog: Elara.Provider.Catalog.t() | nil,
            max_iterations: pos_integer(),
            tool_timeout_ms: pos_integer(),
            max_tool_timeout_ms: pos_integer(),
            max_tool_output_bytes: pos_integer(),
            context_keep_results: pos_integer(),
            context_keep_tokens: pos_integer(),
            command_preflight: boolean(),
            retry: Elara.Provider.Retry.Policy.t()
          }
    defstruct [
      :system,
      :tools,
      :provider_settings,
      :provider_catalog,
      max_iterations: 100,
      tool_timeout_ms: 600_000,
      max_tool_timeout_ms: 3_600_000,
      max_tool_output_bytes: 16_384,
      context_keep_results: 5,
      context_keep_tokens: 20_000,
      command_preflight: false,
      retry: %Elara.Provider.Retry.Policy{}
    ]
  end

  @type ref :: pos_integer()

  @type phase ::
          :idle
          | {:calling_provider, ref(), iteration :: pos_integer()}
          | {:awaiting_retry, ref(), iteration :: pos_integer(), attempt :: pos_integer(),
             delay_ms :: non_neg_integer()}
          | {:checking_tool, ref(), ToolCall.t(), [ToolCall.t()], pos_integer()}
          | {:approval_waiting, ref(), ToolCall.t(), [ToolCall.t()], pos_integer(), map()}
          | {:running_tool, ref(), current :: ToolCall.t(), remaining :: [ToolCall.t()],
             iteration :: pos_integer()}

  @typedoc "Attempts already failed for the current provider call, and the wait they scheduled."
  @type retry :: %{attempts: pos_integer(), waited_ms: non_neg_integer()}

  @type streaming :: %{
          id: String.t(),
          text: String.t(),
          public_content: [Elara.Provider.Visibility.public_part()],
          settings: Elara.Provider.Visibility.settings() | nil
        }

  @type runtime_limits :: %{
          max_iterations: pos_integer(),
          tool_timeout_ms: pos_integer(),
          max_tool_timeout_ms: pos_integer()
        }
  @type runtime_limit_key :: :max_iterations | :tool_timeout_ms
  @runtime_limit_keys [:max_iterations, :tool_timeout_ms, :max_tool_timeout_ms]

  defmodule State do
    @type t :: %__MODULE__{
            config: Config.t(),
            history: [Message.t()],
            phase: Elara.Session.Core.phase(),
            streaming: Elara.Session.Core.streaming() | nil,
            tool_usage: Elara.Provider.Visibility.usage() | nil,
            mcp_guard: map() | nil,
            retry: Elara.Session.Core.retry() | nil,
            pending_runtime_limits: Elara.Session.Core.runtime_limits() | nil,
            runtime_limit_sources: %{optional(Elara.Session.Core.runtime_limit_key()) => :session},
            cleared_tools: %{optional(non_neg_integer()) => map()},
            context_usage_after: non_neg_integer(),
            read_only: boolean(),
            web_content_entered: boolean(),
            next_ref: pos_integer()
          }
    defstruct [
      :config,
      history: [],
      phase: :idle,
      streaming: nil,
      tool_usage: nil,
      mcp_guard: nil,
      retry: nil,
      pending_runtime_limits: nil,
      runtime_limit_sources: %{},
      cleared_tools: %{},
      context_usage_after: 0,
      read_only: false,
      web_content_entered: false,
      next_ref: 1,
      deferred_calls: [],
      steering?: false
    ]
  end

  @type fact ::
          {:ask, String.t()}
          | {:ask_input, User.t()}
          | {:provider_delta, ref(), Provider.delta()}
          | {:provider_settings, Elara.Provider.Visibility.settings()}
          | {:provider_catalog, Elara.Provider.Catalog.t()}
          | {:runtime_limits, runtime_limits(), [runtime_limit_key()]}
          | {:read_only, boolean()}
          | {:web_content_entered, ref()}
          | {:system_notice, Message.System.t()}
          | {:clear_tool_results, ref(), [map()], bytes_freed :: pos_integer()}
          | :runtime_limits_changed
          | {:provider_result, ref(), {:ok, Message.Assistant.t()} | {:error, Provider.Error.t()}}
          | {:retry_elapsed, ref()}
          | {:tool_checked, ref(), :allow | {:deny, String.t()} | {:ask, map()} | {:mcp, map()}}
          | {:tool_approved, ref()}
          | {:tool_result, ref(), Tool.outcome()}
          | {:tool_usage, ref(), Elara.Provider.Visibility.usage()}
          | {:tool_deferred, ref(), String.t()}
          | {:instruction_context, String.t()}
          | {:tool_crashed, ref(), reason :: String.t()}
          | {:tool_timeout, ref()}
          | :interrupt
          | :steer

  @type effect ::
          {:call_provider, ref(), Provider.Request.t()}
          | :persist_read_only
          | :persist_web_content
          | :persist_context_clearing
          | {:await_retry, ref(), min_ms :: non_neg_integer(), max_ms :: non_neg_integer()}
          | {:check_tool, ref(), ToolCall.t()}
          | {:run_tool, ref(), ToolCall.t(), Tool.t()}
          | {:emit, Elara.Event.t()}

  @spec new(Config.t()) :: State.t()
  def new(%Config{} = config) do
    new(config, [])
  end

  @doc """
  Build an idle state from persisted history, repairing unresolved tool calls.
  `boundary:` names the one call that may have been running when the session
  stopped (default: the first unresolved call; `nil`: none); see
  `repair_history/2`.
  """
  @spec new(Config.t(), [Message.t()], keyword()) :: State.t()
  def new(%Config{} = config, history, opts \\ []) when is_list(history) do
    boundary = Keyword.get(opts, :boundary, :first_unresolved)
    %State{config: config, history: repair_history(history, boundary), phase: :idle, next_ref: 1}
  end

  @spec rebase_history(State.t(), [Message.t()]) :: State.t()
  def rebase_history(%State{phase: :idle} = state, history) when is_list(history) do
    %{state | history: repair_history(history), cleared_tools: %{}, context_usage_after: 0}
  end

  @spec replace_tools(State.t(), %{String.t() => Tool.t()}) :: State.t()
  def replace_tools(%State{phase: :idle} = state, tools) when is_map(tools) do
    %{state | config: %{state.config | tools: tools}}
  end

  @restarted "session restarted while this call may have been running; " <>
               "its outcome is unknown and it may have partially changed the workspace"

  @doc """
  Give every unresolved trailing tool call a result. Calls run one at a time and
  a result is persisted before the next call starts, so only the boundary call
  can have started: with parsed arguments it fails closed as indeterminate,
  whatever today's tool config says, because that config cannot prove what the
  call was when it ran. Every other unresolved call never started and reports
  an ordinary error. It cannot tell whether the boundary call started at all.
  """
  @spec repair_history([Message.t()], :first_unresolved | String.t() | nil) :: [Message.t()]
  def repair_history(history, boundary \\ :first_unresolved) when is_list(history) do
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

        unresolved = Enum.reject(calls, &MapSet.member?(completed, &1.id))

        boundary =
          case {boundary, unresolved} do
            {:first_unresolved, [first | _]} -> first.id
            {:first_unresolved, []} -> nil
            {id, _} -> id
          end

        history ++ Enum.map(unresolved, &Message.tool_result(&1, restart_outcome(&1, boundary)))

      _ ->
        history
    end
  end

  defp restart_outcome(%ToolCall{id: id, args: {:ok, _}}, id), do: {:indeterminate, @restarted}
  defp restart_outcome(%ToolCall{}, _boundary), do: {:error, "interrupted"}

  @spec idle?(State.t()) :: boolean()
  def idle?(%State{phase: :idle}), do: true
  def idle?(%State{}), do: false

  @doc "Authoritative next-turn limits. Config remains the running turn's limits."
  @spec runtime_limits(State.t()) :: runtime_limits()
  def runtime_limits(%State{pending_runtime_limits: %{} = limits}), do: limits
  def runtime_limits(%State{} = state), do: Map.take(state.config, @runtime_limit_keys)

  @spec step(State.t(), fact()) :: {State.t(), [effect()]}
  def step(state, {:instruction_context, system}) when is_binary(system) do
    {%{state | config: %{state.config | system: system}}, []}
  end

  def step(%State{phase: :idle} = state, {:system_notice, %Message.System{} = notice}) do
    {%{state | history: state.history ++ [notice]}, [{:emit, {:message_appended, notice}}]}
  end

  def step(%State{phase: :idle} = state, {:ask, prompt}) when is_binary(prompt) do
    step(state, {:ask_input, Message.user(prompt)})
  end

  def step(%State{phase: :idle} = state, {:ask_input, %User{} = user}) do
    state = %{
      state
      | config: struct!(state.config, runtime_limits(state)),
        pending_runtime_limits: nil
    }

    prompt = user.text
    history = state.history ++ [user]

    {ref, state} =
      take_ref(%{state | history: history, deferred_calls: [], steering?: false, retry: nil})

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
    catalog = state.config.provider_catalog
    catalog = if catalog, do: Map.delete(catalog, "settings_notice"), else: nil

    {%{state | config: %{state.config | provider_settings: settings, provider_catalog: catalog}},
     [{:emit, :provider_view_changed}]}
  end

  def step(state, {:provider_catalog, catalog}) do
    {%{state | config: %{state.config | provider_catalog: catalog}},
     [{:emit, :provider_view_changed}]}
  end

  def step(state, {:runtime_limits, limits, keys}) do
    state =
      if idle?(state) do
        %{state | config: struct!(state.config, limits), pending_runtime_limits: nil}
      else
        pending = if limits == Map.take(state.config, @runtime_limit_keys), do: nil, else: limits
        %{state | pending_runtime_limits: pending}
      end

    sources = Enum.reduce(keys, state.runtime_limit_sources, &Map.put(&2, &1, :session))
    {%{state | runtime_limit_sources: sources}, [{:emit, :runtime_limits_changed}]}
  end

  def step(state, :inbox_changed), do: {state, [{:emit, :inbox_changed}]}
  def step(state, :runtime_limits_changed), do: {state, [{:emit, :runtime_limits_changed}]}

  def step(state, {:read_only, enabled}) when is_boolean(enabled) do
    {%{state | read_only: enabled}, [:persist_read_only, {:emit, :inbox_changed}]}
  end

  def step(
        %State{phase: {:running_tool, ref, _, _, _}, web_content_entered: false} = state,
        {:web_content_entered, ref}
      ) do
    {%{state | web_content_entered: true}, [:persist_web_content, {:emit, :inbox_changed}]}
  end

  def step(
        %State{phase: {:calling_provider, ref, _}} = state,
        {:clear_tool_results, ref, entries, _bytes_freed}
      ) do
    cleared = Enum.reduce(entries, state.cleared_tools, &Map.put(&2, &1.index, &1))
    state = %{state | cleared_tools: cleared, context_usage_after: length(state.history)}

    {state,
     [
       :persist_context_clearing,
       {:emit, :provider_view_changed},
       call_provider_effect(state, ref)
     ]}
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

  def step(%State{phase: {:calling_provider, _, _}, streaming: streaming} = state, :steer) do
    stop_stream(state, streaming, :interrupted)
  end

  def step(%State{phase: {:running_tool, _, _, _, _}} = state, :steer) do
    {%{state | steering?: true}, []}
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

      {%{state | phase: :idle, streaming: nil, retry: nil},
       [{:emit, streamed_turn_ended({:provider_error, error}, streaming)}]}
    else
      finish_provider(state, asst, streaming)
    end
  end

  def step(
        %State{phase: {:calling_provider, r, iteration}, streaming: streaming} = state,
        {:provider_result, r, {:error, error}}
      ) do
    case plan_retry(state, streaming, error) do
      {:retry, retry, window} -> await_retry(state, iteration, retry, window, error)
      :stop -> stop_stream(state, streaming, {:provider_error, error})
    end
  end

  def step(
        %State{phase: {:calling_provider, _, _}, streaming: streaming} = state,
        :interrupt
      ) do
    stop_stream(state, streaming, :interrupted)
  end

  def step(%State{phase: {:awaiting_retry, r, iteration, _, _}} = state, {:retry_elapsed, r}) do
    next_provider_attempt(state, iteration)
  end

  def step(%State{phase: {:awaiting_retry, _, _, _, _}} = state, fact)
      when fact in [:interrupt, :steer] do
    {%{state | phase: :idle, streaming: nil, retry: nil}, [{:emit, {:turn_ended, :interrupted}}]}
  end

  def step(
        %State{phase: {:checking_tool, r, call, rest, it}} = state,
        {:tool_checked, r, :allow}
      ) do
    start_tool(state, r, call, rest, it)
  end

  def step(
        %State{phase: {:checking_tool, r, call, rest, it}} = state,
        {:tool_checked, r, {:mcp, %{"mutating" => mutating} = guard}}
      )
      when is_boolean(mutating) do
    start_tool(%{state | mcp_guard: guard}, r, call, rest, it)
  end

  def step(
        %State{phase: {:checking_tool, r, call, rest, it}} = state,
        {:tool_checked, r, {:deny, reason}}
      ) do
    {state, effects} = reject_call(%{state | phase: :idle}, call, rest, it, reason)
    {state, [{:emit, {:command_blocked, call, reason}} | effects]}
  end

  def step(
        %State{phase: {:checking_tool, r, call, rest, it}} = state,
        {:tool_checked, r, {:ask, pending}}
      ) do
    {%{state | phase: {:approval_waiting, r, call, rest, it, pending}},
     [{:emit, {:approval_required, pending}}]}
  end

  def step(
        %State{phase: {:approval_waiting, r, call, rest, it, pending}} = state,
        {:tool_approved, r}
      ) do
    {state, effects} =
      if pending["kind"] in ["rules", "fnox"] do
        {%{state | phase: {:checking_tool, r, call, rest, it}}, [{:check_tool, r, call}]}
      else
        start_tool(state, r, call, rest, it)
      end

    {state, [{:emit, {:approval_granted, pending}} | effects]}
  end

  def step(
        %State{phase: {:approval_waiting, r, call, rest, it, _}} = state,
        {:tool_checked, r, decision}
      ) do
    step(%{state | phase: {:checking_tool, r, call, rest, it}}, {:tool_checked, r, decision})
  end

  def step(%State{phase: {:approval_waiting, _, call, rest, _, _}} = state, fact)
      when fact in [:interrupt, :steer] do
    cancel_unstarted(state, [call | rest])
  end

  def step(%State{phase: {:checking_tool, _, call, rest, _}} = state, fact)
      when fact in [:interrupt, :steer] do
    cancel_unstarted(state, [call | rest])
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

  def step(
        %State{phase: {:running_tool, r, _, _, _}, tool_usage: nil} = state,
        {:tool_usage, r, usage}
      )
      when is_map(usage) do
    {%{state | tool_usage: usage}, []}
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
    outcome =
      running_outcome(
        state,
        call,
        "tool crashed: #{reason}",
        "tool crashed while running: #{reason}"
      )

    finish_tool(state, call, rest, it, outcome)
  end

  def step(%State{phase: {:running_tool, r, call, rest, it}} = state, {:tool_timeout, r}) do
    message =
      if match?(%Tool{run: {Elara.Tools, :bash}}, state.config.tools[call.name]),
        do:
          "timed out while running; inspect the workspace before rerunning the bash call " <>
            "with a longer timeout_ms, up to the configured ceiling",
        else: "timed out while running"

    outcome = running_outcome(state, call, "timed out", message)
    finish_tool(state, call, rest, it, outcome)
  end

  def step(%State{phase: {:running_tool, _r, call, rest, _it}} = state, :interrupt) do
    interrupted = [call | rest]

    {history, emits} =
      Enum.reduce(Enum.with_index(interrupted), {state.history, []}, fn {c, index}, {hist, evs} ->
        # Only the first call was running; the rest never started.
        {usage, outcome} =
          if index == 0,
            do:
              {state.tool_usage,
               running_outcome(state, c, "interrupted", "interrupted while running")},
            else: {nil, {:error, "interrupted"}}

        result = Message.tool_result(c, outcome, usage)
        {hist ++ [result], evs ++ [{:emit, {:message_appended, result}}]}
      end)

    effects = emits ++ [{:emit, {:turn_ended, :interrupted}}]

    {%{state | history: history, phase: :idle, steering?: false, tool_usage: nil, mcp_guard: nil},
     effects}
  end

  def step(%State{} = state, _fact), do: {state, []}

  # A running mutating call that stops without its own result may have changed the
  # workspace partially, so it fails closed as indeterminate. A call that never
  # started, or one that cannot mutate, truthfully reports an error.
  defp running_outcome(state, %ToolCall{name: name}, error, uncertain) do
    mutating =
      if state.mcp_guard,
        do: state.mcp_guard["mutating"],
        else: match?(%Tool{mutating: true}, Map.get(state.config.tools, name))

    case mutating do
      true ->
        {:indeterminate, uncertain <> "; it may have partially changed the workspace"}

      _ ->
        {:error, error}
    end
  end

  # Every stop ends the turn, so the retry budget for the abandoned provider
  # call dies with it rather than carrying into the next one.
  defp stop_stream(%State{retry: retry} = state, streaming, outcome) when retry != nil,
    do: stop_stream(%{state | retry: nil}, streaming, outcome)

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

  # A failed attempt is replayable only while it has published nothing: no
  # streamed text, no typed public part, and no tool call (an errored attempt
  # never produces one). Once the operator or the transcript has seen output,
  # repeating the request would duplicate it, so the error surfaces instead.
  defp plan_retry(state, streaming, error) do
    failed = if state.retry, do: state.retry.attempts + 1, else: 1
    waited = if state.retry, do: state.retry.waited_ms, else: 0

    if published?(streaming) do
      :stop
    else
      case Retry.schedule(state.config.retry, failed, waited, error) do
        {:retry, window} ->
          {:retry, %{attempts: failed, waited_ms: waited + window.max_ms}, window}

        :stop ->
          :stop
      end
    end
  end

  defp published?(%{text: "", public_content: []}), do: false
  defp published?(%{}), do: true

  defp await_retry(state, iteration, retry, window, error) do
    {ref, state} = take_ref(state)
    attempt = retry.attempts + 1

    event =
      {:provider_retry,
       %{
         attempt: attempt,
         max_attempts: state.config.retry.max_attempts,
         delay_ms: window.max_ms,
         error: error
       }}

    {%{
       state
       | phase: {:awaiting_retry, ref, iteration, attempt, window.max_ms},
         streaming: nil,
         retry: retry
     }, [{:emit, event}, {:await_retry, ref, window.min_ms, window.max_ms}]}
  end

  defp next_provider_attempt(state, iteration) do
    {ref, state} = take_ref(state)

    {%{
       state
       | phase: {:calling_provider, ref, iteration},
         streaming: new_stream(ref, state.config.provider_settings)
     }, [call_provider_effect(state, ref)]}
  end

  defp finish_provider(state, asst, streaming) do
    asst = %{asst | request_settings: streaming.settings}
    history = state.history ++ [asst]
    state = %{state | history: history, streaming: nil, retry: nil}

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
    result = Message.tool_result(call, outcome, state.tool_usage)
    history = state.history ++ [result]
    state = %{state | history: history, phase: :idle, tool_usage: nil, mcp_guard: nil}

    {state, more} =
      if state.steering? do
        {history, emits} =
          Enum.reduce(rest, {state.history, []}, fn pending, {history, emits} ->
            result =
              Message.tool_result(pending, {:error, "not started: superseded by steering input"})

            {history ++ [result], emits ++ [{:emit, {:message_appended, result}}]}
          end)

        {%{state | history: history, steering?: false},
         emits ++ [{:emit, {:turn_ended, :interrupted}}]}
      else
        dispatch_next(state, rest, it)
      end

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

        if match?(%Tool{plugin: nil, name: "mcp_call"}, tool) or
             (state.config.command_preflight and
                (tool.name == "bash" or "shell" in tool.capabilities)) do
          {%{state | phase: {:checking_tool, ref, call, rest, iteration}},
           [{:check_tool, ref, call}]}
        else
          start_tool(state, ref, call, rest, iteration)
        end
    end
  end

  defp start_tool(state, ref, call, rest, iteration) do
    tool = Map.fetch!(state.config.tools, call.name)
    tool = if state.mcp_guard, do: %{tool | mutating: state.mcp_guard["mutating"]}, else: tool

    {%{state | phase: {:running_tool, ref, call, rest, iteration}},
     [{:emit, {:tool_started, call}}, {:run_tool, ref, call, tool}]}
  end

  defp cancel_unstarted(state, calls) do
    {history, effects} =
      Enum.reduce(calls, {state.history, []}, fn call, {history, effects} ->
        result = Message.tool_result(call, {:error, "not started: interrupted before approval"})
        {history ++ [result], effects ++ [{:emit, {:message_appended, result}}]}
      end)

    {%{state | history: history, phase: :idle, steering?: false},
     effects ++ [{:emit, {:turn_ended, :interrupted}}]}
  end

  defp reject_call(state, call, rest, iteration, reason) do
    result = Message.tool_result(call, {:error, reason})
    {state, more} = dispatch_next(%{state | history: state.history ++ [result]}, rest, iteration)
    {state, [{:emit, {:message_appended, result}} | more]}
  end

  # Retries belong to one provider call, so a new iteration starts with a fresh budget.
  defp next_provider_call(state, iteration) do
    state = %{state | retry: nil}

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
      messages: Elara.Session.Context.messages(state),
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

  # Suppress consecutive duplicates within one provider response. A later
  # response or intervening call may observe changed state; max_iterations
  # bounds loops across responses without treating arguments as cached results.
  defp repeated_call?(history, %ToolCall{} = call, deferred_calls) do
    case Enum.reverse(history) do
      [%ToolResult{call_id: previous_id} | rest] ->
        with false <- previous_id in deferred_calls,
             %Assistant{tool_calls: calls} <- Enum.find(rest, &is_struct(&1, Assistant)),
             %ToolCall{} = previous <- Enum.find(calls, &(&1.id == previous_id)) do
          call_fingerprint(previous) == call_fingerprint(call)
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp call_fingerprint(%ToolCall{name: name, args: args}), do: {name, args}
end
