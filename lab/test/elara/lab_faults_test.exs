defmodule Elara.LabFaultsTest do
  # Not async: the exec-stub fault kills the VM-wide stub.
  use ExUnit.Case, async: false

  alias Elara.Lab.{Faults, Tools}
  alias Elara.Message.ToolResult
  alias Elara.Provider.Simulated

  @fast [ttft_ms: 5, deltas_per_sec: 1000, delta_bytes: 4, answer_deltas: 3, tool_rounds: 0]

  setup do
    dir = Path.join(System.tmp_dir!(), "lab-faults-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp start(dir, schedule, profile, tools \\ []) do
    provider =
      Simulated.new(
        seed: 1,
        id: "s1",
        profile: profile,
        collector: self(),
        fault: Faults.hook(schedule, self())
      )

    {:ok, id} = Elara.start_session(provider: provider, cwd: dir, plugins: [], tools: tools)
    {:ok, pid} = Elara.session_pid(id)
    {id, pid}
  end

  test "a session fault at provider start kills the session", %{dir: dir} do
    {id, pid} = start(dir, %{{"s1:1", :provider_started} => :session}, @fast)
    ref = Process.monitor(pid)

    catch_exit(Elara.ask(id, "go"))
    assert_receive {:lab_fault, "s1:1", :provider_started, :session}
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  test "a named session fault kills that session from outside it", %{dir: dir} do
    {id, pid} = start(dir, %{}, @fast)
    assert {:ok, _} = Elara.ask(id, "go")
    ref = Process.monitor(pid)

    assert :ok = Faults.inject({:session, id})
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert :ok = Faults.inject({:session, id})
  end

  test "a task fault mid-stream fails the turn and the session survives", %{dir: dir} do
    {id, pid} = start(dir, %{{"s1:1", :provider_streaming} => :task}, @fast)

    assert {:error, _reason} = Elara.ask(id, "go")
    assert_receive {:lab_fault, "s1:1", :provider_streaming, :task}
    assert Process.alive?(pid)

    # The next request (s1:2) has no scheduled fault and completes.
    assert {:ok, _text} = Elara.ask(id, "again")
  end

  test "a session fault inside a running mutation leaves the partial write", %{dir: dir} do
    Tools.register_hook("h1", Faults.hook(%{{"s1:1", :tool_running} => :session}, self()))
    on_exit(fn -> Tools.unregister_hook("h1") end)

    plan = [
      {"lab_marker", %{"path" => "marks.txt", "label" => "one", "hook" => "h1", "key" => "$key"}}
    ]

    {id, pid} =
      start(dir, %{}, Keyword.merge(@fast, tool_rounds: 1, tool_plan: plan), [Tools.marker()])

    ref = Process.monitor(pid)

    catch_exit(Elara.ask(id, "mark"))
    assert_receive {:lab_fault, "s1:1", :tool_running, :session}
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert File.read!(Path.join(dir, "marks.txt")) == "one\n"
  end

  test "an exec-stub fault is recovered for later commands", %{dir: dir} do
    before = Elara.Exec.status()
    Tools.register_hook("h2", Faults.hook(%{{"s1:1", :tool_running} => :exec_stub}, self()))
    on_exit(fn -> Tools.unregister_hook("h2") end)

    plan = [
      {"lab_marker", %{"path" => "marks.txt", "label" => "two", "hook" => "h2", "key" => "$key"}}
    ]

    {id, _pid} =
      start(dir, %{}, Keyword.merge(@fast, tool_rounds: 1, tool_plan: plan), [Tools.marker()])

    assert {:ok, _text} = Elara.ask(id, "mark")
    assert_receive {:lab_fault, "s1:1", :tool_running, :exec_stub}

    assert [%ToolResult{outcome: {:ok, "marked two"}}] =
             Enum.filter(Elara.transcript(id), &is_struct(&1, ToolResult))

    wait = fn wait, n ->
      status = Elara.Exec.status()

      if status.available and status.os_pid != before.os_pid,
        do: :ok,
        else:
          (n > 0 &&
             (
               Process.sleep(20)
               wait.(wait, n - 1)
             )) || flunk("stub not restarted")
    end

    wait.(wait, 200)

    assert {:ok, %Elara.Exec.Result{code: 0}} =
             Elara.Exec.run(["/bin/echo", "ok"], cwd: dir, timeout_ms: 5_000)
  end
end
