defmodule Elara.ExecOutputPolicyTest do
  use ExUnit.Case, async: false

  alias Elara.Exec

  setup do
    marker = "elara_job_output_#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), marker)
    File.mkdir_p!(root)
    {:ok, resources} = Agent.start(fn -> [] end)

    on_exit(fn ->
      for resource <- Agent.get(resources, & &1) do
        case resource do
          {:task, task, token} ->
            stop_task(task, token)

          {:stub, pid, os_pid} ->
            current =
              if Process.alive?(pid) do
                try do
                  :ok = :sys.suspend(pid)
                  current = :sys.get_state(pid).os_pid
                  :ok = GenServer.stop(pid)
                  current
                after
                  if Process.alive?(pid), do: Process.exit(pid, :kill)
                end
              end

            for observed <- Enum.reject([os_pid, current], &is_nil/1),
                do: eventually(fn -> Elara.Lab.ProcessProbe.stopped?(observed) end)
        end
      end

      assert pids(marker) == []
      File.rm_rf!(root)
      Agent.stop(resources)
    end)

    %{root: root, marker: marker, resources: resources}
  end

  @tag :policy_red
  test "head/tail cap preserves a later side effect, suffix and nonzero exit", ctx do
    prefix = "HEAD" <> String.duplicate("x", 60)

    task =
      run(
        ctx,
        [
          "bash",
          "-c",
          "printf '#{prefix}'; sleep 0.15; printf TAIL_END; touch completed; exit 7"
        ],
        max_bytes: 32,
        timeout_ms: 5_000,
        output_policy: :head_tail
      )

    assert {:ok, result} = Task.await(task, 10_000)
    assert result.termination == :exited
    assert result.code == 7
    assert result.signal == nil
    assert File.exists?(Path.join(ctx.root, "completed"))
    assert result.output == "HEAD" <> String.duplicate("x", 20) <> "TAIL_END"
    assert result.bytes_total == 72
    assert result.bytes_sent == 32
    assert Map.get(result, :output_capped) == true
  end

  @tag :policy_red
  test "continuous capped output still reaches the native deadline", ctx do
    task =
      run(ctx, ["bash", "-c", "exec -a #{ctx.marker} yes flood"],
        max_bytes: 31,
        timeout_ms: 200,
        output_policy: :head_tail
      )

    assert {:ok, result} = Task.await(task, 5_000)
    assert result.termination == :timed_out
    assert result.signal == 9
    assert result.bytes_total > 31
    assert result.bytes_sent == 31
    assert byte_size(result.output) == 31
    assert Map.get(result, :output_capped) == true
    eventually(fn -> pids(ctx.marker) == [] end)
  end

  for {cap, expected, retained, capped} <- [
        {1, "z", 1, true},
        {5, "abxyz", 5, true},
        {32, "abcdefghijklmnopqrstuvwxyz", 26, false}
      ] do
    @tag :policy_red
    test "head/tail handles cap #{cap} with exact accounting", ctx do
      task =
        run(ctx, ["printf", "abcdefghijklmnopqrstuvwxyz"],
          max_bytes: unquote(cap),
          output_policy: :head_tail
        )

      assert {:ok, result} = Task.await(task, 5_000)
      assert result.termination == :exited
      assert result.code == 0
      assert result.output == unquote(expected)
      assert result.bytes_total == 26
      assert result.bytes_sent == unquote(retained)
      assert Map.get(result, :output_capped) == unquote(capped)
    end
  end

  test "capped output remains cancellable with authoritative terminal evidence", ctx do
    task =
      run(
        ctx,
        ["bash", "-c", "printf '#{String.duplicate("x", 256)}'; exec -a #{ctx.marker} sleep 30"],
        max_bytes: 32,
        timeout_ms: 30_000,
        output_policy: :head_tail
      )

    eventually(fn -> pids(ctx.marker) != [] end)
    assert {:ok, :requested} = Exec.cancel(task.pid)
    assert {:ok, result} = Task.await(task, 5_000)
    assert result.termination == :cancelled
    assert result.signal == 9
    assert result.bytes_total == 256
    assert result.bytes_sent == 32
    assert Map.get(result, :output_capped) == true
    eventually(fn -> pids(ctx.marker) == [] end)
  end

  test "forced failure settles the owned runner and native process before root removal", ctx do
    token = Exec.token()

    task =
      run(ctx, ["bash", "-c", "exec -a #{ctx.marker} sleep 30"],
        output_policy: :head_tail,
        timeout_ms: 30_000
      )

    assert_raise RuntimeError, "forced output-policy failure", fn ->
      try do
        eventually(fn -> pids(ctx.marker) != [] end)
        raise "forced output-policy failure"
      after
        stop_task(task, token)
      end
    end

    refute Process.alive?(task.pid)
    assert pids(ctx.marker) == []
    assert File.dir?(ctx.root)
  end

  test "unknown policy rejects before execution", ctx do
    task = run(ctx, ["touch", "must-not-start"], output_policy: :unknown)
    assert {:error, {:not_started, reason}} = Task.await(task, 5_000)
    assert reason =~ "output_policy"
    refute File.exists?(Path.join(ctx.root, "must-not-start"))
  end

  test "default policy still kills at the cap and reports omitted output", ctx do
    task = run(ctx, ["yes"], max_bytes: 5, timeout_ms: 5_000)
    assert {:ok, result} = Task.await(task, 5_000)
    assert result.termination == :truncated
    assert result.signal == 9
    assert result.bytes_total > 5
    assert result.bytes_sent == 5
    assert byte_size(result.output) == 5
    assert result.output_capped
  end

  test "an older stub rejects head/tail before submitting the command", ctx do
    pid = stub(ctx, false, %{})

    assert {:error, {:not_started, reason}} =
             GenServer.call(pid, {:run, ["unused"], [output_policy: :head_tail]})

    assert reason =~ "does not support"
    refute File.exists?(Path.join(ctx.root, "submitted"))
  end

  test "an older stub still accepts the default policy", ctx do
    pid =
      stub(ctx, false, %{
        "tail" => nil,
        "output_capped" => nil,
        "bytes_total" => 2,
        "bytes_sent" => 2
      })

    assert {:ok, result} = GenServer.call(pid, {:run, ["unused"], []})
    assert result.output == "ab"
    assert result.output_capped == false
  end

  test "a valid head/tail terminal preserves the gap without inventing termination", ctx do
    pid = stub(ctx, true, %{})

    assert {:ok, result} =
             GenServer.call(pid, {:run, ["unused"], [max_bytes: 4, output_policy: :head_tail]})

    assert result.output == "abyz"
    assert result.bytes_total == 10
    assert result.bytes_sent == 4
    assert result.output_capped
    assert result.termination == :exited
  end

  for {label, fields} <- [
        {"missing tail", %{"tail" => nil}},
        {"non-byte tail", %{"tail" => [121, -1]}},
        {"non-list tail", %{"tail" => "yz"}},
        {"oversized tail", %{"tail" => [120, 121, 122]}},
        {"wrong retained count", %{"bytes_sent" => 3}},
        {"wrong total count", %{"bytes_total" => 3}},
        {"missing capped flag", %{"output_capped" => nil}},
        {"false capped flag", %{"output_capped" => false}},
        {"killed at cap", %{"truncated" => true}}
      ] do
    test "head/tail rejects #{label} as uncertain evidence", ctx do
      pid = stub(ctx, true, unquote(Macro.escape(fields)))

      assert {:indeterminate, reason} =
               GenServer.call(pid, {:run, ["unused"], [max_bytes: 4, output_policy: :head_tail]})

      assert reason =~ "inconsistent terminal accounting"
    end
  end

  defp stub(ctx, supports_policy, fields) do
    ready = %{"ev" => "ready", "protocol" => 1, "stub_version" => "fixture"}

    ready =
      if supports_policy,
        do: Map.put(ready, "output_policies", ["truncate", "head_tail"]),
        else: ready

    terminal =
      Map.merge(
        %{
          "ev" => "exit",
          "code" => 0,
          "signal" => nil,
          "cancelled" => false,
          "timed_out" => false,
          "truncated" => false,
          "bytes_total" => 10,
          "bytes_sent" => 4,
          "elapsed_ms" => 1,
          "tail" => [121, 122],
          "output_capped" => true
        },
        fields
      )

    terminal =
      Map.reject(terminal, fn {key, value} ->
        key in ["tail", "output_capped"] and value == nil
      end)

    config = Path.join(ctx.root, "stub.json")
    File.write!(config, JSON.encode!(%{ready: ready, terminal: terminal}))
    binary = Path.join(ctx.root, "stub.py")

    File.write!(binary, """
    \#!#{System.find_executable("python3")}
    import json,os,sys
    config=json.load(open(#{inspect(config)}))
    print(json.dumps(config["ready"]),flush=True)
    for line in sys.stdin:
      request=json.loads(line)
      if request["op"]=="run":
        open(#{inspect(Path.join(ctx.root, "submitted"))},"w").write("submitted")
        for event in [{"ev":"started","pid":os.getpid()},{"ev":"chunk","stream":"combined","bytes":[97,98]},config["terminal"]]:
          print(json.dumps(dict(event,id=request["id"])),flush=True)
    """)

    File.chmod!(binary, 0o700)
    {:ok, pid} = Exec.start_link(name: {:global, {__MODULE__, make_ref()}}, binary: binary)
    Process.unlink(pid)
    Agent.update(ctx.resources, &[{:stub, pid, nil} | &1])
    os_pid = GenServer.call(pid, :status).os_pid

    Agent.update(ctx.resources, fn resources ->
      Enum.map(resources, fn
        {:stub, ^pid, nil} -> {:stub, pid, os_pid}
        other -> other
      end)
    end)

    pid
  end

  defp run(ctx, argv, opts) do
    token = Exec.token()

    task =
      Task.Supervisor.async_nolink(Elara.TaskSup, fn ->
        Exec.run(argv, Keyword.put(opts, :cwd, ctx.root))
      end)

    Agent.update(ctx.resources, &[{:task, task, token} | &1])
    task
  end

  defp stop_task(task, token) do
    ref = Process.monitor(task.pid)
    Process.exit(task.pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    eventually(fn -> Exec.settlement(task.pid, token) == :settled end)
  end

  defp pids(marker) do
    case System.cmd("pgrep", ["-f", marker]) do
      {out, 0} -> String.split(out, "\n", trim: true)
      {_, 1} -> []
    end
  end

  defp eventually(check, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    cond do
      check.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("owned process did not reach its expected state")

      true ->
        Process.sleep(10)
        eventually(check, deadline)
    end
  end
end
