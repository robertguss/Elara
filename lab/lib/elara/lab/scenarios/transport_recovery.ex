defmodule Elara.Lab.Scenarios.TransportRecovery do
  @moduledoc "Persisted input and mutation intent through actual loopback client/worker faults."
  @behaviour Elara.Lab
  alias Elara.Lab.{Gate, InputObserver, Jobs, NativeGroup}
  alias Elara.Lab.Scenarios.SessionRecovery
  alias Elara.Lab.Scenarios.SessionRecovery.{Coordinator, Deadline}
  alias Elara.Effect.{ControllerJournal, Executor, ExecutorLedger, LocalExecutor}
  alias Elara.Executor.{Remote, Request, Router}
  alias Elara.Message.{Assistant, ToolCall, ToolResult, User}
  alias Elara.Session.{Handoff, Store}
  alias Elara.Worker.Server

  @stages ~w(client_running handler_running worker_running)
  @workspace "transport-fixture"
  @token "disposable-lab-loopback-token"
  @recovery_ms 5_000
  def curve_fields, do: [{"recovery_ms", ["recovery_ms"]}, {"backlog_ms", ["backlog_ms"]}]

  defp backlog_limit(config), do: @recovery_ms + 2 * config.schedule.work_ms

  def run(%{provider: :real}), do: raise("transport_recovery uses only its lab provider")

  def run(context) do
    stage = context.params["stage"] || "client_running"
    unless stage in @stages, do: raise(ArgumentError, "unknown transport stage #{inspect(stage)}")
    brain = Path.join(context.dir, "brain")
    worker = Path.join(context.dir, "worker")
    Enum.each([brain, worker], &File.mkdir_p!/1)
    {:ok, co} = Coordinator.start_link([])
    {:ok, gate} = Gate.start_link()
    Process.unlink(gate)

    config = %{
      co: co,
      gate: gate,
      brain: brain,
      cwd: worker,
      receipt_backend?: context.params["receipt_backend"] == "true",
      schedule: schedule(context.seed, stage)
    }

    log = Elara.Lab.choice_log()

    try do
      result = attempt(fn -> flow(context, config) end)
      events = Gate.snapshot(gate)
      evidence = Coordinator.evidence(co)
      view = call(config, :final_view, 1_000, fn -> observation(events) end)

      physical =
        call(config, :final_native, 1_000, fn -> NativeGroup.stopped(details(events, :native)) end)

      hook = attempt(fn -> context.hook.({:before_cleanup, %{gate: gate}}) end)
      cleanup = cleanup(config, log)

      report(config, result, hook, events, evidence, view, physical, cleanup)
      |> SessionRecovery.finalize()
    after
      if Process.alive?(co), do: cleanup(config, log)
    end
  end

  defp schedule(seed, stage) do
    random = :rand.seed_s(:exsss, {seed, 1085, 19})
    {order, random} = :rand.uniform_s(2, random)
    {work, _} = :rand.uniform_s(20, random)
    %{stage: stage, order: if(order == 1, do: ["B", "C"], else: ["C", "B"]), work_ms: work}
  end

  defp flow(context, config) do
    deadline = Jobs.now() + 10_000
    %{available: true, jobs: 0} = call!(config, :baseline, deadline, &Elara.Exec.status/0)
    worker = start_worker(config, deadline)

    router =
      call!(config, :router, deadline, fn ->
        {:ok, router} = Router.start_link()
        :ok = Coordinator.track(config.co, :worker, router)
        Gate.note(config.gate, :router, %{pid: router})
        router
      end)

    register(config, router, worker, deadline)

    executor =
      if config.receipt_backend? do
        call!(config, :effect_executor, deadline, fn ->
          {:ok, name} = LocalExecutor.open(config.brain, @workspace)
          Gate.note(config.gate, :effect_executor, %{name: name, pid: GenServer.whereis(name)})
          name
        end)
      end

    source =
      call!(config, :start, deadline, fn ->
        {:ok, id} =
          Elara.start_session(
            cwd: config.brain,
            home: config.brain,
            skill_paths: [],
            plugins: [],
            provider: {Elara.Lab.TransportProvider, config},
            tools: [tool("bash")],
            router: router,
            effect_executor: executor,
            workspace_id: @workspace,
            max_iterations: 3,
            context_limit: 100_000,
            tool_timeout_ms: 60_000,
            max_tool_output_bytes: 1_024
          )

        :ok = Coordinator.transfer_session(config.co, :start, id)
        {:ok, store} = Handoff.store(id)
        pid = Elara.session_pid(id) |> elem(1)
        Gate.note(config.gate, :source, %{id: id, pid: pid, path: store.path})
        id
      end)

    :ok = Gate.subscribe(config.gate, source)
    call!(config, :submit, deadline, fn -> Elara.submit_input(source, normal("A")) end)

    point =
      poll!(config, :handler_running, deadline, fn ->
        event(Gate.snapshot(config.gate), :handler_running)
      end)

    native = poll!(config, :native, deadline, fn -> NativeGroup.before(config.cwd) end)
    epoch = call!(config, :native_epoch, deadline, fn -> NativeGroup.epoch(native) end)
    native = Map.merge(native, %{guardian: epoch.guardian, stub: epoch.os_pid})
    Gate.note(config.gate, :native, native)
    Gate.note(config.gate, :native_epoch, epoch)

    source_info = details(Gate.snapshot(config.gate), :source)

    network =
      call!(config, :network_owner, deadline, fn ->
        network(point.details.socket, source_info.pid, config.receipt_backend?)
      end)

    Gate.note(config.gate, :network, network)

    for label <- config.schedule.order do
      call!(config, :submit, deadline, fn -> Elara.submit_input(source, normal(label)) end)
    end

    checkpoint =
      poll!(config, :checkpoint, deadline, fn ->
        with {:ok, view} <- InputObserver.read(source_info.path, expected()),
             true <- valid_inputs?(view),
             true <-
               Enum.all?(
                 ~w(B C),
                 &(view.inputs[&1].receipt != nil and
                     view.inputs[&1].receipt.state in [:queued, :accepted] and
                     view.inputs[&1].user_entries == [])
               ),
             {:ok, store} <- Store.open(source_info.path),
             true <- store.active_input_id == normal("A").id,
             true <- declared_call?(store),
             true <- mutation(store) == nil do
          shell = :sys.get_state(source_info.pid, 1_000)
          {:ok, [job]} = ControllerJournal.all(shell.effect_journal)
          {:ok, _intent} = ControllerJournal.get(shell.effect_journal, job.job_id)

          unless shell.effect_executor == executor and
                   shell.effect_executor_explicit? == config.receipt_backend? and
                   shell.router == router and
                   job.tool_call_id == "transport-A" and
                   job.tool_name == "bash" and job.workspace_id == @workspace and
                   job.arguments == %{"command" => NativeGroup.command()},
                 do: throw(:wrong_transport_effect)

          {:monitors, monitors} = Process.info(Process.whereis(Elara.Exec), :monitors)
          router_state = :sys.get_state(router, 1_000)

          unless {:process, point.details.job} in monitors and
                   Map.has_key?(router_state.checkouts, network.owner),
                 do: throw(:wrong_transport_native_owner)

          receipt = if config.receipt_backend?, do: receipt(config, job.job_id)

          if config.receipt_backend? and
               not match?(
                 {:ok,
                  %ExecutorLedger.Record{
                    state: :accepted,
                    admission_count: 1,
                    callback_attempt_count: 1,
                    terminal_count: 0
                  }},
                 receipt
               ),
             do: throw(:missing_attempted_receipt)

          %{
            job: Map.from_struct(job),
            receipt: receipt,
            journal: shell.effect_journal,
            active: store.active_input_id,
            view: view,
            network: network,
            source: source_info,
            worker: worker,
            handler: point.caller,
            worker_job: point.details.job,
            tcp_guardian: point.details.guardian,
            router: router,
            exec_monitors: monitors
          }
        else
          _ -> nil
        end
      end)

    Gate.note(config.gate, :checkpoint, checkpoint)

    target =
      case config.schedule.stage do
        "client_running" -> network.owner
        "handler_running" -> point.caller
        "worker_running" -> worker
      end

    :ok = Coordinator.observe_target(config.co, target)
    ref = Process.monitor(target)

    try do
      context.hook.(
        {:before_fault,
         %{
           gate: config.gate,
           target: target,
           source: source_info.pid,
           worker: worker,
           client: network.owner,
           handler: point.caller,
           job: point.details.job,
           guardian: point.details.guardian,
           native: native,
           executor: executor,
           writer: network.writer
         }}
      )

      Process.sleep(config.schedule.work_ms)

      eligible =
        call!(config, :eligible, deadline, fn ->
          latest = event(Gate.snapshot(config.gate), :handler_running)
          current = NativeGroup.before(config.cwd)
          current_net = network(point.details.socket, source_info.pid, config.receipt_backend?)

          latest != nil and latest.released_at == nil and Process.alive?(target) and
            Enum.all?(
              [point.caller, point.details.job, point.details.guardian, worker, network.owner],
              &Process.alive?/1
            ) and
            current != nil and current.root.pid == native.root.pid and
            current.child.pid == native.child.pid and
            NativeGroup.epoch(current) == epoch and current_net == network
        end)

      unless eligible, do: throw(:ineligible_transport_fault)
      Gate.note(config.gate, :eligible, %{target: target})
      Gate.note(config.gate, :injected, %{target: target, ref: ref})
      Process.exit(target, :kill)

      receive do
        {:DOWN, ^ref, :process, ^target, reason} ->
          Gate.note(config.gate, :target_down, %{target: target, ref: ref, reason: reason})
      after
        @recovery_ms -> throw(:missing_transport_target_down)
      end

      {:ok, _} = Coordinator.await_down(config.co, 1_000)
      if Process.alive?(point.caller), do: Gate.release(config.gate, :handler_running)
    after
      Process.demonitor(ref, [:flush])
    end

    down = event(Gate.snapshot(config.gate), :target_down)
    recovery_deadline = down.at + @recovery_ms

    recovered =
      poll!(config, :recovered, recovery_deadline, fn ->
        with {:ok, view} <- InputObserver.read(source_info.path, expected()),
             true <- valid_inputs?(view) and view.inputs["A"].completed,
             true <-
               Enum.all?(view.inputs, fn {_, input} ->
                 input.terminal or input.state == :paused or
                   (input.receipt != nil and input.receipt.state in [:queued, :accepted])
               end),
             {:ok, store} <- Store.open(source_info.path),
             %{outcome: :indeterminate} = outcome <- mutation(store),
             true <- NativeGroup.stopped(native).stopped,
             true <-
               Enum.all?(
                 [point.caller, point.details.job, point.details.guardian],
                 &(not Process.alive?(&1))
               ),
             %{available: true, jobs: 0} <- Elara.Exec.status() do
          %{
            observation: view,
            mutation: outcome,
            settlement: Elara.Exec.settlement(point.details.job, epoch.token)
          }
        else
          _ -> nil
        end
      end)

    Gate.note(config.gate, :recovered, recovered)

    final =
      poll!(config, :inputs_settled, down.at + backlog_limit(config), fn ->
        case InputObserver.read(source_info.path, expected()) do
          {:ok, %{all_completed: true} = view} -> view
          _ -> nil
        end
      end)

    Gate.note(config.gate, :settled, final)

    intent =
      call!(config, :intent_after, down.at + backlog_limit(config), fn ->
        {:ok, [job]} = ControllerJournal.all(checkpoint.journal)
        Map.from_struct(job)
      end)

    unless intent == checkpoint.job, do: throw(:changed_transport_intent)
    Gate.note(config.gate, :intent_after, intent)

    if config.receipt_backend? do
      {:indeterminate, record} =
        call!(config, :effect_after, down.at + backlog_limit(config), fn ->
          Executor.query(executor, checkpoint.job.job_id)
        end)

      {:ok, before} = checkpoint.receipt

      unless record.job_id == before.job_id and
               record.operation_digest == before.operation_digest and
               record.executor_id == before.executor_id and
               record.admission_count == 1 and record.callback_attempt_count == 1 and
               record.terminal_count == 1 and match?({:indeterminate, _}, record.result) and
               GenServer.whereis(executor) == checkpoint.network.writer and
               Process.alive?(checkpoint.network.writer),
             do: throw(:wrong_uncertain_receipt)

      {:ok, ^record} = receipt(config, record.job_id)

      Gate.note(config.gate, :effect_after, %{
        record: Map.from_struct(record),
        writer: checkpoint.network.writer
      })

      replay =
        call!(config, :receipt_no_replay, down.at + backlog_limit(config), fn ->
          operation = fn ->
            File.write!(Path.join(config.cwd, "replayed"), "unsafe replay")
            {:ok, "replayed"}
          end

          submitted = Executor.submit(executor, record.job_id, record.operation_digest, operation)

          continued =
            Executor.continue(executor, record.job_id, record.operation_digest, operation)

          %{
            same_terminal: submitted == {:indeterminate, record},
            continue_rejected: continued == {:error, :already_terminal},
            marker_absent: not File.exists?(Path.join(config.cwd, "replayed"))
          }
        end)

      Gate.note(config.gate, :receipt_no_replay, replay)
    end

    serving_worker =
      if Process.alive?(worker),
        do: worker,
        else: start_worker(config, down.at + backlog_limit(config))

    register(config, router, serving_worker, down.at + backlog_limit(config))
    File.write!(Path.join(config.cwd, "probe"), "serving")

    probe =
      call!(config, :worker_probe, down.at + backlog_limit(config), fn ->
        Remote.execute(
          %{port: Server.port(serving_worker), token: @token},
          request("read", %{"path" => "probe"}),
          tool("read")
        )
      end)

    Gate.note(config.gate, :worker_probe, %{
      result: probe,
      pid: serving_worker,
      alive: Process.alive?(serving_worker),
      replaced: serving_worker != worker
    })

    :ok
  end

  defp start_worker(config, deadline) do
    call!(config, :start_worker, deadline, fn ->
      {:ok, worker} =
        Server.start_link(
          token: @token,
          capabilities: ["shell", "filesystem:read"],
          workspaces: %{@workspace => config.cwd},
          lifecycle_hook: fn
            :before_socket_monitor, details ->
              :ok = Gate.observe(config.gate, :worker_handler, details)

              case Gate.hold(config.gate, :handler_running, details) do
                :ok -> :ok
                :skip -> :ok
              end

            :job_unlinked, details ->
              Gate.note(config.gate, :job_unlinked, details)
          end
        )

      :ok = Coordinator.track(config.co, :worker, worker)
      Gate.note(config.gate, :worker, %{pid: worker})
      worker
    end)
  end

  defp register(config, router, worker, deadline) do
    call!(config, :register, deadline, fn ->
      Router.register(router,
        id: "lab-worker",
        executor: {Remote, %{port: Server.port(worker), token: @token}},
        capabilities: Server.capabilities(worker),
        workspaces: [@workspace]
      )
    end)
  end

  defp network(socket, source, receipt_backend?) do
    {:ok, local} = :inet.sockname(socket)
    {:ok, peer} = :inet.peername(socket)

    counterparts =
      for port <- :erlang.ports(),
          Port.info(port, :name) == {:name, ~c"tcp_inet"},
          :inet.sockname(port) == {:ok, peer},
          :inet.peername(port) == {:ok, local},
          do: port

    [client] = counterparts
    {:connected, owner} = Port.info(client, :connected)

    shell = :sys.get_state(source, 1_000)
    {:monitors, monitors} = Process.info(source, :monitors)

    owned =
      Enum.any?(shell.tasks, fn
        {_ref, {:tool, _core_ref, ^owner, _lease}} -> true
        _ -> false
      end)

    writer = if receipt_backend?, do: GenServer.whereis(shell.effect_executor)

    links =
      case Process.info(owner, :links) do
        {:links, links} -> links
        _ -> []
      end

    valid_owner =
      if receipt_backend?,
        do:
          shell.effect_executor_explicit? and is_pid(writer) and writer != owner and
            writer in links and Registry.keys(Elara.EffectExecutors, writer) != [],
        else:
          owned and {:process, owner} in monitors and shell.effect_executor == nil and
            not shell.effect_executor_explicit?

    unless is_pid(owner) and valid_owner, do: throw(:wrong_tcp_client_owner)

    %{
      socket: client,
      owner: owner,
      local: peer,
      peer: local,
      server_socket: socket,
      writer: writer,
      callback_linked_to_writer: writer in links,
      source_tool_owned: owned,
      source_monitored: {:process, owner} in monitors
    }
  end

  def normal(label),
    do: %{
      id: "transport-input-#{label}",
      sender_id: "lab",
      kind: :normal,
      user: %User{text: "transport #{label}"},
      terminal_text: "done transport #{label}"
    }

  defp expected, do: Map.new(~w(A B C), &{&1, normal(&1)})
  defp valid_inputs?(view), do: Enum.all?(view.checks, fn {_, ok} -> ok end)

  defp tool(name),
    do: Elara.Tool.builtins() |> Enum.find(&(&1.name == name)) |> Map.put(:placement, :remote)

  defp request(name, arguments) do
    tool = tool(name)

    %Request{
      tool_call_id: "independent-probe",
      session_id: "probe",
      tool_name: name,
      tool_version: tool.version,
      arguments: arguments,
      workspace_id: @workspace,
      deadline_ms: System.system_time(:millisecond) + 1_000,
      max_output_bytes: 1_024,
      cancellation_id: "probe",
      required_capabilities: tool.capabilities,
      placement: :remote,
      mutating: tool.mutating
    }
  end

  defp mutation(store) do
    results =
      for %Store.Entry{message: %ToolResult{} = result} <- store.entries, do: result

    case results do
      [%ToolResult{call_id: "transport-A", name: "bash", outcome: {kind, text}}] ->
        if declared_call?(store), do: %{outcome: kind, text: text}, else: %{outcome: :invalid}

      [] ->
        nil

      other ->
        %{outcome: :invalid, results: other}
    end
  end

  defp declared_call?(store) do
    calls =
      for %Store.Entry{message: %Assistant{tool_calls: calls}} <- store.entries,
          call <- calls,
          do: call

    case calls do
      [%ToolCall{id: "transport-A", name: "bash", args: {:ok, args}}] ->
        args == %{"command" => NativeGroup.command()}

      _ ->
        false
    end
  end

  defp observation(events) do
    source = details(events, :source)
    if source, do: InputObserver.read(source.path, expected()), else: {:error, :missing_source}
  end

  defp cleanup(config, log) do
    events = if Process.alive?(config.gate), do: Gate.snapshot(config.gate), else: []
    gates = if Process.alive?(config.gate), do: Gate.stop(config.gate), else: false
    workers = for %{point: :worker, details: %{pid: pid}} <- events, do: pid
    Enum.each(workers, &Process.exit(&1, :kill))
    File.write(Path.join(config.cwd, "release"), "released")

    physical =
      call(config, :cleanup_native, 5_000, fn ->
        no_admission = not Enum.any?(events, &(&1.point == :worker_handler))
        wait_cleanup(config, details(events, :native), workers, no_admission, Jobs.now() + 4_900)
      end)

    source = details(events, :source)

    source_stop =
      if source,
        do:
          call(config, :stop_source, 1_000, fn ->
            if Process.alive?(source.pid), do: GenServer.stop(source.pid, :normal, 500), else: :ok
          end),
        else: {:ok, :not_started}

    executor = details(events, :effect_executor)

    executor_stop =
      if executor do
        call(config, :stop_effect_executor, 1_000, fn ->
          case GenServer.whereis(executor.name) do
            nil -> :ok
            pid -> DynamicSupervisor.terminate_child(Elara.EffectExecutorSup, pid)
          end
        end)
      else
        {:ok, :not_started}
      end

    sessions = SessionRecovery.cleanup(config.co, config.brain, log, true)

    Map.merge(sessions, %{
      confirmed:
        sessions.confirmed and gates and physical == {:ok, true} and
          source_stop in [{:ok, :ok}, {:ok, :not_started}] and
          executor_stop in [{:ok, :ok}, {:ok, :not_started}],
      gates_settled: gates,
      native_settlement: physical,
      source_stop: source_stop,
      executor_stop: executor_stop
    })
  end

  defp wait_cleanup(config, native, workers, no_admission, deadline) do
    status = Elara.Exec.status()
    physical = NativeGroup.stopped(native)

    if (physical.stopped or (native == nil and no_admission)) and status.jobs == 0 and
         Enum.all?(workers, &(not Process.alive?(&1))) do
      true
    else
      if Jobs.now() >= deadline,
        do: false,
        else:
          (
            Process.sleep(10)
            wait_cleanup(config, native, workers, no_admission, deadline)
          )
    end
  end

  defp report(config, result, hook, events, evidence, observation, physical, cleanup) do
    checkpoint = details(events, :checkpoint)
    injected = event(events, :injected)
    eligible = event(events, :eligible)
    down = event(events, :target_down)
    recovered = event(events, :recovered)
    settled = event(events, :settled)
    intent = details(events, :intent_after)
    probe = details(events, :worker_probe)

    view =
      case observation do
        {:ok, {:ok, value}} -> value
        _ -> nil
      end

    after_native =
      case physical do
        {:ok, value} -> value
        error -> %{stopped: false, error: error}
      end

    fault =
      eligible != nil and injected != nil and eligible.at <= injected.at and
        eligible.details.target == injected.details.target and
        Enum.count(events, &(&1.point == :injected)) == 1

    death =
      fault and down != nil and down.details.reason == :killed and evidence.death.matched and
        evidence.death.reason == :killed and down.details.ref == injected.details.ref and
        down.details.target == injected.details.target and
        evidence.death.target == inspect(injected.details.target) and
        evidence.death.at >= injected.at and down.at >= injected.at and
        evidence.ordering.monitor_installed_at <= injected.at

    launches =
      case File.read(Path.join(config.cwd, "started")) do
        {:ok, bytes} -> byte_size(bytes)
        _ -> nil
      end

    recovery_ms = if down && recovered, do: recovered.at - down.at
    backlog_ms = if down && settled, do: settled.at - down.at

    checks = %{
      fault_witnessed: fault,
      target_down_witnessed: death,
      identities: view != nil and valid_inputs?(view),
      all_inputs_completed: view != nil and view.all_completed,
      source_mutation_indeterminate:
        recovered != nil and recovered.details.mutation.outcome == :indeterminate,
      stable_intent: checkpoint != nil and intent != nil and intent == checkpoint.job,
      direct_client_owned:
        checkpoint != nil and checkpoint.network.owner != checkpoint.source.pid,
      native_stopped_before_cleanup: after_native.stopped,
      launch_once: launches == 1,
      native_epoch_settled: recovered != nil and recovered.details.settlement == :settled,
      worker_serving: probe != nil and probe.result == "serving" and probe.alive,
      recovery_bounded: is_integer(recovery_ms) and recovery_ms <= @recovery_ms,
      backlog_bounded: is_integer(backlog_ms) and backlog_ms <= backlog_limit(config)
    }

    checks =
      if config.receipt_backend? do
        after_receipt = details(events, :effect_after)
        replay = details(events, :receipt_no_replay)

        Map.merge(checks, %{
          receipt_identity_preserved:
            after_receipt != nil and checkpoint != nil and
              after_receipt.record.job_id == checkpoint.job.job_id and
              after_receipt.record.operation_digest == checkpoint.job.operation_digest,
          receipt_indeterminate:
            after_receipt != nil and after_receipt.record.state == :indeterminate and
              after_receipt.record.terminal_count == 1,
          writer_survived:
            after_receipt != nil and checkpoint != nil and
              after_receipt.writer == checkpoint.network.writer,
          callback_linked_to_writer:
            checkpoint != nil and checkpoint.network.callback_linked_to_writer,
          no_receipt_replay: replay != nil and Enum.all?(Map.values(replay), & &1)
        })
      else
        checks
      end

    %{
      complete:
        result == {:ok, :ok} and fault and death and view != nil and cleanup.confirmed and
          hook == {:ok, :ok},
      checks: checks,
      error: if(result == {:ok, :ok}, do: nil, else: result),
      schedule: config.schedule,
      choices_digest: Elara.Lab.digest(config.schedule),
      ordering: events,
      death: evidence.death,
      observation: view,
      mutation: recovered && recovered.details.mutation,
      intent: intent,
      route: if(config.receipt_backend?, do: :receipt_callback_worker, else: :direct_tool_task),
      receipt_backend: config.receipt_backend?,
      receipt_before:
        case checkpoint && checkpoint.receipt do
          {:ok, record} -> Map.from_struct(record)
          _ -> nil
        end,
      receipt_after: details(events, :effect_after),
      receipt_no_replay: details(events, :receipt_no_replay),
      native: %{before: details(events, :native), after: after_native},
      launches: launches,
      recovery_ms: recovery_ms,
      backlog_ms: backlog_ms,
      bounds: %{
        recovery_ms: @recovery_ms,
        backlog_ms: backlog_limit(config),
        backlog_count: 2,
        per_input_work_ms: config.schedule.work_ms
      },
      cleanup: cleanup,
      cleanup_confirmed: cleanup.confirmed
    }
  end

  # Read the live ledger without acquiring write authority or changing its
  # schema/settings. The existing decoder still checks record and result digests.
  defp receipt(config, job_id) do
    %{name: {:via, Registry, {Elara.EffectExecutors, id}}} =
      details(Gate.snapshot(config.gate), :effect_executor)

    path = LocalExecutor.ledger_path(config.brain, id)
    {:ok, db} = Exqlite.Sqlite3.open(path, mode: :readonly)

    try do
      ExecutorLedger.query(
        %ExecutorLedger{db: db, path: path, configuration: %{mode: :readonly}},
        job_id
      )
    after
      Exqlite.Sqlite3.close(db)
    end
  end

  defp details(events, point) do
    case event(events, point) do
      nil -> nil
      event -> event.details
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
      {:ok, {:ok, value}} -> value
      {:ok, value} -> value
      error -> throw({op, error})
    end
  end

  defp poll!(config, op, deadline, fun) do
    case call!(config, op, deadline, fun) do
      nil ->
        if Jobs.now() >= deadline,
          do: throw({:timeout, op}),
          else:
            (
              Process.sleep(10)
              poll!(config, op, deadline, fun)
            )

      value ->
        value
    end
  end
end

defmodule Elara.Lab.TransportProvider do
  @moduledoc "Stateless responses for the declared transport input fixture."
  @behaviour Elara.Provider
  alias Elara.Lab.{Gate, NativeGroup}
  alias Elara.Message.{ToolCall, ToolResult, User}
  def chat(config, request), do: stream(config, request, fn _ -> :ok end)

  def stream(config, request, sink) do
    user = Enum.find(Enum.reverse(request.messages), &is_struct(&1, User))
    :ok = Gate.observe(config.gate, :provider_task, %{input: user.text})
    Process.sleep(config.schedule.work_ms)
    last = List.last(request.messages)

    {text, calls} =
      cond do
        last == user and user.text == "transport A" ->
          {"",
           [
             %ToolCall{
               id: "transport-A",
               name: "bash",
               args: {:ok, %{"command" => NativeGroup.command()}}
             }
           ]}

        user.text == "transport A" and
            match?(%ToolResult{call_id: "transport-A", outcome: {:indeterminate, _}}, last) ->
          {"done transport A", []}

        user.text in ["transport B", "transport C"] and last == user ->
          {"done " <> user.text, []}

        true ->
          raise "unknown transport fixture request"
      end

    {:ok, assistant} = Elara.Message.assistant(text, calls)
    sink.(text)
    {:ok, assistant, config}
  end
end
