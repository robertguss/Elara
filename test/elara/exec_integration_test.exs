defmodule Elara.ExecIntegrationTest do
  use ExUnit.Case, async: false

  alias Elara.Exec
  alias Elara.Message
  alias Elara.Message.{ToolCall, ToolResult}

  @event_timeout 3_000
  @process_timeout 3_000

  defp assistant(text, calls \\ []) do
    {:ok, assistant} = Message.assistant(text, calls)
    assistant
  end

  defp provider(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    {Elara.Provider.Scripted, agent}
  end

  defp bash_call(id, command) do
    %ToolCall{id: id, name: "bash", args: {:ok, %{"command" => command}}}
  end

  defp start_bash_session(replies, opts) do
    bash = Enum.find(Elara.Tool.builtins(), &(&1.name == "bash"))

    Elara.start_session(
      Keyword.merge(
        [provider: provider(replies), tools: [bash], persist: false, plugins: []],
        opts
      )
    )
  end

  defp fixture(prefix) do
    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "#{prefix}-#{unique}")
    marker = "#{prefix}_#{unique}"
    ready = Path.join(root, "ready")
    File.mkdir_p!(root)

    on_exit(fn ->
      kill_markers(marker)
      File.rm_rf!(root)
    end)

    %{root: root, marker: marker, ready: ready}
  end

  test "public interrupt kills a shell and all background descendants" do
    fixture = fixture("elara_interrupt")

    command =
      "touch #{fixture.ready}; " <>
        "bash -c 'exec -a #{fixture.marker}_a sleep 30' & " <>
        "bash -c 'exec -a #{fixture.marker}_b sleep 30' & wait"

    {:ok, session} =
      start_bash_session(
        [
          {:ok, assistant(nil, [bash_call("interrupt", command)])}
        ],
        cwd: fixture.root,
        tool_timeout_ms: 10_000
      )

    :ok = Elara.subscribe(session)
    :ok = Elara.ask_async(session, "run descendants")

    assert_receive {:elara, ^session, {:tool_started, %ToolCall{id: "interrupt"}}},
                   @event_timeout

    assert_eventually(fn -> File.exists?(fixture.ready) end)
    assert_eventually(fn -> length(marker_pids(fixture.marker)) >= 2 end)

    Elara.interrupt(session)

    assert_receive {:elara, ^session,
                    {:message_appended,
                     %ToolResult{call_id: "interrupt", outcome: {:error, "interrupted"}}}},
                   @event_timeout

    assert_receive {:elara, ^session, {:turn_ended, :interrupted}}, @event_timeout
    assert_eventually(fn -> marker_pids(fixture.marker) == [] end)
  end

  test "public tool timeout kills its process group and reports timed out" do
    fixture = fixture("elara_timeout")
    command = long_sleep_command(fixture)

    {:ok, session} =
      start_bash_session(
        [
          {:ok, assistant(nil, [bash_call("timeout", command)])},
          {:ok, assistant("continued")}
        ],
        cwd: fixture.root,
        tool_timeout_ms: 1_000
      )

    task = Task.async(fn -> Elara.ask(session, "time out") end)
    assert_eventually(fn -> File.exists?(fixture.ready) end)
    assert_eventually(fn -> marker_pids(fixture.marker) != [] end)
    assert {:ok, "continued"} = Task.await(task, @event_timeout)

    assert %ToolResult{outcome: {:error, "timed out"}} =
             Enum.find(Elara.transcript(session), &match?(%ToolResult{call_id: "timeout"}, &1))

    assert_eventually(fn -> marker_pids(fixture.marker) == [] end)
  end

  test "public byte flood is killed at source with truthful accounting" do
    fixture = fixture("elara_flood")
    go = Path.join(fixture.root, "go")

    command =
      "touch #{fixture.ready}; " <>
        "while [ ! -f #{go} ]; do sleep 0.01; done; " <>
        "exec bash -c 'exec -a #{fixture.marker} yes'"

    {:ok, session} =
      start_bash_session(
        [
          {:ok, assistant(nil, [bash_call("flood", command)])},
          {:ok, assistant("continued")}
        ],
        cwd: fixture.root,
        max_tool_output_bytes: 128,
        tool_timeout_ms: 10_000
      )

    task = Task.async(fn -> Elara.ask(session, "flood") end)
    assert_eventually(fn -> File.exists?(fixture.ready) end)
    assert_eventually(fn -> marker_pids(fixture.marker) != [] end)
    File.touch!(go)
    assert {:ok, "continued"} = Task.await(task, @event_timeout)

    %ToolResult{outcome: {:error, message}} =
      Enum.find(Elara.transcript(session), &match?(%ToolResult{call_id: "flood"}, &1))

    assert [_, total, sent] =
             Regex.run(~r/bytes_total=(\d+) bytes_sent=(\d+)/, message)

    assert String.to_integer(sent) == 128
    assert String.to_integer(total) > String.to_integer(sent)
    assert_eventually(fn -> marker_pids(fixture.marker) == [] end)
  end

  test "stub death is indeterminate, guardians clean up, and the replacement runs" do
    fixture = fixture("elara_stub_death")
    first = bash_call("first", long_sleep_command(fixture))
    second = bash_call("second", "printf replacement")

    {:ok, session} =
      start_bash_session(
        [
          {:ok, assistant(nil, [first])},
          {:ok, assistant("after loss")},
          {:ok, assistant(nil, [second])},
          {:ok, assistant("continued")}
        ],
        cwd: fixture.root,
        tool_timeout_ms: 10_000
      )

    generation = Exec.status().generation
    task = Task.async(fn -> Elara.ask(session, "lose the stub") end)
    assert_eventually(fn -> File.exists?(fixture.ready) end)
    assert_eventually(fn -> marker_pids(fixture.marker) != [] end)

    {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(Exec.status().os_pid)])
    assert {:ok, "after loss"} = Task.await(task, @event_timeout)

    assert %ToolResult{outcome: {:indeterminate, message}} =
             Enum.find(Elara.transcript(session), &match?(%ToolResult{call_id: "first"}, &1))

    assert message =~ "execution outcome indeterminate"
    assert_eventually(fn -> marker_pids(fixture.marker) == [] end)
    assert_eventually(fn -> Exec.status().available and Exec.status().generation > generation end)

    assert {:ok, "continued"} = Elara.ask(session, "run after restart")

    assert %ToolResult{outcome: {:ok, "replacement"}} =
             Enum.find(Elara.transcript(session), &match?(%ToolResult{call_id: "second"}, &1))
  end

  test "raw execution timeout and flood expose terminal metadata" do
    assert {:ok, %Exec.Result{termination: :timed_out, signal: 9}} =
             Exec.run(["sleep", "30"], cwd: File.cwd!(), max_bytes: 64, timeout_ms: 50)

    assert {:ok,
            %Exec.Result{
              termination: :truncated,
              signal: 9,
              bytes_sent: 257,
              bytes_total: total,
              output: output
            }} = Exec.run(["yes"], cwd: File.cwd!(), max_bytes: 257, timeout_ms: 1_000)

    assert total > 257
    assert byte_size(output) == 257
  end

  test "abrupt BEAM death closes the Port and leaves no command descendants" do
    fixture = fixture("elara_beam_death")
    command = long_sleep_command(fixture)

    code = """
    Task.start(fn ->
      Elara.Exec.run(["/bin/sh", "-c", #{inspect(command)}],
        cwd: #{inspect(fixture.root)}, max_bytes: 1024, timeout_ms: 30_000)
    end)
    wait = fn wait, deadline ->
      cond do
        File.exists?(#{inspect(fixture.ready)}) -> :ok
        System.monotonic_time(:millisecond) >= deadline -> System.halt(2)
        true -> Process.sleep(10); wait.(wait, deadline)
      end
    end
    :ok = wait.(wait, System.monotonic_time(:millisecond) + 3_000)
    System.halt(0)
    """

    {_output, 0} =
      System.cmd("mix", ["run", "--no-compile", "--no-deps-check", "-e", code],
        cd: File.cwd!(),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert_eventually(fn -> marker_pids(fixture.marker) == [] end)
  end

  defp long_sleep_command(fixture) do
    "touch #{fixture.ready}; exec bash -c 'exec -a #{fixture.marker} sleep 30'"
  end

  defp marker_pids(marker) do
    case System.cmd("pgrep", ["-f", marker], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.to_integer/1)

      {_output, 1} ->
        []
    end
  end

  defp kill_markers(marker) do
    case marker_pids(marker) do
      [] ->
        :ok

      pids ->
        System.cmd("kill", ["-KILL" | Enum.map(pids, &Integer.to_string/1)],
          stderr_to_stdout: true
        )

        :ok
    end
  end

  defp assert_eventually(condition, timeout \\ @process_timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_assert_eventually(condition, deadline)
  end

  defp do_assert_eventually(condition, deadline) do
    cond do
      condition.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition did not become true within the deadline")

      true ->
        Process.sleep(10)
        do_assert_eventually(condition, deadline)
    end
  end
end
