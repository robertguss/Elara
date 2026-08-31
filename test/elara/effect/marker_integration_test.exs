defmodule Elara.Effect.MarkerIntegrationTest do
  use ExUnit.Case, async: false

  alias Elara.Effect.ControllerJournal
  alias Elara.Effect.ControllerJournal.Observation
  alias Elara.Effect.ExecutorLedger
  alias Elara.Effect.ExecutorLedger.Record
  alias Elara.Effect.TestExecutor
  alias Elara.Message
  alias Elara.Message.{ToolCall, ToolResult}
  alias Elara.Session.Store
  alias Elara.Tool
  alias Elara.Tool.Ctx

  defmodule MarkerTool do
    def run(
          %{"path" => path, "token" => token},
          %Ctx{job_id: job_id, operation_digest: operation_digest}
        )
        when is_binary(job_id) and is_binary(operation_digest) do
      record = %{
        "job_id" => job_id,
        "operation_digest" => operation_digest,
        "token" => token
      }

      File.write!(path, JSON.encode!(record) <> "\n", [:append])
      {:ok, "marker #{token} committed"}
    end
  end

  defmodule ReadTool do
    def run(%{"path" => path}, %Ctx{}), do: {:ok, File.read!(path)}
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "elara-marker-integration-#{System.unique_integer([:positive])}"
      )

    cwd = Path.join(root, "workspace")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      cwd: cwd,
      marker_path: Path.join(cwd, "marker.jsonl"),
      journal_path: Path.join(root, "controller.sqlite3"),
      executor_path: Path.join(root, "executor.sqlite3")
    }
  end

  test "normal execution and identity replays produce one causally linked mutation and result",
       context do
    executor = start_executor(context.executor_path)
    call = marker_call(context.marker_path, "normal")
    provider = script([{:ok, assistant(nil, [call])}, {:ok, assistant("done")}])
    session = start_marker_session(context, executor, provider)

    assert {:ok, "done"} = Elara.ask(session, "run marker")

    {job, observation} = controller_evidence(context.journal_path)
    assert job.tool_call_id == call.id
    assert observation.result_persisted?
    assert %Record{} = observation.executor_record

    assert {:completed, %Record{} = completed} = TestExecutor.query(executor, job.job_id)
    assert completed == observation.executor_record
    assert completed.admission_count == 1
    assert completed.callback_attempt_count == 1
    assert completed.terminal_count == 1

    assert [marker] = marker_records(context.marker_path)
    assert marker["job_id"] == job.job_id
    assert marker["operation_digest"] == job.operation_digest
    assert marker["token"] == "normal"

    results = Enum.filter(Elara.transcript(session), &is_struct(&1, ToolResult))

    assert [
             %ToolResult{
               call_id: "marker-call",
               outcome: {:ok, "marker normal committed"}
             }
           ] = results

    recording = Elara.recording(session)
    assert job.effect_id.recording_id == recording.header.recording_id

    result_transition =
      Enum.find(recording.transitions, fn transition ->
        match?(%{kind: :tool_result}, transition.fact)
      end)

    assert result_transition.caused_by == %{
             transition: Map.take(job.effect_id, [:recording_id, :sequence]),
             effect_index: job.effect_id.effect_index
           }

    assert {:completed, ^completed} =
             TestExecutor.submit(executor, job.job_id, job.operation_digest, fn ->
               raise "duplicate submit invoked callback"
             end)

    assert {:completed, ^completed} = TestExecutor.query(executor, job.job_id)
    assert marker_records(context.marker_path) == [marker]

    conflicting_digest =
      String.duplicate(if(String.starts_with?(job.operation_digest, "a"), do: "b", else: "a"), 64)

    assert {:error, :digest_conflict} =
             TestExecutor.submit(executor, job.job_id, conflicting_digest, fn ->
               raise "conflicting submit invoked callback"
             end)

    assert marker_records(context.marker_path) == [marker]
    stop_session(session)
    assert :ok = TestExecutor.close(executor)
  end

  test "controller restart after intent commit submits the same identity once", context do
    parent = self()

    controller_hook = fn
      :after_intent_commit_before_dispatch = point -> block(parent, :controller_hook, point)
      _point -> :ok
    end

    executor = start_executor(context.executor_path)
    call = marker_call(context.marker_path, "intent-recovery")
    provider = script([{:ok, assistant(nil, [call])}])
    session = start_marker_session(context, executor, provider, controller_hook)
    call_ask_unlinked(session)

    assert_receive {:controller_hook, :after_intent_commit_before_dispatch, _journal}, 1_000
    {job, nil} = controller_evidence(context.journal_path)
    assert :unknown = TestExecutor.query(executor, job.job_id)
    store_path = newest_store_path(context.cwd)
    kill_session(session)

    recovered =
      start_marker_session(context, executor, script([]), fn _point -> :ok end, store_path)

    assert [%ToolResult{outcome: {:ok, "marker intent-recovery committed"}}] =
             tool_results(recovered)

    assert [marker] = marker_records(context.marker_path)
    assert marker["job_id"] == job.job_id
    assert {:completed, %Record{} = completed} = TestExecutor.query(executor, job.job_id)

    assert {completed.admission_count, completed.callback_attempt_count, completed.terminal_count} ==
             {1, 1, 1}

    assert %Observation{result_persisted?: true, executor_record: ^completed} =
             observation(context.journal_path, job.job_id)

    stop_session(recovered)
    assert :ok = TestExecutor.close(executor)
  end

  test "controller terminal observation commits before the session result", context do
    parent = self()

    controller_hook = fn
      :after_completion_reply_before_session_result_persist = point ->
        block(parent, :controller_hook, point)

      _point ->
        :ok
    end

    executor = start_executor(context.executor_path)
    call = marker_call(context.marker_path, "observation-order")

    provider =
      script([{:ok, assistant(nil, [call])}, {:ok, assistant("done")}])

    session = start_marker_session(context, executor, provider, controller_hook)
    call_ask_unlinked(session)

    assert_receive {:controller_hook, :after_completion_reply_before_session_result_persist,
                    task},
                   1_000

    {job, %Observation{result_persisted?: false, executor_record: completed}} =
      controller_evidence(context.journal_path)

    assert completed.state == :completed
    assert tool_results(session) == []
    assert [_marker] = marker_records(context.marker_path)

    send(task, {:continue, :after_completion_reply_before_session_result_persist})
    assert_receive {:ask_result, {:ok, "done"}}, 1_000

    assert [%ToolResult{outcome: {:ok, "marker observation-order committed"}}] =
             tool_results(session)

    assert %Observation{result_persisted?: true, executor_record: ^completed} =
             observation(context.journal_path, job.job_id)

    stop_session(session)
    assert :ok = TestExecutor.close(executor)
  end

  test "lost acceptance reply recovers accepted evidence without failover or resubmission",
       context do
    parent = self()

    executor_hook = fn
      :after_accept_commit_before_accept_reply = point -> block(parent, :executor_hook, point)
      _point -> :ok
    end

    executor = start_executor(context.executor_path, executor_hook)
    call = marker_call(context.marker_path, "acceptance-recovery")
    session = start_marker_session(context, executor, script([{:ok, assistant(nil, [call])}]))
    call_ask_unlinked(session)

    assert_receive {:executor_hook, :after_accept_commit_before_accept_reply, ^executor}, 1_000
    {job, nil} = controller_evidence(context.journal_path)
    store_path = newest_store_path(context.cwd)
    kill_session(session)
    send(executor, {:continue, :after_accept_commit_before_accept_reply})

    assert {:accepted, %Record{callback_attempt_count: 0}} =
             TestExecutor.query(executor, job.job_id)

    recovered =
      start_marker_session(context, executor, script([]), fn _point -> :ok end, store_path)

    assert [%ToolResult{outcome: {:ok, "marker acceptance-recovery committed"}}] =
             tool_results(recovered)

    assert [_marker] = marker_records(context.marker_path)

    assert {:completed, %Record{admission_count: 1, callback_attempt_count: 1}} =
             TestExecutor.query(executor, job.job_id)

    stop_session(recovered)
    assert :ok = TestExecutor.close(executor)
  end

  test "lost completion reply recovers terminal evidence without invoking the marker again",
       context do
    parent = self()

    executor_hook = fn
      :after_completion_commit_before_completion_reply = point ->
        block(parent, :executor_hook, point)

      _point ->
        :ok
    end

    executor = start_executor(context.executor_path, executor_hook)
    call = marker_call(context.marker_path, "completion-recovery")
    session = start_marker_session(context, executor, script([{:ok, assistant(nil, [call])}]))
    call_ask_unlinked(session)

    assert_receive {:executor_hook, :after_completion_commit_before_completion_reply, ^executor},
                   1_000

    {job, %Observation{executor_record: %Record{state: :accepted}}} =
      controller_evidence(context.journal_path)

    assert [_marker] = marker_records(context.marker_path)
    store_path = newest_store_path(context.cwd)
    kill_session(session)
    send(executor, {:continue, :after_completion_commit_before_completion_reply})
    assert {:completed, completed} = TestExecutor.query(executor, job.job_id)

    recovered =
      start_marker_session(context, executor, script([]), fn _point -> :ok end, store_path)

    assert [%ToolResult{outcome: {:ok, "marker completion-recovery committed"}}] =
             tool_results(recovered)

    assert length(marker_records(context.marker_path)) == 1

    assert %Observation{result_persisted?: true, executor_record: ^completed} =
             observation(context.journal_path, job.job_id)

    stop_session(recovered)
    assert :ok = TestExecutor.close(executor)
  end

  test "attempt proof without terminal evidence becomes one honest indeterminate result",
       context do
    parent = self()

    executor_hook = fn
      :after_external_mutation_before_completion_commit = point ->
        block(parent, :executor_hook, point)

      _point ->
        :ok
    end

    executor = start_executor(context.executor_path, executor_hook)
    call = marker_call(context.marker_path, "indeterminate")
    session = start_marker_session(context, executor, script([{:ok, assistant(nil, [call])}]))
    call_ask_unlinked(session)

    assert_receive {:executor_hook, :after_external_mutation_before_completion_commit, ^executor},
                   1_000

    {job, %Observation{executor_record: %Record{state: :accepted}}} =
      controller_evidence(context.journal_path)

    assert [_marker] = marker_records(context.marker_path)
    store_path = newest_store_path(context.cwd)
    kill_session(session)
    kill_executor(executor)

    reopened = start_executor(context.executor_path)

    assert {:accepted, %Record{callback_attempt_count: 1, terminal_count: 0}} =
             TestExecutor.query(reopened, job.job_id)

    recovered =
      start_marker_session(context, reopened, script([]), fn _point -> :ok end, store_path)

    assert [%ToolResult{outcome: {:indeterminate, message}}] = tool_results(recovered)
    assert message =~ "job_id=#{job.job_id}"
    assert message =~ "operation_digest=#{job.operation_digest}"
    assert message =~ "workspace_id=#{job.workspace_id}"
    assert message =~ "last_proven=callback_invoked"
    assert message =~ "missing=completed_or_failed"
    assert message =~ "action=do_not_retry_or_fail_over"
    assert length(marker_records(context.marker_path)) == 1

    assert {:accepted, attempted} = TestExecutor.query(reopened, job.job_id)
    assert ExecutorLedger.last_proven_fact(attempted) == :callback_invoked

    assert %Observation{result_persisted?: true, executor_record: ^attempted} =
             observation(context.journal_path, job.job_id)

    stop_session(recovered)
    assert :ok = TestExecutor.close(reopened)
  end

  test "nonmutating tools retain the direct path when the sidecar is configured", context do
    source = Path.join(context.cwd, "source.txt")
    File.write!(source, "read directly")
    executor = start_executor(context.executor_path)

    call = %ToolCall{
      id: "read-call",
      name: "probe_read",
      args: {:ok, %{"path" => source}}
    }

    tool = %Tool{
      name: "probe_read",
      version: "1",
      description: "read test file",
      parameters: %{"type" => "object"},
      capabilities: ["filesystem:read"],
      mutating: false,
      run: {ReadTool, :run}
    }

    session =
      start_session(
        context,
        executor,
        script([{:ok, assistant(nil, [call])}, {:ok, assistant("done")}]),
        [tool]
      )

    assert {:ok, "done"} = Elara.ask(session, "read")
    assert [%ToolResult{outcome: {:ok, "read directly"}}] = tool_results(session)

    journal = start_journal(context.journal_path)
    assert {:ok, []} = ControllerJournal.all(journal)
    assert :ok = ControllerJournal.close(journal)

    stop_session(session)
    assert :ok = TestExecutor.close(executor)
  end

  defp start_marker_session(
         context,
         executor,
         provider,
         fault_hook \\ fn _point -> :ok end,
         resume \\ nil
       ) do
    start_session(context, executor, provider, [marker_tool()], fault_hook, resume)
  end

  defp start_session(
         context,
         executor,
         provider,
         tools,
         fault_hook \\ fn _point -> :ok end,
         resume \\ nil
       ) do
    opts = [
      provider: provider,
      tools: tools,
      plugins: [],
      cwd: context.cwd,
      effect_executor: executor,
      effect_journal_path: context.journal_path,
      effect_fault_hook: fault_hook
    ]

    opts = if resume, do: Keyword.put(opts, :resume, resume), else: opts
    {:ok, session} = Elara.start_session(opts)
    session
  end

  defp marker_tool do
    %Tool{
      name: "marker",
      version: "1",
      description: "append a non-deduplicating ER-1 marker",
      parameters: %{"type" => "object"},
      capabilities: ["filesystem:write"],
      mutating: true,
      placement: :local,
      run: {MarkerTool, :run}
    }
  end

  defp marker_call(path, token) do
    %ToolCall{
      id: "marker-call",
      name: "marker",
      args: {:ok, %{"path" => path, "token" => token}}
    }
  end

  defp script(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    {Elara.Provider.Scripted, agent}
  end

  defp assistant(text, calls \\ []) do
    {:ok, assistant} = Message.assistant(text, calls)
    assistant
  end

  defp start_executor(path, hook \\ fn _point -> :ok end) do
    {:ok, executor} = TestExecutor.start_link(id: "executor-1", path: path, fault_hook: hook)
    Process.unlink(executor)
    executor
  end

  defp start_journal(path) do
    {:ok, journal} = ControllerJournal.start_link(path: path)
    Process.unlink(journal)
    journal
  end

  defp controller_evidence(path) do
    journal = start_journal(path)
    assert {:ok, [job]} = ControllerJournal.all(journal)
    assert {:ok, observation} = ControllerJournal.observation(journal, job.job_id)
    assert :ok = ControllerJournal.close(journal)
    {job, observation}
  end

  defp observation(path, job_id) do
    journal = start_journal(path)
    assert {:ok, observation} = ControllerJournal.observation(journal, job_id)
    assert :ok = ControllerJournal.close(journal)
    observation
  end

  defp marker_records(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.map(&JSON.decode!/1)

      {:error, :enoent} ->
        []
    end
  end

  defp tool_results(session) do
    Enum.filter(Elara.transcript(session), &is_struct(&1, ToolResult))
  end

  defp newest_store_path(cwd) do
    {:ok, info} = Store.newest(cwd)
    info.path
  end

  defp block(parent, tag, point) do
    send(parent, {tag, point, self()})

    receive do
      {:continue, ^point} -> :ok
    end
  end

  defp call_ask_unlinked(session) do
    parent = self()

    spawn(fn ->
      result =
        try do
          Elara.ask(session, "run marker")
        catch
          :exit, reason -> {:exit, reason}
        end

      send(parent, {:ask_result, result})
    end)
  end

  defp kill_session(session) do
    {:ok, pid} = Elara.session_pid(session)
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000
  end

  defp kill_executor(executor) do
    monitor = Process.monitor(executor)
    Process.exit(executor, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^executor, :killed}, 1_000
  end

  defp stop_session(session) do
    {:ok, pid} = Elara.session_pid(session)
    GenServer.stop(pid)
  end
end
