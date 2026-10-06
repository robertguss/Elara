defmodule Elara.Lab.Scenarios.GroupRecovery do
  @moduledoc "Public Exec fault preparations for an ordinary shell-owned process group."
  @behaviour Elara.Lab

  alias Elara.Lab.{Gate, Jobs, ProcessProbe}
  alias Elara.Lab.Scenarios.SessionRecovery
  alias Elara.Lab.Scenarios.SessionRecovery.{Coordinator, Deadline}

  @stages ~w(owner_running executor_running stub_running)
  @owner {__MODULE__, :owner}
  @recovery_ms 5_000

  @impl true
  def run(context) do
    stage = context.params["stage"] || "owner_running"
    unless stage in @stages, do: raise(ArgumentError, "unknown group stage #{inspect(stage)}")
    cwd = Path.join(context.dir, "workspace")
    File.mkdir_p!(cwd)
    {:ok, co} = Coordinator.start_link([])
    {:ok, gate} = Gate.start_link()
    Process.unlink(gate)
    config = %{cwd: cwd, co: co, gate: gate, schedule: schedule(context.seed, stage)}

    try do
      result = attempt(fn -> flow(context, config) end)
      events = Gate.snapshot(gate)
      evidence = Coordinator.evidence(co)
      physical = call(config, :final_native, 1_000, fn -> stopped(event(events, :native)) end)
      hook = attempt(fn -> context.hook.({:before_cleanup, %{owner: owner_pid()}}) end)
      cleanup = cleanup(config)

      report(config, result, hook, events, evidence, physical, cleanup)
      |> SessionRecovery.finalize()
    after
      if Process.alive?(co), do: cleanup(config)
      Process.delete(@owner)
    end
  end

  defp schedule(seed, stage) do
    {delay, _} = :rand.uniform_s(20, :rand.seed_s(:exsss, {seed + 1, seed + 2, seed + 3}))
    %{stage: stage, fault_delay_ms: delay, command_ms: 60_000}
  end

  defp flow(context, config) do
    setup = Jobs.now() + 10_000
    %{available: true, jobs: 0} = call!(config, :baseline, setup, &Elara.Exec.status/0)

    task =
      Task.Supervisor.async_nolink(Elara.TaskSup, fn ->
        :ok = Gate.hold(config.gate, :command_ready)
        :ok = Gate.observe(config.gate, :command_admitted)

        Elara.Exec.run(["sh", "-c", command()],
          cwd: config.cwd,
          timeout_ms: 60_000,
          max_bytes: 1_024
        )
      end)

    Process.put(@owner, task)

    poll!(config, :command_ready, setup, fn ->
      if event(Gate.snapshot(config.gate), :command_ready), do: true
    end)

    :ok = Gate.release(config.gate, :command_ready)

    native = poll!(config, :native_ownership, setup, fn -> native_before(config.cwd) end)
    epoch = call!(config, :native_epoch, setup, fn -> epoch_before(native) end)
    native = Map.merge(native, %{guardian: epoch.guardian, stub: epoch.os_pid})
    :ok = Gate.note(config.gate, :native, native)
    :ok = Gate.note(config.gate, :epoch, epoch)

    target =
      case config.schedule.stage do
        "owner_running" -> task.pid
        "executor_running" -> epoch.pid
        "stub_running" -> epoch.port
      end

    kind = if is_port(target), do: :port, else: :process
    ref = :erlang.monitor(kind, target)
    installed = Jobs.now()

    try do
      :ok =
        if kind == :port,
          do: Coordinator.observe_port(config.co, target),
          else: Coordinator.observe_target(config.co, target)

      context.hook.({:before_fault, %{owner: task.pid, target: target, native: native}})
      Process.sleep(config.schedule.fault_delay_ms)

      eligible =
        call!(config, :eligibility, setup, fn ->
          current = native_before(config.cwd)

          Process.alive?(task.pid) and current != nil and
            current.root.pid == native.root.pid and current.child.pid == native.child.pid and
            current.root.pgid == native.root.pgid and
            epoch_before(current) == epoch
        end)

      unless eligible, do: throw(:ineligible_group_fault)

      :ok =
        Gate.note(config.gate, :checkpoint, %{target: target, kind: kind, installed: installed})

      :ok = Gate.note(config.gate, :injected, %{target: target, ref: ref, kind: kind})

      if kind == :port do
        {_, 0} =
          System.cmd("kill", ["-KILL", Integer.to_string(epoch.os_pid)], stderr_to_stdout: true)

        :ok = Gate.note(config.gate, :native_kill, %{pid: epoch.os_pid})
      else
        Process.exit(target, :kill)
      end

      receive do
        {:DOWN, ^ref, ^kind, ^target, reason} ->
          :ok =
            Gate.note(config.gate, :target_down, %{
              target: target,
              ref: ref,
              kind: kind,
              reason: reason
            })
      after
        @recovery_ms -> throw(:missing_group_target_down)
      end

      {:ok, _} = Coordinator.await_down(config.co, 1_000)
      down = event(Gate.snapshot(config.gate), :target_down)
      deadline = down.at + @recovery_ms

      poll!(config, :group_recovery, deadline, fn ->
        physical = stopped(%{details: native})
        status = Elara.Exec.status()

        if physical.stopped and not Process.alive?(task.pid) and status.available and
             status.jobs == 0,
           do: %{
             physical: physical,
             status: status,
             pid: Process.whereis(Elara.Exec),
             token: Elara.Exec.token(),
             settlement: Elara.Exec.settlement(task.pid, epoch.token)
           }
      end)
      |> then(&Gate.note(config.gate, :recovered, &1))

      :ok = Gate.note(config.gate, :owner_outcome, await_owner(task, deadline))
      :ok
    after
      :erlang.demonitor(ref, [:flush])
    end
  end

  defp command do
    """
    printf '%s' "$$" > os_pid
    sleep 60 &
    printf '%s' "$!" > descendant_pid
    printf x >> started
    while [ ! -e release ]; do sleep 0.01; done
    """
  end

  defp native_before(cwd) do
    with {:ok, root_pid} <- read_pid(cwd, "os_pid"),
         {:ok, child_pid} <- read_pid(cwd, "descendant_pid"),
         {:ok, root} when is_map(root) <- ProcessProbe.info(root_pid),
         {:ok, child} when is_map(child) <- ProcessProbe.info(child_pid),
         false <- String.starts_with?(root.stat, "Z") or String.starts_with?(child.stat, "Z"),
         {:ok, parent} <- ProcessProbe.parent(child.pid),
         true <- parent == root.pid and child.pgid == root.pgid,
         {:ok, controller} when is_map(controller) <- ProcessProbe.info(System.pid()),
         true <- root.pgid != controller.pgid,
         {:ok, root_cwd} <- ProcessProbe.cwd(root.pid),
         {:ok, child_cwd} <- ProcessProbe.cwd(child.pid),
         true <- same_directory?(cwd, root_cwd) and same_directory?(cwd, child_cwd),
         {:ok, members} <- ProcessProbe.group(root.pgid),
         true <-
           Enum.all?([root.pid, child.pid], fn pid -> Enum.any?(members, &(&1.pid == pid)) end),
         {:ok, "x"} <- File.read(Path.join(cwd, "started")) do
      %{
        root: Map.put(root, :cwd, root_cwd),
        child: Map.merge(child, %{parent: parent, cwd: child_cwd}),
        controller_pgid: controller.pgid,
        members: members,
        owned: true
      }
    else
      _ -> nil
    end
  end

  defp epoch_before(native) do
    pid = Process.whereis(Elara.Exec)
    status = Elara.Exec.status()
    token = Elara.Exec.token()
    {:links, links} = Process.info(pid, :links)
    port = Enum.find(links, &(is_port(&1) and Port.info(&1, :os_pid) == {:os_pid, status.os_pid}))
    {:ok, guardian} = ProcessProbe.parent(native.root.pid)
    {:ok, stub} = ProcessProbe.parent(guardian)
    {:ok, guardian_info} = ProcessProbe.info(guardian)

    unless status.available and status.jobs == 1 and is_port(port) and
             Port.info(port, :connected) == {:connected, pid} and stub == status.os_pid and
             is_map(guardian_info) and not String.starts_with?(guardian_info.stat, "Z"),
           do: throw(:unwitnessed_group_epoch)

    %{pid: pid, port: port, os_pid: status.os_pid, token: token, guardian: guardian}
  end

  defp stopped(%{details: native}) do
    with {:ok, members} <- ProcessProbe.group(native.root.pgid),
         {:ok, root} <- ProcessProbe.info(native.root.pid),
         {:ok, child} <- ProcessProbe.info(native.child.pid) do
      guardian = ProcessProbe.stopped?(native.guardian)

      %{
        stopped:
          Enum.all?(members, &String.starts_with?(&1.stat, "Z")) and
            dead_row?(root) and dead_row?(child) and guardian,
        root: root,
        child: child,
        members: members,
        guardian_stopped: guardian,
        stub_stopped: ProcessProbe.stopped?(native.stub)
      }
    else
      error -> %{stopped: false, error: error}
    end
  end

  defp stopped(_), do: %{stopped: false, error: :missing_native_witness}
  defp dead_row?(nil), do: true
  defp dead_row?(%{stat: stat}), do: String.starts_with?(stat, "Z")

  defp cleanup(config) do
    events = if Process.alive?(config.gate), do: Gate.snapshot(config.gate), else: []
    gates = if Process.alive?(config.gate), do: Gate.stop(config.gate), else: false
    task = Process.get(@owner)
    if task, do: Task.shutdown(task, :brutal_kill)
    if task, do: call(config, :cleanup_cancel, 1_000, fn -> Elara.Exec.cancel(task.pid) end)
    File.write(Path.join(config.cwd, "release"), "released")
    native = event(events, :native)
    admitted = event(events, :command_admitted) != nil

    settlement =
      call(config, :cleanup_group, @recovery_ms, fn ->
        cleanup_until(task, native, admitted, Jobs.now() + @recovery_ms - 100)
      end)

    state = Coordinator.snapshot(config.co)
    helpers = if is_map(state), do: state.helpers, else: []
    settled_helpers = helpers |> Enum.map(&stop_helper/1) |> Enum.all?()
    Coordinator.stop(config.co)

    %{
      confirmed:
        gates and settlement == {:ok, true} and is_map(state) and
          state.unresolved == [] and settled_helpers and not Process.alive?(config.co),
      gates_settled: gates,
      native_settlement: settlement,
      helpers_settled: settled_helpers,
      coordinator_settled: not Process.alive?(config.co)
    }
  end

  defp cleanup_until(task, native, admitted, deadline) do
    physical = if native, do: stopped(native).stopped, else: not admitted
    owner_dead = task == nil or not Process.alive?(task.pid)
    status = Elara.Exec.status()

    cond do
      physical and owner_dead and status.available and status.jobs == 0 ->
        true

      Jobs.now() >= deadline ->
        false

      true ->
        Process.sleep(10)
        cleanup_until(task, native, admitted, deadline)
    end
  end

  defp stop_helper(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> true
    after
      1_000 ->
        Process.demonitor(ref, [:flush])
        false
    end
  end

  defp report(config, result, hook, events, evidence, physical, cleanup) do
    injection = event(events, :injected)
    checkpoint = event(events, :checkpoint)
    down = event(events, :target_down)
    epoch = event(events, :epoch)
    recovered = event(events, :recovered)
    native = event(events, :native)

    after_native =
      case physical do
        {:ok, value} -> value
        error -> %{stopped: false, error: error}
      end

    launches =
      case File.read(Path.join(config.cwd, "started")) do
        {:ok, bytes} -> byte_size(bytes)
        _ -> nil
      end

    fault =
      checkpoint != nil and injection != nil and checkpoint.at <= injection.at and
        checkpoint.details.target == injection.details.target and
        checkpoint.details.installed <= injection.at and
        Enum.count(events, &(&1.point == :injected)) == 1

    death =
      fault and down != nil and evidence.death.matched and down.at >= injection.at and
        evidence.death.at >= injection.at and
        evidence.ordering.monitor_installed_at <= injection.at and
        down.details.ref == injection.details.ref and
        down.details.target == injection.details.target and
        evidence.death.target == inspect(injection.details.target) and
        down.details.reason == evidence.death.reason and
        (injection.details.kind == :port or down.details.reason == :killed)

    same_epoch = config.schedule.stage == "owner_running"

    epoch_ok =
      epoch != nil and recovered != nil and
        if same_epoch,
          do:
            recovered.details.pid == epoch.details.pid and
              recovered.details.token == epoch.details.token,
          else:
            recovered.details.token != epoch.details.token and
              recovered.details.status.os_pid != epoch.details.os_pid and
              if(config.schedule.stage == "stub_running",
                do:
                  recovered.details.pid == epoch.details.pid and
                    recovered.details.token["incarnation"] == epoch.details.token["incarnation"] and
                    recovered.details.token["generation"] > epoch.details.token["generation"],
                else:
                  recovered.details.pid != epoch.details.pid and
                    recovered.details.token["incarnation"] != epoch.details.token["incarnation"]
              )

    recovery_ms = if down && recovered, do: recovered.at - down.at

    checks = %{
      fault_witnessed: fault,
      target_down_witnessed: death,
      ordinary_child_owned: native != nil and native.details.owned,
      launch_once: launches == 1,
      native_stopped_before_cleanup: after_native.stopped,
      epoch_interpreted: epoch_ok,
      settlement_interpreted:
        recovered != nil and
          recovered.details.settlement ==
            if(same_epoch, do: :settled, else: :unknown),
      owner_terminal: owner_terminal?(config.schedule.stage, event(events, :owner_outcome)),
      executor_idle: recovered != nil and recovered.details.status.jobs == 0,
      recovery_bounded: is_integer(recovery_ms) and recovery_ms <= @recovery_ms
    }

    checks =
      if config.schedule.stage == "stub_running",
        do:
          Map.put(
            checks,
            :old_stub_stopped,
            event(events, :native_kill) != nil and epoch != nil and
              event(events, :native_kill).details.pid == epoch.details.os_pid and
              after_native[:stub_stopped] == true
          ),
        else: checks

    %{
      checks: checks,
      complete:
        result == {:ok, :ok} and fault and death and cleanup.confirmed and
          hook == {:ok, :ok},
      error: if(result == {:ok, :ok}, do: nil, else: result),
      schedule: config.schedule,
      choices_digest: Elara.Lab.digest(config.schedule),
      ordering: events,
      death: evidence.death,
      launches: launches,
      native: %{before: native && native.details, after: after_native},
      epoch: %{before: epoch && epoch.details, after: recovered && recovered.details},
      recovery_ms: recovery_ms,
      bounds: %{recovery_ms: @recovery_ms},
      cleanup: cleanup,
      cleanup_confirmed: cleanup.confirmed
    }
  end

  defp await_owner(%Task{ref: ref, pid: pid}, deadline) do
    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        %{result: result}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        %{down: reason}
    after
      max(deadline - Jobs.now(), 0) -> throw(:missing_owner_terminal)
    end
  end

  defp owner_terminal?("owner_running", %{details: %{down: :killed}}), do: true

  defp owner_terminal?("executor_running", %{
         details: %{down: {:killed, {GenServer, :call, [Elara.Exec, {:run, _, _}, :infinity]}}}
       }),
       do: true

  defp owner_terminal?("stub_running", %{details: %{result: {:indeterminate, message}}}),
    do: is_binary(message)

  defp owner_terminal?(_, _), do: false

  defp read_pid(cwd, name) do
    with {:ok, text} <- File.read(Path.join(cwd, name)),
         {pid, ""} when pid > 0 <- Integer.parse(text),
         do: {:ok, pid},
         else: (_ -> :error)
  end

  defp same_directory?(expected, actual) do
    with {:ok, a} <- File.stat(expected),
         {:ok, b} <- File.stat(actual),
         do: a.inode == b.inode and a.major_device == b.major_device,
         else: (_ -> false)
  end

  defp owner_pid do
    case Process.get(@owner) do
      nil -> nil
      task -> task.pid
    end
  end

  defp event(events, point), do: Enum.find(events, &(&1.point == point))

  defp attempt(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp call(config, op, timeout, fun), do: Deadline.call(config.co, op, Jobs.now() + timeout, fun)

  defp call!(config, op, deadline, fun) do
    case Deadline.call(config.co, op, deadline, fun) do
      {:ok, value} -> value
      error -> throw({op, error})
    end
  end

  defp poll!(config, op, deadline, fun) do
    case call!(config, op, deadline, fun) do
      value when value != nil and value != false ->
        value

      _ ->
        if Jobs.now() >= deadline,
          do: throw({:timeout, op}),
          else:
            (
              Process.sleep(10)
              poll!(config, op, deadline, fun)
            )
    end
  end
end
