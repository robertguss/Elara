defmodule Elara.Lab.Scenarios.VMRecovery do
  @moduledoc "External VM faults and public disk recovery for declared provider and native mutation inputs."
  @behaviour Elara.Lab
  alias Elara.Lab.{InputObserver, NativeGroup, ProcessProbe, VM}
  alias Elara.Lab.Scenarios.SessionRecovery
  alias Elara.Message.{Assistant, ToolCall, ToolResult, User}
  alias Elara.Session.Store

  @stages ~w(provider_running mutation_running)
  def curve_fields, do: [{"recovery_ms", ["recovery_ms"]}, {"backlog_ms", ["backlog_ms"]}]
  def run(%{provider: :real}), do: raise("vm_recovery uses only its lab provider")

  def run(context) do
    stage = context.params["stage"] || "provider_running"
    unless stage in @stages, do: raise(ArgumentError, "unknown VM stage #{inspect(stage)}")
    config = Map.merge(context, %{stage: stage, schedule: schedule(context.seed)})
    Enum.each(~w(workspace home), &File.mkdir_p!(Path.join(context.dir, &1)))
    VM.write(context.dir, "schedule", config.schedule)

    {:ok, owned} =
      Agent.start_link(fn ->
        %{vms: [], boots: [], native: nil, fault: nil, root: context.dir, stage: stage}
      end)

    try do
      result = attempt(fn -> flow(config, owned) end)
      hook = attempt(fn -> context.hook.({:before_cleanup, Agent.get(owned, & &1)}) end)
      cleanup = cleanup(owned)
      result = if match?({:error, _}, hook), do: hook, else: result
      report(config, result, Agent.get(owned, & &1), cleanup) |> SessionRecovery.finalize()
    after
      if Process.alive?(owned) do
        unless Agent.get(owned, &Map.has_key?(&1, :cleanup)), do: cleanup(owned)
        Agent.stop(owned)
      end
    end
  end

  def schedule(seed) do
    random = :rand.seed_s(:exsss, {seed, 1085, 23})
    {order, random} = :rand.uniform_s(2, random)
    {work, _} = :rand.uniform_s(20, random)
    %{order: if(order == 1, do: ~w(B C), else: ~w(C B)), work_ms: work}
  end

  def normal(label),
    do: %{
      id: "vm-input-#{label}",
      sender_id: "lab",
      kind: :normal,
      user: %User{text: "vm #{label}"},
      terminal_text: "done vm #{label}"
    }

  def expected, do: Map.new(~w(A B C), &{&1, normal(&1)})

  defp flow(config, owned) do
    {source, first} = launch(config, owned, "prepare")
    checkpoint = await!(fn -> VM.read(config.dir, "checkpoint") end, 10_000, :checkpoint)
    source_file = VM.read(config.dir, "source")
    path = source_file["path"]
    {:ok, view} = InputObserver.read(path, expected())
    true = valid_checkpoint?(config, view, path, checkpoint)
    disk_intent = disk_intents(path)
    true = disk_intent == checkpoint["intent"]

    native =
      if config.stage == "mutation_running" do
        native =
          await!(fn -> NativeGroup.before(Path.join(config.dir, "workspace")) end, 1_000, :native)

        guardian = checkpoint["native"]["guardian"]
        {:ok, ^guardian} = ProcessProbe.parent(native.root.pid)
        {:ok, stub} = ProcessProbe.parent(guardian)
        true = stub == first.stub
        [_ | _] = VM.ancestry(stub, first.os_pid)
        Map.merge(native, %{guardian: guardian, stub: stub})
      end

    Agent.update(owned, &Map.put(&1, :native, native))
    target = first.os_pid

    config.hook.(
      {:before_fault,
       %{target: target, vm: first, owner: source, native: native, root: config.dir}}
    )

    Process.sleep(config.schedule.work_ms)

    current = witness(source, first)
    nonce = Elara.Lab.digest({config.seed, :before_fault})
    VM.write(config.dir, "probe", %{nonce: nonce})

    eligible =
      await!(
        fn ->
          case VM.read(config.dir, "eligible") do
            %{"nonce" => ^nonce} = value -> value
            _ -> nil
          end
        end,
        1_000,
        :eligible
      )

    {:ok, before} = InputObserver.read(path, expected())

    true =
      current.os_pid == target and eligible["held"] == true and
        eligible["active_input_id"] == normal("A").id and
        not File.exists?(Path.join(config.dir, "release-provider")) and
        not File.exists?(Path.join([config.dir, "workspace", "release"])) and
        valid_checkpoint?(config, before, path, checkpoint)

    if native do
      now = NativeGroup.before(Path.join(config.dir, "workspace"))
      true = now != nil and now.root.pid == native.root.pid and now.child.pid == native.child.pid
    end

    :ok = VM.kill(source)

    exited =
      await!(
        fn ->
          state = VM.snapshot(source)
          if state.exit_status != nil and state.port_down, do: state
        end,
        5_000,
        :fault_exit
      )

    true = exited.exit_status == 137
    true = await!(fn -> ProcessProbe.stopped?(target) end, 5_000, :fault_stop)

    fault = %{
      exit_status: exited.exit_status,
      port_down: exited.port_down,
      os_pid: target,
      vm_stopped: true,
      witnessed: true
    }

    Agent.update(owned, &Map.put(&1, :fault, fault))

    physical =
      if native do
        await!(
          fn ->
            stopped = NativeGroup.stopped(native)
            if stopped.stopped and stopped.stub_stopped, do: stopped
          end,
          5_000,
          :native_stop
        )
      else
        true = await!(fn -> ProcessProbe.stopped?(first.stub) end, 5_000, :stub_stop)
        %{stopped: true, stub_stopped: true}
      end

    {second, reopened} = launch(config, owned, "recover")
    true = reopened.os_pid != first.os_pid and reopened.boot_id != first.boot_id
    recovery = await!(fn -> VM.read(config.dir, "reopened") end, 5_000, :reopen)
    {:ok, recovered} = InputObserver.read(path, expected())
    true = recovery["recovery_ms"] <= 5_000 and recovered.inputs["A"].state == :failed

    true =
      Enum.all?(~w(B C), fn label ->
        recovered.inputs[label].state == :paused and
          recovery["statuses"][label]["state"] in ["accepted", "queued"]
      end)

    true = recovery["statuses"]["A"]["state"] == "failed"
    File.write!(Path.join(config.dir, "resume"), "resume", [:sync])

    finish =
      await!(
        fn -> VM.read(config.dir, "finished") end,
        5_000 + 2 * config.schedule.work_ms + 500,
        :backlog
      )

    {:ok, final} = InputObserver.read(path, expected())
    true = VM.snapshot(second).port_owned

    %{
      source: first,
      reopened: reopened,
      checkpoint: checkpoint,
      recovered: recovered,
      observation: final,
      native: %{before: native, after: physical},
      recovery_ms: recovery["recovery_ms"],
      backlog_ms: finish["backlog_ms"],
      finish: finish,
      disk_intent: %{before: disk_intent, after: disk_intents(path)},
      mutation: mutation(path),
      launches: launches(config.dir),
      requests: requests(config.dir)
    }
  end

  defp launch(config, owned, mode) do
    boot_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    {:ok, pid} =
      VM.start(config.dir, mode, Elara.Lab.VMRecoveryPeer, [
        config.dir,
        mode,
        config.stage,
        to_string(config.schedule.work_ms),
        boot_id
      ])

    Agent.update(owned, &Map.update!(&1, :vms, fn vms -> [pid | vms] end))
    boot = await!(fn -> VM.read(config.dir, mode <> "-boot") end, 10_000, :boot)
    true = boot["boot_id"] == boot_id
    state = VM.snapshot(pid)
    true = boot["os_pid"] == state.os_pid

    first =
      Map.merge(state, %{
        stub: boot["stub"],
        boot_id: boot_id,
        max_restarts: boot["max_restarts"],
        period: boot["period"]
      })

    Agent.update(owned, &Map.update!(&1, :boots, fn boots -> [first | boots] end))
    true = first.max_restarts == 3 and first.period == 5
    {pid, witness(pid, first)}
  end

  defp witness(pid, boot) do
    state = VM.snapshot(pid)
    true = state.port_owned and state.exit_status == nil
    {:ok, info} = ProcessProbe.info(state.os_pid)
    true = is_map(info) and not String.starts_with?(info.stat, "Z")
    {:ok, parent} = ProcessProbe.parent(state.os_pid)
    ancestors = VM.ancestry(state.os_pid, String.to_integer(System.pid()))
    {:ok, cwd} = ProcessProbe.cwd(state.os_pid)
    {:ok, expected} = File.stat(Path.dirname(state.log))
    {:ok, actual} = File.stat(cwd)
    true = expected.inode == actual.inode and expected.major_device == actual.major_device

    {image, 0} =
      System.cmd("ps", ["-p", to_string(state.os_pid), "-o", "comm="], stderr_to_stdout: true)

    true = String.contains?(image, "beam.smp")

    Map.merge(boot, %{
      port_owned: state.port_owned,
      parent: parent,
      ancestors: ancestors,
      cwd: cwd,
      image: String.trim(image)
    })
  end

  defp valid_checkpoint?(config, view, path, checkpoint) do
    {:ok, store} = Store.open(path)
    declared_command = NativeGroup.command()

    valid =
      Enum.all?(view.checks, fn {_, pass} -> pass end) and
        store.active_input_id == normal("A").id and length(view.inputs["A"].user_entries) == 1 and
        view.inputs["A"].receipt.state == :consumed and not view.inputs["A"].terminal and
        Enum.all?(~w(B C), fn label ->
          input = view.inputs[label]

          input.receipt != nil and input.receipt.state in [:accepted, :queued] and
            input.user_entries == []
        end) and checkpoint["receipt_backend"] == false

    valid and
      case config.stage do
        "provider_running" ->
          checkpoint["intent"] == [] and mutation(path) == nil

        "mutation_running" ->
          match?(
            [
              %{
                "tool_call_id" => "vm-A",
                "tool_name" => "bash",
                "arguments" => %{"command" => command}
              }
            ]
            when command == declared_command,
            checkpoint["intent"]
          ) and
            declared_call?(store) and mutation(path) == nil
      end
  end

  defp declared_call?(store) do
    command = NativeGroup.command()

    calls =
      for %{message: %Assistant{} = assistant} <- store.entries,
          call <- assistant.tool_calls,
          do: call

    match?([%ToolCall{id: "vm-A", name: "bash", args: {:ok, %{"command" => ^command}}}], calls)
  end

  defp mutation(path) do
    {:ok, store} = Store.open(path)

    case for(%{message: %ToolResult{} = result} <- store.entries, do: result) do
      [] ->
        nil

      [%ToolResult{call_id: "vm-A", name: "bash", outcome: {kind, text}}] ->
        %{outcome: kind, text: text}

      _ ->
        %{outcome: :invalid}
    end
  end

  defp launches(root) do
    case File.read(Path.join([root, "workspace", "started"])) do
      {:ok, bytes} -> byte_size(bytes)
      {:error, :enoent} -> 0
      _ -> nil
    end
  end

  defp disk_intents(path) do
    path = Path.rootname(path) <> ".effects.sqlite3"

    if File.exists?(path) do
      {:ok, db} = Exqlite.Sqlite3.open(path, mode: :readonly)

      try do
        {:ok, statement} =
          Exqlite.Sqlite3.prepare(
            db,
            "SELECT job_id, operation_digest, job FROM controller_intents ORDER BY job_id"
          )

        try do
          {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, statement)

          Enum.map(rows, fn [id, digest, bytes] ->
            {:ok, job} = Elara.Effect.Job.decode(bytes)
            true = job.job_id == id and job.operation_digest == digest
            job |> Map.from_struct() |> JSON.encode!() |> JSON.decode!()
          end)
        after
          Exqlite.Sqlite3.release(db, statement)
        end
      after
        Exqlite.Sqlite3.close(db)
      end
    else
      []
    end
  end

  defp requests(root) do
    case File.read(Path.join(root, "requests")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      _ -> []
    end
  end

  defp cleanup(owned) do
    state = Agent.get(owned, & &1)
    vms = Enum.map(state.vms, fn pid -> attempt(fn -> VM.stop(pid) end) end)

    native =
      if state.native,
        do:
          VM.wait(
            fn ->
              stopped = NativeGroup.stopped(state.native)
              if stopped.stopped and stopped.stub_stopped, do: stopped
            end,
            5_000
          ),
        else: %{stopped: state.stage != "mutation_running", stub_stopped: true}

    stubs = Enum.all?(state.boots, &ProcessProbe.stopped?(&1.stub))

    confirmed =
      length(state.boots) == length(state.vms) and stubs and native != nil and native.stopped and
        Enum.all?(vms, &match?({:ok, %{stopped: true}}, &1))

    result = %{confirmed: confirmed, vms: vms, native: native, stubs_stopped: stubs}
    Agent.update(owned, &Map.put(&1, :cleanup, result))
    result
  end

  defp report(config, {:ok, data}, state, cleanup) do
    view = data.observation

    checks =
      Map.merge(view.checks, %{
        fault_witnessed: state.fault != nil and state.fault.witnessed,
        fresh_vm:
          data.source.os_pid != data.reopened.os_pid and
            data.source.boot_id != data.reopened.boot_id,
        recovery_bound: data.recovery_ms <= 5_000,
        backlog_bound: data.backlog_ms <= 5_000 + 2 * config.schedule.work_ms,
        recovered_input_visible:
          data.recovered.inputs["A"].state == :failed and
            Enum.all?(~w(B C), &(data.recovered.inputs[&1].state == :paused)),
        own_input_terminals:
          view.all_terminal and view.inputs["A"].state == :failed and
            Enum.all?(~w(B C), &view.inputs[&1].completed),
        no_request_replay: Enum.sort(data.requests) == ~w(A B C),
        single_physical_launch:
          data.launches == if(config.stage == "mutation_running", do: 1, else: 0),
        mutation_uncertain:
          if(config.stage == "mutation_running",
            do: data.mutation != nil and data.mutation.outcome == :indeterminate,
            else: data.mutation == nil
          ),
        intent_preserved:
          data.checkpoint["intent"] == data.disk_intent.before and
            data.disk_intent.before == data.disk_intent.after,
        native_stopped_before_cleanup:
          data.native.after.stopped and data.native.after.stub_stopped,
        reopened_executor_idle:
          data.finish["exec"]["available"] == true and data.finish["exec"]["jobs"] == 0,
        cleanup_confirmed: cleanup.confirmed
      })

    Map.merge(data, %{
      checks: checks,
      complete: Enum.all?(checks, fn {_, pass} -> pass end),
      error: nil,
      fault: state.fault,
      cleanup: cleanup,
      cleanup_confirmed: cleanup.confirmed,
      choices_digest: Elara.Lab.digest({config.stage, config.schedule}),
      schedule: config.schedule
    })
  end

  defp report(config, {:error, error}, state, cleanup),
    do: %{
      checks: %{
        fault_witnessed: state.fault != nil and state.fault.witnessed,
        cleanup_confirmed: cleanup.confirmed
      },
      complete: false,
      error: error,
      fault: state.fault,
      cleanup: cleanup,
      cleanup_confirmed: cleanup.confirmed,
      schedule: config.schedule,
      choices_digest: Elara.Lab.digest({config.stage, config.schedule})
    }

  defp await!(fun, timeout, label), do: VM.wait(fun, timeout) || throw({:timeout, label})

  defp attempt(fun) do
    try do
      {:ok, fun.()}
    rescue
      error ->
        {:error,
         {:exception, Exception.message(error), Exception.format(:error, error, __STACKTRACE__)}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end
end
