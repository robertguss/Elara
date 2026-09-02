defmodule Elara.Effect.ProductionWriteTest do
  use ExUnit.Case, async: false

  alias Elara.Effect.{ControllerJournal, Executor, LocalExecutor}
  alias Elara.Effect.ExecutorLedger.Record
  alias Elara.Message
  alias Elara.Message.{Assistant, ToolCall, ToolResult, User}
  alias Elara.Session.Store

  @workspace_id "production-write-test"

  setup do
    root =
      Path.join(System.tmp_dir!(), "elara-production-write-#{System.unique_integer([:positive])}")

    cwd = Path.join(root, "workspace")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      cwd: cwd,
      journal_path: Path.join(root, "controller.sqlite3"),
      target: Path.join(cwd, "nested/output.txt")
    }
  end

  test "default public sessions write through durable receipts without router fallback",
       context do
    call = write_call("write-1", "nested/output.txt", "hello")
    provider = script([{:ok, assistant(nil, [call])}, {:ok, assistant("done")}])

    assert {:ok, session} =
             start_session(context, provider,
               persist: false,
               router: :router_must_not_receive_builtin_write
             )

    assert {:ok, "done"} = Elara.ask(session, "write it")
    assert File.read!(context.target) == "hello"

    assert [
             %User{text: "write it"},
             %Assistant{},
             %ToolResult{
               call_id: "write-1",
               name: "write",
               outcome: {:ok, "wrote 5 bytes to nested/output.txt"}
             },
             %Assistant{text: "done"}
           ] = Elara.transcript(session)

    {job, observation} = controller_evidence(context.journal_path)
    assert job.operation_kind == :declarative_write
    assert job.tool_name == "declarative_write"
    assert job.arguments["path"] == "nested/output.txt"
    assert observation.result_persisted?

    assert %Record{state: :completed, callback_attempt_count: 1, terminal_count: 1} =
             observation.executor_record

    executor = local_executor(context.cwd)
    executor_record = observation.executor_record
    assert {:completed, ^executor_record} = Executor.query(executor, job.job_id)

    stop_session(session)
    stop_local_executor(executor)
  end

  test "the local executor reopens terminal and attempted state and rejects digest changes",
       context do
    executor = local_executor(context.cwd)
    digest = digest("operation-a")

    assert {:accepted, %Record{callback_attempt_count: 0}} =
             Executor.submit(executor, "job-terminal", digest, fn -> {:ok, "complete"} end)

    assert :ok = Executor.continue(executor, "job-terminal")

    assert_receive {:elara_effect_executor, _id, "job-terminal",
                    {:completed, %Record{result: {:ok, "complete"}}}}

    first_pid = GenServer.whereis(executor)
    restart_executor(first_pid, executor)

    assert {:completed, %Record{callback_attempt_count: 1, terminal_count: 1}} =
             Executor.query(executor, "job-terminal")

    assert {:error, :digest_conflict} =
             Executor.submit(executor, "job-terminal", digest("operation-b"), fn ->
               {:ok, "must not run"}
             end)

    parent = self()
    attempted_digest = digest("attempted")

    assert {:accepted, %Record{}} =
             Executor.submit(executor, "job-attempted", attempted_digest, fn ->
               send(parent, {:callback_started, self()})
               receive do: (:never -> {:ok, "unreachable"})
             end)

    assert :ok = Executor.continue(executor, "job-attempted")
    assert_receive {:callback_started, attempted_pid}
    restart_executor(attempted_pid, executor)

    assert {:accepted, %Record{callback_attempt_count: 1, terminal_count: 0}} =
             Executor.query(executor, "job-attempted")

    assert {:error, :callback_already_attempted} =
             Executor.continue(executor, "job-attempted", attempted_digest, fn ->
               {:ok, "must not run"}
             end)

    stop_local_executor(executor)
  end

  test "persisted continuation returns terminal write evidence without rewriting", context do
    call = write_call("terminal-write", "nested/output.txt", "terminal")
    parent = self()

    hook = fn
      :after_completion_reply_before_session_result_persist = point ->
        block(parent, point)

      _point ->
        :ok
    end

    assert {:ok, session} =
             start_session(context, script([{:ok, assistant(nil, [call])}]),
               effect_fault_hook: hook
             )

    ask_unlinked(session)

    assert_receive {:blocked, :after_completion_reply_before_session_result_persist, effect_task}
    assert File.read!(context.target) == "terminal"
    before = File.stat!(context.target)
    session_path = newest_session_path(context.cwd)
    kill_session(session)
    send(effect_task, {:continue, :after_completion_reply_before_session_result_persist})

    assert {:ok, resumed} =
             start_session(context, script([]), resume: session_path)

    assert %ToolResult{
             call_id: "terminal-write",
             outcome: {:ok, "wrote 8 bytes to nested/output.txt"}
           } = List.last(Elara.transcript(resumed))

    after_recovery = File.stat!(context.target)

    assert {after_recovery.inode, after_recovery.mtime, after_recovery.size} ==
             {before.inode, before.mtime, before.size}

    {_job, observation} = controller_evidence(context.journal_path)
    assert observation.result_persisted?
    assert observation.executor_record.state == :completed

    executor = local_executor(context.cwd)
    stop_session(resumed)
    stop_local_executor(executor)
  end

  test "persisted continuation starts an accepted write only under its original identity",
       context do
    call = write_call("accepted-write", "nested/output.txt", "accepted")
    parent = self()

    hook = fn
      :after_accept_observation_before_continue = point -> block(parent, point)
      _point -> :ok
    end

    assert {:ok, session} =
             start_session(context, script([{:ok, assistant(nil, [call])}]),
               effect_fault_hook: hook
             )

    ask_unlinked(session)
    assert_receive {:blocked, :after_accept_observation_before_continue, effect_task}
    session_path = newest_session_path(context.cwd)
    kill_session(session)
    Process.exit(effect_task, :kill)

    {job, observation} = controller_evidence(context.journal_path)
    assert observation.executor_record.callback_attempt_count == 0
    executor = local_executor(context.cwd)
    assert {:accepted, %Record{callback_attempt_count: 0}} = Executor.query(executor, job.job_id)

    assert {:ok, resumed} = start_session(context, script([]), resume: session_path)

    assert %ToolResult{
             call_id: "accepted-write",
             outcome: {:ok, "wrote 8 bytes to nested/output.txt"}
           } = List.last(Elara.transcript(resumed))

    assert File.read!(context.target) == "accepted"

    assert {:completed, %Record{callback_attempt_count: 1, terminal_count: 1}} =
             Executor.query(executor, job.job_id)

    stop_session(resumed)
    stop_local_executor(executor)
  end

  test "persisted continuation reports attempted writes without terminal evidence as indeterminate",
       context do
    call = write_call("attempted-write", "nested/output.txt", "desired")
    parent = self()

    hook = fn
      :after_accept_observation_before_continue = point -> block(parent, point)
      _point -> :ok
    end

    assert {:ok, session} =
             start_session(context, script([{:ok, assistant(nil, [call])}]),
               effect_fault_hook: hook
             )

    ask_unlinked(session)
    assert_receive {:blocked, :after_accept_observation_before_continue, effect_task}
    session_path = newest_session_path(context.cwd)
    kill_session(session)
    Process.exit(effect_task, :kill)

    {job, _observation} = controller_evidence(context.journal_path)
    executor = local_executor(context.cwd)
    parent = self()

    assert :ok =
             Executor.continue(executor, job.job_id, job.operation_digest, fn ->
               send(parent, {:attempt_recorded, self()})
               receive do: (:never -> {:ok, "unreachable"})
             end)

    assert_receive {:attempt_recorded, executor_pid}
    restart_executor(executor_pid, executor)

    assert {:accepted, %Record{callback_attempt_count: 1, terminal_count: 0}} =
             Executor.query(executor, job.job_id)

    refute File.exists?(context.target)

    assert {:ok, resumed} = start_session(context, script([]), resume: session_path)

    assert %ToolResult{
             call_id: "attempted-write",
             outcome: {:indeterminate, message}
           } = List.last(Elara.transcript(resumed))

    assert message =~ "last_proven=callback_invoked"
    assert message =~ "action=do_not_retry_or_fail_over"
    refute File.exists?(context.target)

    {_job, observation} = controller_evidence(context.journal_path)
    assert observation.result_persisted?
    assert observation.executor_record.callback_attempt_count == 1

    stop_session(resumed)
    stop_local_executor(executor)
  end

  test "default production executors do not receipt edit", context do
    File.mkdir_p!(Path.dirname(context.target))
    File.write!(context.target, "old")

    call = %ToolCall{
      id: "edit-1",
      name: "edit",
      args: {:ok, %{"path" => "nested/output.txt", "old_text" => "old", "new_text" => "new"}}
    }

    provider = script([{:ok, assistant(nil, [call])}, {:ok, assistant("done")}])
    assert {:ok, session} = start_session(context, provider, persist: false)
    assert {:ok, "done"} = Elara.ask(session, "edit it")
    assert File.read!(context.target) == "new"

    {job, observation} = controller_evidence(context.journal_path)
    assert job.operation_kind == :run_tool
    assert job.tool_name == "edit"
    assert observation == nil

    executor = local_executor(context.cwd)
    assert :unknown = Executor.query(executor, job.job_id)

    stop_session(session)
    stop_local_executor(executor)
  end

  defp start_session(context, provider, opts) do
    Elara.start_session(
      [
        provider: provider,
        plugins: [],
        cwd: context.cwd,
        workspace_id: @workspace_id,
        effect_journal_path: context.journal_path
      ] ++ opts
    )
  end

  defp local_executor(cwd) do
    {:ok, executor} = LocalExecutor.open(cwd, @workspace_id)
    executor
  end

  defp stop_local_executor(executor) do
    case GenServer.whereis(executor) do
      pid when is_pid(pid) -> DynamicSupervisor.terminate_child(Elara.EffectExecutorSup, pid)
      nil -> :ok
    end
  end

  defp restart_executor(pid, executor) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    wait_for_executor(executor, pid, 100)
  end

  defp wait_for_executor(_executor, _old_pid, 0), do: flunk("local executor did not restart")

  defp wait_for_executor(executor, old_pid, attempts) do
    case GenServer.whereis(executor) do
      pid when is_pid(pid) and pid != old_pid ->
        :ok

      _other ->
        Process.sleep(10)
        wait_for_executor(executor, old_pid, attempts - 1)
    end
  end

  defp controller_evidence(path) do
    {:ok, journal} = ControllerJournal.start_link(path: path)
    Process.unlink(journal)
    assert {:ok, [job]} = ControllerJournal.all(journal)
    assert {:ok, observation} = ControllerJournal.observation(journal, job.job_id)
    assert :ok = ControllerJournal.close(journal)
    {job, observation}
  end

  defp write_call(id, path, content) do
    %ToolCall{id: id, name: "write", args: {:ok, %{"path" => path, "content" => content}}}
  end

  defp assistant(text, calls \\ []) do
    {:ok, message} = Message.assistant(text, calls)
    message
  end

  defp script(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    {Elara.Provider.Scripted, agent}
  end

  defp ask_unlinked(session) do
    parent = self()

    spawn(fn ->
      result =
        try do
          Elara.ask(session, "write it")
        catch
          :exit, reason -> {:exit, reason}
        end

      send(parent, {:ask_result, result})
    end)
  end

  defp block(parent, point) do
    send(parent, {:blocked, point, self()})

    receive do
      {:continue, ^point} -> :ok
    end
  end

  defp newest_session_path(cwd) do
    assert {:ok, info} = Store.newest(cwd)
    info.path
  end

  defp kill_session(session) do
    {:ok, pid} = Elara.session_pid(session)
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
  end

  defp stop_session(session) do
    {:ok, pid} = Elara.session_pid(session)
    GenServer.stop(pid)
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
