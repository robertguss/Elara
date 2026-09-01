defmodule Elara.Benchmark.LemonTargetRunner do
  @moduledoc false

  alias CodingAgent.{Session, SettingsManager}
  alias CodingAgent.Tools.{Bash, Edit, Write}
  alias LemonAi.Types.{AssistantMessage, Model, ModelCost, TextContent, ToolCall, Usage, Cost}

  @spec run(map()) :: map()
  def run(request) do
    mapping = request["mapping"]

    tool_call = %ToolCall{
      type: :tool_call,
      id: mapping["tool_call_id"],
      name: mapping["tool_name"],
      arguments: mapping["tool_arguments"],
      thought_signature: nil
    }

    responses = [
      assistant_message([tool_call], :tool_use),
      assistant_message([%TextContent{type: :text, text: mapping["final_assistant_text"]}], :stop)
    ]

    {:ok, response_queue} = Agent.start_link(fn -> {responses, 0} end)
    stream_fn = stream_fn(response_queue)

    options = [
      cwd: request["workspace_root"],
      workspace_dir: request["lemon_workspace_root"],
      session_id: "exp003-#{request["task_id"]}",
      model: model(),
      settings_manager: settings(),
      system_prompt: "Execute exactly the supplied deterministic tool call.",
      tools: tools(request["workspace_root"]),
      stream_fn: stream_fn,
      register: false,
      thinking_level: :off,
      python_repl_mod: nil
    ]

    {:ok, session} = Session.start_link(options)
    unsubscribe = Session.subscribe(session)
    :ok = Session.prompt(session, request["prompt"])
    {:ok, events} = collect_events([], 10_000)
    messages = Session.get_messages(session)
    state = Session.get_state(session)
    unsubscribe.()
    GenServer.stop(session)

    {_remaining, stream_call_count} = Agent.get(response_queue, & &1)
    Agent.stop(response_queue)

    tool_starts = Enum.filter(events, &match?({:tool_execution_start, _, _, _}, &1))
    tool_ends = Enum.filter(events, &match?({:tool_execution_end, _, _, _, _}, &1))
    agent_ends = Enum.filter(events, &match?({:agent_end, _}, &1))
    [{:tool_execution_start, observed_id, observed_name, observed_arguments}] = tool_starts
    [{:tool_execution_end, ^observed_id, ^observed_name, _result, tool_error}] = tool_ends

    %{
      "status" => "ok",
      "schema" => "elara.exp003.external-adapter-observation.v1",
      "task_id" => request["task_id"],
      "runtime" => runtime(),
      "observed_outcome" => if(tool_error, do: "error", else: "ok"),
      "provider_plan_consumed" => stream_call_count == 2,
      "stream_call_count" => stream_call_count,
      "tool_execution_start_count" => length(tool_starts),
      "tool_execution_end_count" => length(tool_ends),
      "agent_end_count" => length(agent_ends),
      "tool_error" => tool_error,
      "tool_call_identity_matches" =>
        observed_id == mapping["tool_call_id"] and observed_name == mapping["tool_name"],
      "tool_arguments_match" => observed_arguments == mapping["tool_arguments"],
      "session_idle" => state.is_streaming == false,
      "transcript_shape" => Enum.map(messages, &message_shape/1),
      "native_lifecycle" => Enum.map(events, &event_name/1)
    }
  end

  defp tools(cwd) do
    [
      Write.tool(cwd, format: false, diagnostics: false, checkpoint: false),
      Edit.tool(cwd, diagnostics: false, checkpoint: false),
      Bash.tool(cwd, timeout_ms: 5_000)
    ]
  end

  defp settings do
    %SettingsManager{
      default_thinking_level: :off,
      compaction_enabled: false,
      retry_enabled: false,
      max_retries: 0,
      extension_paths: [],
      extension_auto_load_default_paths: false,
      providers: %{}
    }
  end

  defp model do
    %Model{
      id: "elara-exp003-deterministic",
      name: "Elara EXP-003 deterministic",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://invalid.local",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0},
      context_window: 128_000,
      max_tokens: 4_096,
      headers: %{},
      compat: nil
    }
  end

  defp assistant_message(content, stop_reason) do
    %AssistantMessage{
      role: :assistant,
      content: content,
      api: :mock,
      provider: :mock_provider,
      model: "elara-exp003-deterministic",
      usage: %Usage{
        input: 0,
        output: 0,
        cache_read: 0,
        cache_write: 0,
        total_tokens: 0,
        cost: %Cost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
      },
      stop_reason: stop_reason,
      error_message: nil,
      timestamp: 0
    }
  end

  defp stream_fn(queue) do
    fn _model, _context, _options ->
      response =
        Agent.get_and_update(queue, fn
          {[head | tail], count} -> {head, {tail, count + 1}}
          {[], count} -> {nil, {[], count}}
        end)

      if response do
        {:ok, response_stream(response)}
      else
        {:error, :unexpected_extra_model_turn}
      end
    end
  end

  defp response_stream(response) do
    {:ok, stream} = LemonAi.EventStream.start_link()

    Task.start(fn ->
      LemonAi.EventStream.push(stream, {:start, response})

      response.content
      |> Enum.with_index()
      |> Enum.each(fn
        {%TextContent{text: text}, index} ->
          LemonAi.EventStream.push(stream, {:text_start, index, response})
          LemonAi.EventStream.push(stream, {:text_delta, index, text, response})
          LemonAi.EventStream.push(stream, {:text_end, index, text, response})

        {%ToolCall{} = call, index} ->
          LemonAi.EventStream.push(stream, {:tool_call_start, index, response})
          LemonAi.EventStream.push(stream, {:tool_call_end, index, call, response})
      end)

      LemonAi.EventStream.push(stream, {:done, response.stop_reason, response})
      LemonAi.EventStream.complete(stream, response)
    end)

    stream
  end

  defp collect_events(events, timeout_ms) do
    receive do
      {:session_event, _session_id, {:agent_end, _messages} = event} ->
        {:ok, Enum.reverse([event | events])}

      {:session_event, _session_id, {:error, reason, _partial}} ->
        {:error, {:session_error, reason}}

      {:session_event, _session_id, event} ->
        collect_events([event | events], timeout_ms)
    after
      timeout_ms -> {:error, :session_timeout}
    end
  end

  defp message_shape(%LemonAi.Types.UserMessage{}), do: "user"

  defp message_shape(%AssistantMessage{content: content}) do
    if Enum.any?(content, &is_struct(&1, ToolCall)),
      do: "assistant_tool_call",
      else: "assistant_text"
  end

  defp message_shape(%LemonAi.Types.ToolResultMessage{}), do: "tool_result"
  defp message_shape(_message), do: "other"

  defp event_name({:agent_start}), do: "agent_start"
  defp event_name({:turn_start}), do: "turn_start"
  defp event_name({:message_start, _message}), do: "message_start"
  defp event_name({:message_end, _message}), do: "message_end"
  defp event_name({:tool_execution_start, _, _, _}), do: "tool_execution_start"
  defp event_name({:tool_execution_update, _, _, _}), do: "tool_execution_update"
  defp event_name({:tool_execution_end, _, _, _, _}), do: "tool_execution_end"
  defp event_name({:turn_end, _, _}), do: "turn_end"
  defp event_name({:agent_end, _}), do: "agent_end"
  defp event_name(event), do: event |> elem(0) |> to_string()

  defp runtime do
    %{
      "elixir" => System.version(),
      "otp_release" => List.to_string(:erlang.system_info(:otp_release)),
      "erts" => List.to_string(:erlang.system_info(:version)),
      "system_architecture" => List.to_string(:erlang.system_info(:system_architecture))
    }
  end
end

[request_path, output_path] =
  case System.argv() do
    ["--", request_path, output_path] -> [request_path, output_path]
    [request_path, output_path] -> [request_path, output_path]
  end

result =
  try do
    request_path |> File.read!() |> Jason.decode!() |> Elara.Benchmark.LemonTargetRunner.run()
  rescue
    error ->
      %{
        "status" => "error",
        "kind" => "exception",
        "message" => Exception.message(error),
        "exception" => inspect(error.__struct__)
      }
  catch
    kind, reason ->
      %{"status" => "error", "kind" => to_string(kind), "message" => inspect(reason)}
  end

File.write!(output_path, Jason.encode!(result))
if result["status"] == "error", do: System.halt(1)
