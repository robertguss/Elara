defmodule Elara.WorkerLifecycleTest do
  use ExUnit.Case, async: false

  alias Elara.Executor.{Remote, Request}
  alias Elara.Worker.Server

  setup do
    marker = "elara_worker_lifecycle_#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), marker)
    File.mkdir_p!(root)

    on_exit(fn ->
      for pid <- marker_pids(marker) do
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
      end

      assert_eventually(fn -> marker_pids(marker) == [] end)
      File.rm_rf!(root)
    end)

    %{root: root, marker: marker}
  end

  test "handler death after unlink kills the job and its native process group", context do
    owner = self()

    hook = fn
      :before_socket_monitor, details ->
        send(owner, {:worker_job, self(), details})

      :job_unlinked, details ->
        send(owner, {:job_unlinked, self(), details.job})

        receive do
          :continue_handler -> :ok
        after
          5_000 -> raise "unlink fault was not released"
        end
    end

    worker = start_worker(context.root, hook)
    socket = submit(worker, command(context), "bash")
    assert_receive {:worker_job, handler, %{job: job, guardian: guardian}}, 3_000
    own_process(job)
    own_process(guardian)
    assert_eventually(fn -> length(marker_pids(context.marker)) >= 2 end)
    job_ref = Process.monitor(job)
    handler_ref = Process.monitor(handler)
    guardian_ref = Process.monitor(guardian)

    :ok = :gen_tcp.close(socket)
    assert_receive {:job_unlinked, ^handler, ^job}, 3_000
    assert Process.alive?(job)
    Process.exit(handler, :kill)
    assert_receive {:DOWN, ^handler_ref, :process, ^handler, :killed}, 3_000
    assert_receive {:DOWN, ^job_ref, :process, ^job, :killed}, 3_000
    assert_receive {:DOWN, ^guardian_ref, :process, ^guardian, :normal}, 3_000
    assert_eventually(fn -> marker_pids(context.marker) == [] end)
  end

  test "closed socket at active setup cancels the job and leaves the worker serving",
       context do
    owner = self()

    hook = fn
      :before_socket_monitor, details ->
        send(owner, {:worker_job, self(), details})

        receive do
          :observe_disconnect ->
            # Witness the peer close, then close the passive port explicitly.
            # FIN alone need not make setopts fail on every socket backend.
            closed = :gen_tcp.recv(details.socket, 0, 3_000)
            :ok = :gen_tcp.close(details.socket)
            send(owner, {:disconnect_observed, self(), closed})

          :continue_handler ->
            :ok
        after
          5_000 -> raise "disconnect fault was not released"
        end

      :job_unlinked, _details ->
        :ok
    end

    worker = start_worker(context.root, hook)
    socket = submit(worker, command(context), "bash")
    assert_receive {:worker_job, handler, %{job: job, guardian: guardian}}, 3_000
    own_process(job)
    own_process(guardian)
    assert_eventually(fn -> length(marker_pids(context.marker)) >= 2 end)
    job_ref = Process.monitor(job)
    guardian_ref = Process.monitor(guardian)

    :ok = :gen_tcp.close(socket)
    send(handler, :observe_disconnect)
    assert_receive {:disconnect_observed, ^handler, {:error, :closed}}, 3_000
    assert_receive {:DOWN, ^job_ref, :process, ^job, _reason}, 3_000
    assert_receive {:DOWN, ^guardian_ref, :process, ^guardian, :normal}, 3_000
    assert_eventually(fn -> marker_pids(context.marker) == [] end)
    assert Process.alive?(worker)

    File.write!(Path.join(context.root, "probe"), "still serving")

    reader =
      Task.async(fn ->
        Remote.execute(
          %{port: Server.port(worker), token: "test-token"},
          request("read", %{"path" => "probe"}),
          tool("read")
        )
      end)

    assert_receive {:worker_job, next_handler, %{job: next_job}}, 3_000
    own_process(next_job)
    send(next_handler, :continue_handler)
    assert {:ok, "still serving"} = Task.await(reader, 3_000)
  end

  test "worker death still kills linked jobs, guardians, and the native group", context do
    owner = self()
    hook = fn point, details -> send(owner, {point, self(), details}) end
    worker = start_worker(context.root, hook)
    _socket = submit(worker, command(context), "bash")

    assert_receive {:before_socket_monitor, _handler, %{job: job, guardian: guardian}}, 3_000
    own_process(job)
    own_process(guardian)
    assert_eventually(fn -> length(marker_pids(context.marker)) >= 2 end)
    job_ref = Process.monitor(job)
    guardian_ref = Process.monitor(guardian)

    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^job_ref, :process, ^job, :killed}, 3_000
    assert_receive {:DOWN, ^guardian_ref, :process, ^guardian, :normal}, 3_000
    assert_eventually(fn -> marker_pids(context.marker) == [] end)
  end

  test "a normally completed job retires its guardian and keeps the worker serving", context do
    owner = self()

    hook = fn :before_socket_monitor, details ->
      send(owner, {:worker_job, self(), details})

      receive do
        :continue_handler -> :ok
      after
        5_000 -> raise "completion was not released"
      end
    end

    worker = start_worker(context.root, hook)
    File.write!(Path.join(context.root, "probe"), "completed")

    reader =
      Task.async(fn ->
        Remote.execute(
          %{port: Server.port(worker), token: "test-token"},
          request("read", %{"path" => "probe"}),
          tool("read")
        )
      end)

    assert_receive {:worker_job, handler, %{job: job, guardian: guardian}}, 3_000
    own_process(job)
    own_process(guardian)
    guardian_ref = Process.monitor(guardian)
    send(handler, :continue_handler)

    assert {:ok, "completed"} = Task.await(reader, 3_000)
    assert_receive {:DOWN, ^guardian_ref, :process, ^guardian, _reason}, 3_000
    assert Process.alive?(worker)
  end

  defp start_worker(root, hook) do
    {:ok, worker} =
      Server.start_link(
        token: "test-token",
        capabilities: ["shell", "filesystem:read"],
        workspaces: %{"workspace" => root},
        lifecycle_hook: hook
      )

    Process.unlink(worker)
    own_process(worker)
    worker
  end

  defp own_process(pid) do
    on_exit(fn ->
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 3_000
    end)
  end

  defp submit(worker, command, name) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, Server.port(worker), [
        :binary,
        packet: :line,
        active: false
      ])

    on_exit(fn -> :gen_tcp.close(socket) end)

    line = %{
      "version" => 2,
      "token" => "test-token",
      "request" => Request.to_map(request(name, %{"command" => command}))
    }

    :ok = :gen_tcp.send(socket, Elara.Protocol.encode(line))
    socket
  end

  defp request(name, arguments) do
    tool = tool(name)

    %Request{
      tool_call_id: "lifecycle",
      session_id: "session",
      tool_name: name,
      tool_version: tool.version,
      arguments: arguments,
      workspace_id: "workspace",
      deadline_ms: System.system_time(:millisecond) + 30_000,
      max_output_bytes: 16_384,
      cancellation_id: "cancel",
      required_capabilities: tool.capabilities,
      placement: :remote,
      mutating: tool.mutating
    }
  end

  defp tool(name), do: Enum.find(Elara.Tool.builtins(), &(&1.name == name))

  defp command(context) do
    "bash -c 'exec -a #{context.marker}_child sleep 60' & " <>
      "printf started > #{Path.join(context.root, "started")}; wait"
  end

  defp marker_pids(marker) do
    case System.cmd("pgrep", ["-f", marker], stderr_to_stdout: true) do
      {output, 0} -> String.split(output, "\n", trim: true) |> Enum.map(&String.to_integer/1)
      {_output, 1} -> []
    end
  end

  defp assert_eventually(condition) do
    deadline = System.monotonic_time(:millisecond) + 3_000
    wait(condition, deadline)
  end

  defp wait(condition, deadline) do
    cond do
      condition.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not reached")

      true ->
        Process.sleep(10)
        wait(condition, deadline)
    end
  end
end
