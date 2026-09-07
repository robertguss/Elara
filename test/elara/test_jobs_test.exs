defmodule Elara.TestJobsTest do
  use ExUnit.Case, async: false

  alias Elara.{Message, TestJobs, Tool}
  alias Elara.Session.Store

  defmodule Controlled do
    @behaviour Elara.Provider
    def chat(owner, request) do
      send(owner, {:model, self(), request})

      receive do
        {:answer, answer} -> {:ok, answer, owner}
      end
    end

    def stream(owner, request, _sink), do: chat(owner, request)
  end

  setup do
    root = Path.join(System.tmp_dir!(), "elara-test-job-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "test"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule JobFixture.MixProject do
      use Mix.Project
      def project, do: [app: :job_fixture, version: "0.1.0"]
    end
    """)

    File.write!(Path.join(root, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(root, "test/job_test.exs"), """
    defmodule JobFixtureTest do
      use ExUnit.Case
      test "controlled test" do
        File.write!("started", "1", [:append])
        File.write!("os_pid", System.pid())
        wait()
        assert true
      end
      defp wait do
        unless File.exists?("release") do
          Process.sleep(10)
          wait()
        end
      end
    end
    """)

    {:ok, session} =
      Elara.start_session(
        cwd: root,
        home: root,
        skill_paths: [],
        plugins: [],
        provider: {Controlled, self()}
      )

    {:ok, pid} = Elara.session_pid(session)
    ctx = %Tool.Ctx{session_id: session, cwd: root, tool_name: "test_job"}

    on_exit(fn ->
      File.write!(Path.join(root, "release"), "")
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(root)
    end)

    %{root: root, session: session, ctx: ctx}
  end

  defp answer(pid, text, calls \\ []) do
    send(pid, {:answer, %Message.Assistant{text: text, tool_calls: calls}})
  end

  defp await(fun, remaining \\ 500)
  defp await(_, 0), do: flunk("condition did not converge")

  defp await(fun, n) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          await(fun, n - 1)
        )
  end

  defp run(ctx, action, extra \\ %{}) do
    TestJobs.run(Map.merge(%{"action" => action, "job_id" => "focused"}, extra), ctx)
  end

  defp status(ctx) do
    {:ok, json} = run(ctx, "status")
    JSON.decode!(json)
  end

  defp inbox(session) do
    {:ok, pid} = Elara.session_pid(session)
    GenServer.call(pid, :thread_store).inbox
  end

  test "public tool starts a real test and one completion wakes the idle agent without polling",
       %{ctx: ctx, session: session, root: root} do
    Elara.ask_async(session, "run the focused test")
    assert_receive {:model, model, _}, 2000

    call = %Message.ToolCall{
      id: "start",
      name: "test_job",
      args: {:ok, %{"action" => "start", "job_id" => "focused", "target" => "test/job_test.exs"}}
    }

    answer(model, nil, [call])
    assert_receive {:model, model, request}, 2000
    assert List.last(request.messages).outcome |> elem(0) == :ok
    answer(model, "Waiting for test completion.")
    await(fn -> File.exists?(Path.join(root, "started")) end)
    refute_receive {:model, _, _}, 100

    assert {:ok, _} = run(ctx, "start", %{"target" => "test/job_test.exs"})
    assert {:error, _} = run(ctx, "start", %{"target" => "test/job_test.exs:3"})

    assert {:error, _} =
             run(ctx, "start", %{"job_id" => "second", "target" => "test/job_test.exs"})

    {:ok, other} =
      Elara.start_session(
        cwd: root,
        home: root,
        skill_paths: [],
        plugins: [],
        provider: {Controlled, self()}
      )

    {:ok, other_pid} = Elara.session_pid(other)
    on_exit(fn -> if Process.alive?(other_pid), do: GenServer.stop(other_pid) end)
    assert {:error, _} = run(%{ctx | session_id: other}, "status")
    Elara.ask_async(other, "unrelated work")
    assert_receive {:model, other_model, _}, 2000
    answer(other_model, "Other session remains usable.")
    File.write!(Path.join(root, "release"), "")

    assert_receive {:model, model, request}, 5000
    user = List.last(request.messages)
    assert user.agent_source["sender"] =~ "test-job:"
    assert user.text =~ "passed"
    answer(model, "The focused test passed.")
    await(fn -> status(ctx)["delivery"] == "accepted" end)

    # Model a crash after inbox acceptance but before the adapter saved its ack.
    {:ok, record} = Elara.TestJobs.Record.load(status(ctx)["key"])
    record = Map.put(record, "delivery", "pending")
    {:ok, store_root} = Store.root()
    path = Path.join([store_root, "_test_jobs", record["key"] <> ".json"])
    File.write!(path, JSON.encode!(record))
    old = Process.whereis(TestJobs)
    Process.exit(old, :kill)
    await(fn -> is_pid(Process.whereis(TestJobs)) and Process.whereis(TestJobs) != old end)
    send(TestJobs, :deliver)
    await(fn -> status(ctx)["delivery"] == "accepted" end)
    refute_receive {:model, _, _}, 100
    assert length(inbox(session)) == 1
    assert File.read!(Path.join(root, "started")) == "1"
    assert status(ctx)["source_changed_now"] == false
    File.write!(Path.join(root, "mix.exs"), "\n# later revision\n", [:append])
    assert status(ctx)["source_changed_now"] == true
  end

  test "execution epoch loss holds capacity until explicit reconciliation",
       %{ctx: ctx, session: session, root: root} do
    Elara.interrupt(session)
    assert {:ok, _} = run(ctx, "start", %{"target" => "test/job_test.exs"})
    await(fn -> File.exists?(Path.join(root, "os_pid")) end)
    os_pid = File.read!(Path.join(root, "os_pid"))
    old = Process.whereis(Elara.Exec)
    Process.exit(old, :kill)
    await(fn -> is_pid(Process.whereis(Elara.Exec)) and Process.whereis(Elara.Exec) != old end)
    await(fn -> status(ctx)["settlement"] == "unknown" end)
    assert status(ctx)["status"] == "indeterminate"
    assert status(ctx)["slot"] == "held"
    assert {:error, _} = run(ctx, "start", %{"job_id" => "next", "target" => "test/job_test.exs"})

    await(fn ->
      case System.cmd("ps", ["-p", os_pid, "-o", "stat="]) do
        {"", 1} -> true
        {stat, 0} -> String.starts_with?(String.trim(stat), "Z")
        _ -> false
      end
    end)

    assert {:ok, %{"slot" => "released", "status" => "indeterminate"}} =
             TestJobs.acknowledge_stopped(session, "focused")

    File.write!(Path.join(root, "release"), "")
    assert {:ok, _} = run(ctx, "start", %{"job_id" => "next", "target" => "test/job_test.exs"})

    await(fn ->
      {:ok, result} = run(ctx, "status", %{"job_id" => "next"})
      JSON.decode!(result)["status"] == "passed"
    end)

    assert File.read!(Path.join(root, "started")) == "11"
  end

  test "malformed retained records fail admission closed without crashing the manager",
       %{ctx: ctx} do
    {:ok, store_root} = Store.root()
    path = Path.join([store_root, "_test_jobs", String.duplicate("0", 64) <> ".json"])
    File.mkdir_p!(Path.dirname(path))

    on_exit(fn ->
      File.rm(path)
      Supervisor.terminate_child(Elara.Supervisor, TestJobs)
      Supervisor.restart_child(Elara.Supervisor, TestJobs)
    end)

    for malformed <- ["[]", "{}", ~s({"version":1,"status":"passed"})] do
      File.write!(path, malformed)
      :ok = Supervisor.terminate_child(Elara.Supervisor, TestJobs)
      {:ok, manager} = Supervisor.restart_child(Elara.Supervisor, TestJobs)
      assert {:error, _} = run(ctx, "start", %{"target" => "test/job_test.exs"})
      send(manager, :deliver)
      assert {:error, _} = run(ctx, "status")
      assert Process.whereis(TestJobs) == manager
    end
  end

  test "saved records reject contradictory lifecycle and terminal evidence", %{
    ctx: ctx,
    session: session
  } do
    Elara.interrupt(session)
    assert {:ok, _} = run(ctx, "start", %{"target" => "test/job_test.exs"})
    assert {:ok, _} = run(ctx, "cancel")
    await(fn -> status(ctx)["status"] == "cancelled" end)
    alias Elara.TestJobs.Record
    {:ok, terminal} = Record.load(status(ctx)["key"])
    key = Record.key(terminal["owner"], "invalid-evidence")
    valid = Map.merge(terminal, %{"key" => key, "job_id" => "invalid-evidence"})
    path = Path.join(Record.root(), key <> ".json")
    on_exit(fn -> File.rm(path) end)
    assert :ok = Record.save(valid)

    for invalid <- [
          Map.put(valid, "status", "running"),
          Map.put(valid, "execution", nil),
          Map.put(valid, "signal", 0),
          Map.put(valid, "bytes_total", valid["bytes_sent"] + 1),
          Map.merge(valid, %{"status" => "truncated", "termination" => "truncated"}),
          Map.merge(valid, %{
            "status" => "passed",
            "termination" => "exited",
            "exit_code" => 0,
            "signal" => 9
          }),
          Map.put(valid, "bytes_sent", valid["bytes_total"] + 1),
          Map.put(valid, "output", 12),
          Map.delete(valid, "exit_code"),
          put_in(valid, ["execution", "pid"], "<0.999999999999999999999999999.0>")
        ] do
      File.write!(path, JSON.encode!(invalid))
      assert {:error, :invalid_job_record} = Record.load(key)
    end
  end

  test "handoff successor owns status, cancellation and the single completion", %{root: root} do
    {:ok, source} =
      Elara.start_session(
        cwd: root,
        home: root,
        skill_paths: [],
        plugins: [],
        provider: {Controlled, self()},
        pause_inputs: true,
        context_limit: 100_000,
        max_tool_output_bytes: 1024,
        system: "test",
        tools: [TestJobs.tool()],
        seed_history: [%Message.Assistant{text: String.duplicate("e", 60_000)}]
      )

    ctx = %Tool.Ctx{session_id: source, cwd: root, tool_name: "test_job"}

    on_exit(fn ->
      for id <- Enum.uniq([source, Elara.Session.Handoff.owner(source)]) do
        case Elara.session_pid(id) do
          {:ok, pid} -> GenServer.stop(pid)
          _ -> :ok
        end
      end
    end)

    assert {:ok, _} = run(ctx, "start", %{"target" => "test/job_test.exs"})
    await(fn -> File.exists?(Path.join(root, "started")) end)
    assert {:error, :interrupted} = Elara.ask(source, "continue after handoff")
    await(fn -> Elara.Session.Handoff.owner(source) != source end)
    successor = Elara.Session.Handoff.owner(source)
    successor_ctx = %{ctx | session_id: successor}
    assert status(successor_ctx)["job_id"] == "focused"
    assert {:ok, _} = run(successor_ctx, "cancel")
    await(fn -> status(successor_ctx)["status"] == "cancelled" end)
    await(fn -> Enum.count(inbox(successor), &(&1.kind == :report)) == 1 end)
    refute Enum.any?(inbox(source), &(&1.kind == :report))
    refute_receive {:model, _, _}, 100
  end

  test "queued start from a stopped tool caller is rejected", %{ctx: ctx, root: root} do
    manager = Process.whereis(TestJobs)
    :ok = :sys.suspend(manager)

    try do
      {:ok, caller} = Task.start(fn -> run(ctx, "start", %{"target" => "test/job_test.exs"}) end)

      await(fn ->
        {:messages, messages} = Process.info(manager, :messages)
        Enum.any?(messages, &match?({:"$gen_call", {^caller, _}, {"start", _, _, _}}, &1))
      end)

      ref = Process.monitor(caller)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^ref, :process, ^caller, :killed}
    after
      :sys.resume(manager)
    end

    assert {:error, _} = run(ctx, "status")
    refute File.exists?(Path.join(root, "started"))
  end

  test "blocked inbox delivery does not block another job's admission or cancellation",
       %{ctx: ctx, session: session, root: root} do
    Elara.interrupt(session)

    {:ok, other} =
      Elara.start_session(
        cwd: root,
        home: root,
        skill_paths: [],
        plugins: [],
        provider: {Controlled, self()},
        inputs_paused: true
      )

    {:ok, other_pid} = Elara.session_pid(other)
    on_exit(fn -> if Process.alive?(other_pid), do: GenServer.stop(other_pid) end)
    other_ctx = %{ctx | session_id: other}
    assert {:ok, _} = run(ctx, "start", %{"target" => "test/job_test.exs"})
    await(fn -> File.exists?(Path.join(root, "started")) end)
    {:ok, recipient} = Elara.session_pid(session)
    :ok = :sys.suspend(recipient)

    try do
      File.write!(Path.join(root, "release"), "")
      await(fn -> status(ctx)["status"] == "passed" end)
      await(fn -> not is_nil(:sys.get_state(TestJobs).delivery_task) end)
      File.rm!(Path.join(root, "release"))
      start = Task.async(fn -> run(other_ctx, "start", %{"target" => "test/job_test.exs"}) end)
      assert {:ok, _} = Task.await(start, 1000)
      cancel = Task.async(fn -> run(other_ctx, "cancel") end)
      assert {:ok, _} = Task.await(cancel, 1000)
      await(fn -> status(other_ctx)["status"] == "cancelled" end)
    after
      :sys.resume(recipient)
    end
  end

  test "invalid targets and ephemeral sessions cannot start jobs", %{ctx: ctx, root: root} do
    for target <- [
          "--help",
          "test",
          "../test/job_test.exs",
          "test/../mix.exs",
          "test/job_test.exs:0"
        ] do
      assert {:error, _} = run(ctx, "start", %{"target" => target})
    end

    {:ok, ephemeral} =
      Elara.start_session(
        cwd: root,
        home: root,
        skill_paths: [],
        plugins: [],
        persist: false,
        provider: {Controlled, self()}
      )

    {:ok, pid} = Elara.session_pid(ephemeral)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert {:error, _} =
             run(%{ctx | session_id: ephemeral}, "start", %{"target" => "test/job_test.exs"})

    refute File.exists?(Path.join(root, "started"))
  end

  test "runner crash is indeterminate and does not stop the session or manager",
       %{ctx: ctx, session: session, root: root} do
    Elara.interrupt(session)
    assert {:ok, _} = run(ctx, "start", %{"target" => "test/job_test.exs"})
    await(fn -> File.exists?(Path.join(root, "started")) end)
    manager = Process.whereis(TestJobs)
    [{_, running}] = Map.to_list(:sys.get_state(manager).active)
    Process.exit(running.task.pid, :kill)
    await(fn -> status(ctx)["status"] == "indeterminate" end)
    assert Process.whereis(TestJobs) == manager
    assert {:ok, _} = Elara.session_pid(session)
    assert File.read!(Path.join(root, "started")) == "1"
  end

  test "paused and offline recipient retains completion; resume never reruns the command",
       %{ctx: ctx, session: session, root: root} do
    Elara.interrupt(session)
    assert {:ok, _} = run(ctx, "start", %{"target" => "test/job_test.exs"})
    await(fn -> File.exists?(Path.join(root, "started")) end)
    {:ok, pid} = Elara.session_pid(session)
    store = GenServer.call(pid, :thread_store)
    GenServer.stop(pid)
    File.write!(Path.join(root, "release"), "")
    await(fn -> status(ctx)["status"] == "passed" end)
    refute_receive {:model, _, _}, 100

    assert {:ok, ^session} =
             Elara.start_session(
               resume: store.path,
               cwd: root,
               home: root,
               skill_paths: [],
               plugins: [],
               provider: {Controlled, self()}
             )

    on_exit(fn ->
      case Elara.session_pid(session) do
        {:ok, resumed} -> GenServer.stop(resumed)
        _ -> :ok
      end
    end)

    await(fn -> length(inbox(session)) == 1 end)
    refute_receive {:model, _, _}, 100
    Elara.resume_inputs(session)
    assert_receive {:model, model, _}, 2000
    answer(model, "read completion")
    assert File.read!(Path.join(root, "started")) == "1"
  end

  test "cancellation returns confirmed terminal evidence and source changes are visible",
       %{ctx: ctx, root: root, session: session} do
    Elara.interrupt(session)
    assert {:ok, _} = run(ctx, "start", %{"target" => "test/job_test.exs"})
    await(fn -> File.exists?(Path.join(root, "started")) end)
    File.write!(Path.join(root, "test/job_test.exs"), "\n# changed\n", [:append])
    assert {:ok, _} = run(ctx, "cancel")
    await(fn -> status(ctx)["status"] == "cancelled" end)
    result = status(ctx)
    assert result["source_changed_now"]
    assert result["source_changed"]
    assert result["termination"] == "cancelled"
    refute_receive {:model, _, _}, 100
  end

  test "manager crash does not replay the command and preserves uncertainty",
       %{ctx: ctx, session: session, root: root} do
    Elara.interrupt(session)
    assert {:ok, _} = run(ctx, "start", %{"target" => "test/job_test.exs"})
    await(fn -> File.exists?(Path.join(root, "started")) end)
    old = Process.whereis(TestJobs)
    Process.exit(old, :kill)
    await(fn -> is_pid(Process.whereis(TestJobs)) and Process.whereis(TestJobs) != old end)
    await(fn -> status(ctx)["status"] == "indeterminate" end)
    assert {:ok, _} = run(ctx, "start", %{"target" => "test/job_test.exs"})
    assert File.read!(Path.join(root, "started")) == "1"
    refute_receive {:model, _, _}, 100
  end
end
