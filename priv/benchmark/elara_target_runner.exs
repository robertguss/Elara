defmodule Elara.Benchmark.TargetRunner do
  @moduledoc false

  alias Elara.Effect.{ControllerJournal, TestExecutor}
  alias Elara.Message
  alias Elara.Message.{Assistant, ToolCall, ToolResult, User}

  @spec run(map()) :: map()
  def run(request) do
    remove_adapter_mix_environment()
    {:ok, hooks} = Agent.start_link(fn -> [] end)
    hook = fn point -> Agent.update(hooks, &[Atom.to_string(point) | &1]) end
    mapping = request["mapping"]

    call = %ToolCall{
      id: mapping["tool_call_id"],
      name: mapping["tool_name"],
      args: {:ok, mapping["tool_arguments"]}
    }

    {:ok, tool_turn} = Message.assistant(nil, [call])
    {:ok, final_turn} = Message.assistant(mapping["final_assistant_text"], [])
    {:ok, provider} = Agent.start_link(fn -> [{:ok, tool_turn}, {:ok, final_turn}] end)
    {executor, executor_config} = start_executor(request, hook)

    options = [
      provider: {Elara.Provider.Scripted, provider},
      cwd: request["workspace_root"],
      persist: false,
      plugins: [],
      tool_timeout_ms: request["tool_timeout_ms"],
      allowed_capabilities: :all
    ]

    options = receipt_options(options, request, executor, hook)
    {:ok, session} = Elara.start_session(options)
    ask_result = Elara.ask(session, request["prompt"])
    transcript = Elara.transcript(session)
    status = Elara.status(session)
    remaining_plan = Agent.get(provider, & &1)
    {:ok, session_pid} = Elara.session_pid(session)
    GenServer.stop(session_pid)

    receipt_evidence = receipt_evidence(request, executor, executor_config)
    hooks_observed = hooks |> Agent.get(&Enum.reverse/1)
    stop_executor(executor)

    tool_results = Enum.filter(transcript, &is_struct(&1, ToolResult))
    [tool_result] = tool_results

    %{
      "status" => "ok",
      "schema" => "elara.exp003.internal-adapter-observation.v1",
      "task_id" => request["task_id"],
      "condition" => request["condition"],
      "target_commit" => request["target_commit"],
      "runtime" => runtime(),
      "observed_outcome" => normalize_outcome(tool_result.outcome),
      "tool_result_kind" => tool_result.outcome |> elem(0) |> Atom.to_string(),
      "provider_plan_consumed" => remaining_plan == [],
      "provider_call_count" => 2 - length(remaining_plan),
      "tool_call_count" => length(tool_results),
      "session_result_count" => 1,
      "session_result" => normalize_ask_result(ask_result),
      "session_idle" =>
        status.phase == :idle and status.current_effect == nil and status.task_count == 0,
      "transcript_shape" => Enum.map(transcript, &message_shape/1),
      "hooks_observed" => hooks_observed,
      "receipt_evidence" => receipt_evidence
    }
  end

  defp start_executor(%{"condition" => "baseline"}, _hook), do: {nil, nil}

  defp start_executor(%{"condition" => "receipts"} = request, hook) do
    id = "exp003-receipt-equivalence"

    {:ok, executor} =
      TestExecutor.start_link(
        id: id,
        path: request["executor_ledger_path"],
        fault_hook: hook
      )

    Process.unlink(executor)
    {executor, TestExecutor.configuration(executor)}
  end

  defp receipt_options(options, %{"condition" => "baseline"}, nil, _hook), do: options

  defp receipt_options(options, %{"condition" => "receipts"} = request, executor, hook) do
    options ++
      [
        effect_executor: executor,
        effect_journal_path: request["controller_journal_path"],
        effect_fault_hook: hook
      ]
  end

  defp receipt_evidence(%{"condition" => "baseline"}, nil, nil), do: "not_applicable"

  defp receipt_evidence(%{"condition" => "receipts"} = request, executor, executor_config) do
    {:completed, record} = terminal_record(TestExecutor.query(executor, only_job_id(request)))
    journal = start_journal(request["controller_journal_path"])
    {:ok, [job]} = ControllerJournal.all(journal)
    {:ok, observation} = ControllerJournal.observation(journal, job.job_id)
    journal_config = ControllerJournal.configuration(journal)
    :ok = ControllerJournal.close(journal)

    %{
      "state" => Atom.to_string(record.state),
      "result_kind" => record.result |> elem(0) |> Atom.to_string(),
      "admission_count" => record.admission_count,
      "callback_attempt_count" => record.callback_attempt_count,
      "terminal_count" => record.terminal_count,
      "result_persisted" => observation.result_persisted?,
      "identity_consistent" =>
        job.job_id == record.job_id and job.operation_digest == record.operation_digest and
          observation.job_id == record.job_id and
          observation.operation_digest == record.operation_digest,
      "job_id_format_valid" => String.starts_with?(record.job_id, "er1j_v1_"),
      "operation_digest_format_valid" => byte_size(record.operation_digest) == 64,
      "executor_configuration" => stringify(executor_config),
      "controller_configuration" => stringify(journal_config)
    }
  end

  defp terminal_record({state, record}) when state in [:completed, :failed],
    do: {:completed, record}

  defp only_job_id(request) do
    journal = start_journal(request["controller_journal_path"])
    {:ok, [job]} = ControllerJournal.all(journal)
    :ok = ControllerJournal.close(journal)
    job.job_id
  end

  defp start_journal(path) do
    {:ok, journal} = ControllerJournal.start_link(path: path)
    Process.unlink(journal)
    journal
  end

  defp stop_executor(nil), do: :ok
  defp stop_executor(executor), do: TestExecutor.close(executor)

  defp normalize_outcome({:ok, _payload}), do: "ok"

  defp normalize_outcome({:error, "exit " <> rest}) do
    case Integer.parse(rest) do
      {status, _remainder} -> "error_exit_#{status}"
      :error -> "error"
    end
  end

  defp normalize_outcome({:error, message}) do
    if String.contains?(message, ["old_text not found", "need exactly one"]),
      do: "error_conflict",
      else: "error"
  end

  defp normalize_outcome({:indeterminate, _message}), do: "indeterminate"

  defp normalize_ask_result({:ok, text}), do: text
  defp normalize_ask_result({:error, reason}), do: "error:" <> inspect(reason)

  defp message_shape(%User{}), do: "user"
  defp message_shape(%Assistant{tool_calls: [_ | _]}), do: "assistant_tool_call"
  defp message_shape(%ToolResult{}), do: "tool_result"
  defp message_shape(%Assistant{}), do: "assistant_text"

  defp runtime do
    %{
      "elixir" => System.version(),
      "otp_release" => List.to_string(:erlang.system_info(:otp_release)),
      "erts" => List.to_string(:erlang.system_info(:version)),
      "system_architecture" => List.to_string(:erlang.system_info(:system_architecture))
    }
  end

  defp remove_adapter_mix_environment do
    Enum.each(~w(MIX_BUILD_PATH MIX_DEPS_PATH MIX_ENV), &System.delete_env/1)
  end

  defp stringify(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)
  end

  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end

[request_path, output_path] =
  case System.argv() do
    ["--", request_path, output_path] -> [request_path, output_path]
    [request_path, output_path] -> [request_path, output_path]
  end

result =
  try do
    request_path |> File.read!() |> JSON.decode!() |> Elara.Benchmark.TargetRunner.run()
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

File.write!(output_path, JSON.encode!(result))
if result["status"] == "error", do: System.halt(1)
