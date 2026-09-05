defmodule Elara.InputQueueRecoveryTest do
  use ExUnit.Case, async: false

  alias Elara.Effect.ControllerJournal
  alias Elara.Effect.ExecutorLedger
  alias Elara.Effect.ExecutorLedger.Record
  alias Elara.Effect.TestExecutor
  alias Elara.Message
  alias Elara.Message.{ToolCall, ToolResult}
  alias Elara.Session.Store
  alias Elara.Tool

  @timeout 1_000

  defmodule MutationTool do
    def run(%{"owner" => owner}, _ctx) do
      owner = String.to_existing_atom(owner)
      send(owner, {:mutation_started, self()})

      receive do
        :release -> {:ok, "mutation committed"}
      end
    end
  end

  test "restored queued input waits for an authoritative terminal receipt despite an indeterminate result" do
    root =
      Path.join(System.tmp_dir!(), "elara-input-recovery-#{System.unique_integer([:positive])}")

    cwd = Path.join(root, "workspace")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(root) end)

    Process.register(self(), :input_queue_recovery_owner)

    on_exit(fn ->
      if Process.whereis(:input_queue_recovery_owner),
        do: Process.unregister(:input_queue_recovery_owner)
    end)

    executor_path = Path.join(root, "executor.sqlite3")
    journal_path = Path.join(root, "controller.sqlite3")

    {:ok, executor} = TestExecutor.start_link(id: "executor-1", path: executor_path)

    Process.unlink(executor)

    first_provider =
      script([
        {:ok,
         assistant(nil, [
           %ToolCall{
             id: "mutation-call",
             name: "mutation",
             args: {:ok, %{"owner" => "input_queue_recovery_owner"}}
           }
         ])}
      ])

    {:ok, session} =
      Elara.start_session(
        provider: first_provider,
        tools: [mutation_tool()],
        plugins: [],
        cwd: cwd,
        effect_executor: executor,
        effect_journal_path: journal_path
      )

    assert {:ok, _} = Elara.submit_input(session, attrs("active", "start mutation"))
    assert_receive {:mutation_started, _mutation_task}, @timeout
    assert {:ok, _} = Elara.submit_input(session, attrs("queued", "after recovery"))
    {:ok, info} = Store.newest(cwd)
    kill_session(session)
    job_id = only_job_id(journal_path)
    kill_executor(executor)

    {:ok, executor} = TestExecutor.start_link(id: "executor-1", path: executor_path)
    Process.unlink(executor)

    assert {:accepted, %Record{callback_attempt_count: 1} = accepted} =
             TestExecutor.query(executor, job_id)

    queued_reply = {:ok, assistant("queued done")}
    {:ok, resumed_agent} = Agent.start_link(fn -> [queued_reply] end)
    resumed_provider = {Elara.Provider.Scripted, resumed_agent}

    {:ok, resumed} =
      Elara.start_session(
        provider: resumed_provider,
        tools: [mutation_tool()],
        plugins: [],
        cwd: cwd,
        resume: info.path,
        effect_executor: executor,
        effect_journal_path: journal_path
      )

    on_exit(fn ->
      if match?({:ok, _}, Elara.session_pid(resumed)), do: stop_session(resumed)
      if Process.alive?(executor), do: TestExecutor.close(executor)
    end)

    assert [%ToolResult{outcome: {:indeterminate, _}}] = tool_results(resumed)
    assert {:ok, %{state: :consumed}} = Elara.input_status(resumed, "active")
    assert {:ok, %{state: :queued}} = Elara.input_status(resumed, "queued")
    assert Agent.get(resumed_agent, & &1) == [queued_reply]

    Process.sleep(75)
    assert {:ok, %{state: :consumed}} = Elara.input_status(resumed, "active")
    assert {:ok, %{state: :queued}} = Elara.input_status(resumed, "queued")
    assert Agent.get(resumed_agent, & &1) == [queued_reply]

    # Supply the terminal receipt that the crashed executor would have committed
    # after the already-proven callback invocation.
    {:ok, ledger} = ExecutorLedger.open(executor_path)

    assert {:ok, %Record{state: :completed}} =
             ExecutorLedger.finish(
               ledger,
               "executor-1",
               job_id,
               accepted.operation_digest,
               {:ok, "mutation committed"}
             )

    assert :ok = ExecutorLedger.close(ledger)

    assert_eventually(fn ->
      match?({:completed, %Record{}}, TestExecutor.query(executor, job_id))
    end)

    assert_eventually(fn ->
      match?({:ok, %{state: :failed}}, Elara.input_status(resumed, "active"))
    end)

    assert_eventually(fn ->
      match?({:ok, %{state: :consumed}}, Elara.input_status(resumed, "queued"))
    end)

    assert Agent.get(resumed_agent, & &1) == []

    assert Enum.count(
             Elara.transcript(resumed),
             &match?(%Message.User{text: "after recovery"}, &1)
           ) == 1

    assert Enum.count(
             Elara.transcript(resumed),
             &match?(%Message.Assistant{text: "queued done"}, &1)
           ) == 1
  end

  test "live queued input waits for an unsettled timed-out mutation to reach a terminal receipt" do
    root =
      Path.join(
        System.tmp_dir!(),
        "elara-input-live-timeout-#{System.unique_integer([:positive])}"
      )

    cwd = Path.join(root, "workspace")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(root) end)

    Process.register(self(), :input_queue_recovery_owner)

    on_exit(fn ->
      if Process.whereis(:input_queue_recovery_owner),
        do: Process.unregister(:input_queue_recovery_owner)
    end)

    executor_path = Path.join(root, "executor.sqlite3")
    journal_path = Path.join(root, "controller.sqlite3")
    {:ok, executor} = TestExecutor.start_link(id: "executor-1", path: executor_path)
    Process.unlink(executor)

    queued_reply = {:ok, assistant("queued done")}

    {:ok, provider_agent} =
      Agent.start_link(fn ->
        [
          {:ok,
           assistant(nil, [
             %ToolCall{
               id: "live-mutation-call",
               name: "mutation",
               args: {:ok, %{"owner" => "input_queue_recovery_owner"}}
             }
           ])},
          {:ok, assistant("active timed out")},
          queued_reply
        ]
      end)

    {:ok, session} =
      Elara.start_session(
        provider: {Elara.Provider.Scripted, provider_agent},
        tools: [mutation_tool()],
        plugins: [],
        cwd: cwd,
        effect_executor: executor,
        effect_journal_path: journal_path,
        tool_timeout_ms: 50
      )

    on_exit(fn ->
      if match?({:ok, _}, Elara.session_pid(session)), do: stop_session(session)
      if Process.alive?(executor), do: TestExecutor.close(executor)
    end)

    assert {:ok, _} = Elara.submit_input(session, attrs("active", "start live mutation"))
    assert_receive {:mutation_started, mutation_task}, @timeout
    assert {:ok, _} = Elara.submit_input(session, attrs("queued", "after live timeout"))

    assert_eventually(fn ->
      Enum.any?(tool_results(session), &match?(%ToolResult{outcome: {:error, "timed out"}}, &1))
    end)

    assert_eventually(fn ->
      match?({:ok, %{state: :consumed}}, Elara.input_status(session, "active"))
    end)

    assert {:ok, %{state: :queued}} = Elara.input_status(session, "queued")
    assert Agent.get(provider_agent, & &1) == [queued_reply]

    Process.sleep(75)
    assert {:ok, %{state: :queued}} = Elara.input_status(session, "queued")
    assert Agent.get(provider_agent, & &1) == [queued_reply]

    send(mutation_task, :release)
    job_id = only_job_id(journal_path)

    assert_eventually(fn ->
      match?({:completed, %Record{}}, TestExecutor.query(executor, job_id))
    end)

    assert_eventually(fn ->
      match?({:ok, %{state: :consumed}}, Elara.input_status(session, "queued"))
    end)

    assert Agent.get(provider_agent, & &1) == []

    assert Enum.count(
             Elara.transcript(session),
             &match?(%Message.User{text: "after live timeout"}, &1)
           ) == 1

    assert Enum.count(
             Elara.transcript(session),
             &match?(%Message.Assistant{text: "queued done"}, &1)
           ) == 1
  end

  defp mutation_tool do
    %Tool{
      name: "mutation",
      version: "1",
      description: "test mutation",
      parameters: %{"type" => "object"},
      capabilities: ["filesystem:write"],
      mutating: true,
      placement: :local,
      run: {MutationTool, :run}
    }
  end

  defp attrs(id, text), do: %{id: id, sender_id: "test", kind: :normal, user: Message.user(text)}

  defp assistant(text, calls \\ []) do
    {:ok, message} = Message.assistant(text, calls)
    message
  end

  defp script(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    {Elara.Provider.Scripted, agent}
  end

  defp tool_results(session),
    do: Enum.filter(Elara.transcript(session), &is_struct(&1, ToolResult))

  defp only_job_id(path) do
    {:ok, journal} = ControllerJournal.start_link(path: path)
    Process.unlink(journal)
    {:ok, [job]} = ControllerJournal.all(journal)
    :ok = ControllerJournal.close(journal)
    job.job_id
  end

  defp assert_eventually(fun, attempts \\ 100)
  defp assert_eventually(_fun, 0), do: flunk("state did not converge")

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp kill_session(session) do
    {:ok, pid} = Elara.session_pid(session)
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, @timeout
  end

  defp kill_executor(executor) do
    monitor = Process.monitor(executor)
    Process.exit(executor, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^executor, :killed}, @timeout
  end

  defp stop_session(session) do
    {:ok, pid} = Elara.session_pid(session)
    GenServer.stop(pid)
  end
end
