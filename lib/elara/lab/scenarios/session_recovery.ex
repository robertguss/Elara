defmodule Elara.Lab.Scenarios.SessionRecovery do
  @moduledoc """
  LAB-5 recovery harness. The selected fault caller is held until persisted B/C
  backlog is observed, then a scenario-owned coordinator releases one injection.
  Results are judged only from a coherent read-only persisted store view.
  """

  @behaviour Elara.Lab

  alias Elara.Lab.{Jobs, Tools}
  alias Elara.Lab.Scenarios.SessionRecovery.{Coordinator, Deadline, Observer, StoreView}
  alias Elara.Message.User
  alias Elara.Provider.Simulated

  @faults ~w(provider_started provider_streaming tool_running)
  @hook "session-recovery"
  @simulator "recovery"
  @reopen_simulator "recovery-reopen"
  @recovery_bound_ms 5_000
  @work_allowance_ms 1_000
  @marks "marks.txt"

  @impl true
  def curve_fields do
    [
      {"recovery_ms", ["recovery_ms"]},
      {"backlog_ms", ["backlog_ms"]},
      {"marker_count", ["marker_count"]}
    ]
  end

  @impl true
  def run(%{provider: :real}), do: raise("session_recovery runs on the simulated provider only")

  def run(%{seed: seed, dir: dir} = context) do
    case parse_fault(get_in(context, [:params, "fault"])) do
      {:ok, fault} -> exercise(fault, seed, dir)
      :error -> unknown(dir)
    end
  end

  defp exercise(fault, seed, dir) do
    cwd = Path.join(dir, "workspace")
    File.mkdir_p!(cwd)
    log = Elara.Lab.choice_log()
    {point, key, target} = selected_fault(fault)
    {:ok, coordinator} = Coordinator.start_link(fault: fault, point: point, key: key)
    Coordinator.track(coordinator, :collector, log)

    Tools.register_hook(@hook, fn hook_point, hook_key ->
      Coordinator.hook(coordinator, hook_point, hook_key, :session)
    end)

    result =
      try do
        run_flow(fault, seed, cwd, log, coordinator, target)
      rescue
        error -> {:error, {:exception, Exception.message(error)}}
      catch
        kind, reason -> {:error, {kind, reason}}
      after
        Tools.unregister_hook(@hook)
      end

    ordering =
      case Coordinator.evidence(coordinator, 1_000) do
        evidence when is_map(evidence) -> evidence
        _ -> missing_coordinator_evidence()
      end

    cleanup = cleanup(coordinator, cwd, log)

    case result do
      {:ok, witness} ->
        witness
        |> Map.merge(ordering)
        |> Observer.report(cleanup)

      {:error, reason} ->
        incomplete("scenario_failed", reason, fault, cleanup, ordering)
    end
  end

  defp run_flow(fault, seed, cwd, log, coordinator, target) do
    deadline = Jobs.now() + @recovery_bound_ms
    provider = provider(seed, @simulator, log, fault, coordinator)

    with {:ok, {:ok, session}} <-
           Deadline.call(coordinator, :start, deadline, fn ->
             Elara.start_session(session_opts(cwd, provider))
           end),
         :ok <- Coordinator.track(coordinator, :session, session),
         {:ok, pid} <- Elara.session_pid(session),
         :ok <- maybe_observe_session_target(coordinator, target, pid),
         {:ok, accepted_a} <- submit(session, "A", coordinator, deadline),
         {:ok, _arrival} <- Coordinator.await_arrival(coordinator, remaining(deadline)),
         {:ok, accepted_b} <- submit(session, "B", coordinator, deadline),
         {:ok, accepted_c} <- submit(session, "C", coordinator, deadline),
         accepted = %{"A" => accepted_a, "B" => accepted_b, "C" => accepted_c},
         {:ok, path} <- StoreView.find_path(cwd, session, coordinator, deadline),
         {:ok, pending} <- StoreView.await_pending(path, cwd, accepted, coordinator, deadline),
         :ok <- Coordinator.witness_backlog(coordinator, pending.ids, remaining(deadline)),
         :ok <- Coordinator.release(coordinator, remaining(deadline)),
         {:ok, death} <- Coordinator.await_down(coordinator, @recovery_bound_ms) do
      case fault do
        :tool_running ->
          session_recovery(seed, cwd, log, coordinator, path, accepted, death)

        provider_fault ->
          provider_recovery(provider_fault, cwd, coordinator, path, session, accepted, death)
      end
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
    end
  end

  defp provider_recovery(fault, cwd, coordinator, path, session, accepted, death) do
    recovery_deadline = death.at + @recovery_bound_ms

    with {:ok, failed_view} <-
           StoreView.await_failed(path, cwd, accepted["A"].id, coordinator, recovery_deadline),
         recovery_endpoint = Jobs.now(),
         backlog_count = length(death.backlog_ids),
         backlog_deadline = death.at + @recovery_bound_ms + backlog_count * @work_allowance_ms,
         {:ok, settled_view} <-
           StoreView.await_settled(path, cwd, accepted, coordinator, backlog_deadline),
         backlog_endpoint = Jobs.now(),
         {:ok, marker_bytes} <- StoreView.read_markers(cwd, coordinator, backlog_deadline),
         {:ok, status} <-
           Deadline.call(coordinator, :status, Jobs.now() + 1_000, fn -> Elara.status(session) end),
         true <- is_map(status) do
      {:ok,
       StoreView.witness(settled_view, %{
         fault: fault,
         accepted: accepted,
         cwd: cwd,
         death: death,
         probe: :ok,
         paused_inputs: nil,
         recovery_ms: recovery_endpoint - death.at,
         backlog_ms: backlog_endpoint - death.at,
         backlog_count: backlog_count,
         backlog_settled: StoreView.settled?(settled_view, accepted),
         marker_bytes: marker_bytes,
         clocks: %{
           recovery: clock("target_down", death.at, recovery_endpoint),
           backlog: clock("target_down", death.at, backlog_endpoint)
         },
         failed_view: failed_view
       })}
    else
      false -> {:error, :unresponsive_status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp session_recovery(seed, cwd, log, coordinator, path, accepted, death) do
    reopen_at = Jobs.now()
    provider = provider(seed, @reopen_simulator, log, nil, coordinator)

    with {:ok, {:ok, reopened}} <-
           Deadline.call(coordinator, :reopen, reopen_at + @recovery_bound_ms, fn ->
             Elara.start_session(
               session_opts(cwd, provider) ++ [resume: path, pause_inputs: true]
             )
           end),
         :ok <- Coordinator.track(coordinator, :session, reopened),
         {:ok, status} <-
           Deadline.call(coordinator, :status, reopen_at + @recovery_bound_ms, fn ->
             Elara.status(reopened)
           end),
         true <- is_map(status),
         {:ok, paused_view} <-
           StoreView.await_paused(
             path,
             cwd,
             accepted,
             coordinator,
             reopen_at + @recovery_bound_ms
           ),
         recovery_endpoint = Jobs.now(),
         {:ok, failed_view} <-
           StoreView.await_failed(
             path,
             cwd,
             accepted["A"].id,
             coordinator,
             death.at + @recovery_bound_ms
           ),
         paused_inputs = StoreView.extra_inputs(paused_view, accepted),
         resume_at = Jobs.now(),
         {:ok, :ok} <-
           Deadline.call(coordinator, :resume, resume_at + @recovery_bound_ms, fn ->
             Elara.resume_inputs(reopened)
           end),
         backlog_count = length(death.backlog_ids),
         backlog_deadline = resume_at + @recovery_bound_ms + backlog_count * @work_allowance_ms,
         {:ok, settled_view} <-
           StoreView.await_settled(path, cwd, accepted, coordinator, backlog_deadline),
         backlog_endpoint = Jobs.now(),
         {:ok, marker_bytes} <- StoreView.read_markers(cwd, coordinator, backlog_deadline) do
      {:ok,
       StoreView.witness(settled_view, %{
         fault: :tool_running,
         accepted: accepted,
         cwd: cwd,
         death: death,
         probe: :ok,
         paused_inputs: paused_inputs,
         recovery_ms: recovery_endpoint - reopen_at,
         backlog_ms: backlog_endpoint - resume_at,
         backlog_count: backlog_count,
         backlog_settled: StoreView.settled?(settled_view, accepted),
         marker_bytes: marker_bytes,
         clocks: %{
           recovery: clock("immediately_before_reopen", reopen_at, recovery_endpoint),
           backlog: clock("explicit_resume", resume_at, backlog_endpoint),
           a_failure: clock("target_down", death.at, Jobs.now())
         },
         failed_view: failed_view
       })}
    else
      false -> {:error, :reopen_unresponsive}
      {:error, reason} -> {:error, reason}
    end
  end

  defp submit(session, label, coordinator, deadline) do
    attrs = %{
      id: "recovery-#{label}",
      sender_id: "lab",
      kind: :normal,
      user: %User{text: "input #{label}"}
    }

    case Deadline.call(coordinator, :submit, deadline, fn ->
           Elara.submit_input(session, attrs)
         end) do
      {:ok, {:ok, entry}} -> {:ok, %{id: entry.id, label: label, text: attrs.user.text}}
      {:ok, {:error, reason}} -> {:error, {:submit_failed, label, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp provider(seed, id, log, fault, coordinator) do
    hook =
      if fault in [:provider_started, :provider_streaming] do
        fn point, key -> Coordinator.hook(coordinator, point, key, :task) end
      end

    Simulated.new(
      seed: seed,
      id: id,
      profile: profile(fault),
      collector: log,
      fault: hook
    )
  end

  defp profile(fault) do
    labels =
      if fault in [:provider_started, :provider_streaming], do: ["B", "C"], else: ["A", "B", "C"]

    [
      ttft_ms: 10,
      deltas_per_sec: 100,
      delta_bytes: 8,
      answer_deltas: 2,
      tool_rounds: 0,
      rules: Enum.map(labels, &marker_rule/1)
    ]
  end

  defp marker_rule(label) do
    {fn messages ->
       match?(%User{text: "input " <> ^label, agent_source: nil}, List.last(messages))
     end, {:tool, "lab_marker", marker_args(label)}}
  end

  defp marker_args(label) do
    %{"path" => @marks, "label" => label, "hook" => @hook, "key" => "label:#{label}"}
  end

  defp session_opts(cwd, provider) do
    [
      cwd: cwd,
      home: cwd,
      skill_paths: [],
      plugins: [],
      tools: [Tools.marker()],
      persist: true,
      max_iterations: 3,
      provider: provider
    ]
  end

  defp cleanup(coordinator, cwd, log) do
    {state, coordinator_read} =
      case Coordinator.snapshot(coordinator, 1_000) do
        state when is_map(state) -> {state, true}
        _ -> {missing_coordinator_state(), false}
      end

    sessions = state.sessions ++ Enum.map(Elara.list_sessions(cwd), & &1.id)

    session_results =
      sessions
      |> Enum.uniq()
      |> Enum.map(fn session ->
        deadline = Jobs.now() + 1_000

        case Deadline.call(coordinator, :stop, deadline, fn -> bounded_stop(session) end) do
          {:ok, :ok} -> true
          _ -> session_dead?(session)
        end
      end)

    owned_pids =
      [state.target, state.caller | state.helpers ++ MapSet.to_list(state.workers)]
      |> Enum.filter(&is_pid/1)
      |> Enum.uniq()

    Enum.each(owned_pids, fn pid ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    helpers_settled = await_dead(owned_pids, Jobs.now() + 1_000)
    choices = collect_choices(coordinator, log)
    if Process.alive?(log), do: Process.exit(log, :kill)
    collector_settled = await_dead([log], Jobs.now() + 1_000)

    unresolved =
      case Coordinator.snapshot(coordinator, 1_000) do
        state when is_map(state) -> state.unresolved
        _ -> [:coordinator_snapshot]
      end

    Coordinator.stop(coordinator)
    coordinator_settled = not Process.alive?(coordinator)

    %{
      confirmed:
        Enum.all?(session_results) and helpers_settled and collector_settled and
          coordinator_read and coordinator_settled and unresolved == [],
      sessions: session_results,
      helpers_settled: helpers_settled,
      collector_settled: collector_settled,
      coordinator_settled: coordinator_settled,
      unresolved: unresolved,
      choices: choices
    }
  end

  defp collect_choices(coordinator, log) do
    case Deadline.call(coordinator, :choices, Jobs.now() + 500, fn -> Elara.Lab.choices(log) end) do
      {:ok, choices} -> choices
      _ -> %{}
    end
  end

  defp bounded_stop(session) do
    case Elara.session_pid(session) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        Process.exit(pid, :shutdown)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          500 ->
            Process.exit(pid, :kill)

            receive do
              {:DOWN, ^ref, :process, ^pid, _} -> :ok
            after
              250 -> {:error, :still_alive}
            end
        end

      _ ->
        :ok
    end
  end

  defp session_dead?(session) do
    case Elara.session_pid(session) do
      {:ok, pid} -> not Process.alive?(pid)
      _ -> true
    end
  end

  defp await_dead([], _deadline), do: true

  defp await_dead(pids, deadline) do
    alive = Enum.filter(pids, &Process.alive?/1)

    cond do
      alive == [] ->
        true

      Jobs.now() >= deadline ->
        false

      true ->
        Process.sleep(10)
        await_dead(alive, deadline)
    end
  end

  defp missing_coordinator_state do
    %{
      sessions: [],
      target: nil,
      caller: nil,
      helpers: [],
      workers: MapSet.new(),
      unresolved: [:coordinator_snapshot]
    }
  end

  defp missing_coordinator_evidence do
    %{
      death: %{matched: false, target: nil, reason: nil, at: nil},
      ordering: %{
        target: nil,
        backlog_ids: [],
        monitor_installed_at: nil,
        arrived_at: nil,
        backlog_observed_at: nil,
        released_at: nil,
        injected_at: nil,
        target_down_at: nil
      },
      fault_seen: false,
      target_down: false,
      one_shot: false,
      hook_returned_before_down: false
    }
  end

  defp selected_fault(:tool_running), do: {:tool_running, "label:A", :session}
  defp selected_fault(point), do: {point, "#{@simulator}:1", :task}

  defp maybe_observe_session_target(coordinator, :session, pid),
    do: Coordinator.set_expected_target(coordinator, pid)

  defp maybe_observe_session_target(_coordinator, :task, _pid), do: :ok

  defp clock(origin, origin_at, endpoint_at) do
    %{origin: origin, origin_at: origin_at, endpoint_at: endpoint_at, ms: endpoint_at - origin_at}
  end

  defp remaining(deadline), do: max(deadline - Jobs.now(), 0)

  defp parse_fault(name) when name in @faults, do: {:ok, String.to_existing_atom(name)}
  defp parse_fault(_), do: :error

  defp unknown(dir) do
    %{
      checks: %{known_fault: false},
      bounds: %{"recovery" => "undetermined", "backlog" => "undetermined"},
      incomplete: "unknown_fault",
      complete: false,
      cleanup_confirmed: true,
      completed_turns: 0,
      choices_digest: Elara.Lab.digest({:unknown_fault, dir}),
      recovery_ms: nil,
      backlog_ms: nil,
      marker_count: 0,
      recovery: %{accepted_ids: [], receipts: %{}, history_count: 0, marker_bytes: []}
    }
  end

  defp incomplete(reason, detail, fault, cleanup, ordering) do
    %{
      checks: %{known_fault: true, prerequisites_observed: false},
      bounds: %{"recovery" => "undetermined", "backlog" => "undetermined"},
      incomplete: "#{reason}: #{inspect(detail)}",
      complete: false,
      cleanup_confirmed: cleanup.confirmed,
      cleanup: cleanup,
      ordering: ordering.ordering,
      death: ordering.death,
      completed_turns: 0,
      choices_digest: Elara.Lab.digest({reason, fault, detail}),
      recovery_ms: nil,
      backlog_ms: nil,
      marker_count: 0,
      fault: Atom.to_string(fault),
      recovery: %{accepted_ids: [], receipts: %{}, history_count: 0, marker_bytes: []}
    }
  end
end

defmodule Elara.Lab.Scenarios.SessionRecovery.Coordinator do
  @moduledoc false
  use GenServer

  alias Elara.Lab.Faults
  alias Elara.Lab.Jobs

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  def hook(pid, point, key, target) do
    target_pid = target_pid(target)

    case GenServer.call(pid, {:arrive, point, key, target, target_pid, self()}, :infinity) do
      {:inject, selected_target} ->
        GenServer.cast(pid, {:injected, self()})
        Faults.inject(selected_target)
        _ = await_down(pid, 5_000)
        record_hook_return(pid)
        :ok

      :skip ->
        :skip
    end
  end

  def await_arrival(pid, timeout), do: await(pid, :arrival, timeout)
  def await_down(pid, timeout), do: await(pid, :down, timeout)

  def witness_backlog(pid, ids, timeout \\ 1_000),
    do: bounded_call(pid, {:backlog, ids, Jobs.now() + timeout}, timeout)

  def release(pid, timeout \\ 1_000),
    do: bounded_call(pid, {:release, Jobs.now() + timeout}, timeout)

  def snapshot(pid, timeout \\ 1_000), do: bounded_call(pid, :snapshot, timeout)
  def evidence(pid, timeout \\ 1_000), do: bounded_call(pid, :evidence, timeout)
  def track(pid, kind, resource), do: bounded_call(pid, {:track, kind, resource}, 1_000)
  def record_hook_return(pid), do: bounded_call(pid, :hook_returned, 1_000)
  def observe_target(pid, target), do: bounded_call(pid, {:observe_target, target}, 1_000)

  def set_expected_target(pid, target),
    do: bounded_call(pid, {:expected_target, target}, 1_000)

  @impl true
  def init(opts) do
    {:ok,
     %{
       fault: opts[:fault],
       point: opts[:point],
       key: opts[:key],
       expected_target: nil,
       target: nil,
       caller: nil,
       monitor: nil,
       arrival_from: nil,
       arrived_at: nil,
       monitor_installed_at: nil,
       backlog_ids: [],
       backlog_observed_at: nil,
       released: false,
       released_at: nil,
       injections: 0,
       injected_at: nil,
       down: nil,
       hook_returned_at: nil,
       hook_returned_before_down: false,
       helpers: [],
       workers: MapSet.new(),
       sessions: [],
       collectors: [],
       unresolved: []
     }}
  end

  @impl true
  def handle_call({:arrive, point, key, target, target_pid, caller}, from, state) do
    state = %{state | workers: MapSet.put(state.workers, caller)}
    selected = point == state.point and key == state.key

    cond do
      not selected or state.arrival_from != nil or state.injections > 0 ->
        {:reply, :skip, state}

      not is_pid(target_pid) or not Process.alive?(target_pid) ->
        {:reply, :skip, %{state | unresolved: [:missing_target | state.unresolved]}}

      not is_nil(state.expected_target) and state.expected_target != target_pid ->
        {:reply, :skip, %{state | unresolved: [:wrong_target | state.unresolved]}}

      true ->
        installed = Jobs.now()
        ref = Process.monitor(target_pid)
        arrived = Jobs.now()

        {:noreply,
         %{
           state
           | target: target_pid,
             caller: caller,
             monitor: ref,
             arrival_from: {from, target},
             monitor_installed_at: installed,
             arrived_at: arrived
         }}
    end
  end

  def handle_call({:backlog, ids, deadline}, _from, state) do
    if Jobs.now() < deadline and length(ids) == 2 and Enum.all?(ids, &is_binary/1) and
         length(Enum.uniq(ids)) == 2 do
      {:reply, :ok, %{state | backlog_ids: ids, backlog_observed_at: Jobs.now()}}
    else
      {:reply, {:error, :invalid_backlog}, state}
    end
  end

  def handle_call(
        {:release, deadline},
        _from,
        %{arrival_from: {from, target}, backlog_ids: [_, _]} = state
      ) do
    if Jobs.now() >= deadline do
      {:reply, {:error, :timeout}, state}
    else
      released = Jobs.now()
      GenServer.reply(from, {:inject, target})

      {:reply, :ok,
       %{state | released: true, released_at: released, injections: state.injections + 1}}
    end
  end

  def handle_call({:release, _deadline}, _from, state),
    do: {:reply, {:error, :barrier_incomplete}, state}

  def handle_call({:observe_target, target}, _from, state) do
    if is_pid(target) and Process.alive?(target) do
      installed = Jobs.now()
      ref = Process.monitor(target)

      {:reply, :ok,
       %{
         state
         | target: target,
           monitor: ref,
           monitor_installed_at: installed,
           arrived_at: installed
       }}
    else
      {:reply, {:error, :missing_target}, state}
    end
  end

  def handle_call({:expected_target, target}, _from, state),
    do: {:reply, :ok, %{state | expected_target: target}}

  def handle_call(:hook_returned, _from, state) do
    returned_at = Jobs.now()

    {:reply, :ok,
     %{
       state
       | hook_returned_at: returned_at,
         hook_returned_before_down: state.hook_returned_before_down or is_nil(state.down)
     }}
  end

  def handle_call({:track, :session, session}, _from, state),
    do: {:reply, :ok, %{state | sessions: [session | state.sessions]}}

  def handle_call({:track, :collector, collector}, _from, state),
    do: {:reply, :ok, %{state | collectors: [collector | state.collectors]}}

  def handle_call(:snapshot, _from, state), do: {:reply, public_state(state), state}

  def handle_call(:evidence, _from, state) do
    death =
      case state.down do
        nil ->
          %{matched: false, target: encode_pid(state.target), reason: nil, at: nil}

        down ->
          %{matched: true, target: encode_pid(down.target), reason: down.reason, at: down.at}
      end

    ordering = %{
      fault_key: state.key,
      fault_point: state.point,
      monitor_installed_at: state.monitor_installed_at,
      arrived_at: state.arrived_at,
      backlog_observed_at: state.backlog_observed_at,
      released_at: state.released_at,
      injected_at: state.injected_at,
      target_down_at: state.down && state.down.at,
      target: encode_pid(state.target),
      hook_returned_at: state.hook_returned_at,
      backlog_ids: state.backlog_ids
    }

    {:reply,
     %{
       death: death,
       ordering: ordering,
       fault_seen: not is_nil(state.arrived_at),
       target_down: death.matched,
       one_shot: state.injections == 1,
       hook_returned_before_down: state.hook_returned_before_down
     }, state}
  end

  @impl true
  def handle_cast({:injected, caller}, state) do
    if caller == state.caller,
      do: {:noreply, %{state | injected_at: Jobs.now()}},
      else: {:noreply, %{state | unresolved: [:wrong_injector | state.unresolved]}}
  end

  @impl true
  def handle_info({:register_helper, owner, helper, token, deadline}, state) do
    if Jobs.now() < deadline and Process.alive?(helper) do
      Process.monitor(helper)
      send(owner, {:helper_registered, token})
      {:noreply, %{state | helpers: [helper | state.helpers]}}
    else
      send(owner, {:helper_registration_expired, token})
      {:noreply, state}
    end
  end

  def handle_info({:settle_helper, helper}, state) do
    helpers =
      if Process.alive?(helper), do: state.helpers, else: List.delete(state.helpers, helper)

    {:noreply, %{state | helpers: helpers}}
  end

  def handle_info({:unresolved, operation}, state),
    do: {:noreply, %{state | unresolved: [operation | state.unresolved]}}

  def handle_info({:DOWN, ref, :process, target, reason}, %{monitor: ref, target: target} = state) do
    {:noreply, %{state | down: %{target: target, reason: reason, at: Jobs.now()}}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, %{state | helpers: List.delete(state.helpers, pid)}}

  defp await(pid, field, timeout) do
    deadline = Jobs.now() + timeout

    wait = fn wait ->
      state = snapshot(pid, max(deadline - Jobs.now(), 1))

      value =
        case {field, state} do
          {:arrival, state} when is_map(state) ->
            if state.arrived_at,
              do:
                {:ok,
                 %{
                   target: state.target,
                   arrived_at: state.arrived_at,
                   monitor_installed_at: state.monitor_installed_at
                 }}

          {:down, state} when is_map(state) ->
            if state.down,
              do:
                {:ok,
                 Map.merge(state.down, %{
                   backlog_ids: state.backlog_ids,
                   fault_key: state.key,
                   fault_point: state.point
                 })}

          _ ->
            nil
        end

      cond do
        value ->
          value

        Jobs.now() >= deadline ->
          {:error, :timeout}

        true ->
          Process.sleep(5)
          wait.(wait)
      end
    end

    wait.(wait)
  end

  defp target_pid(:task), do: self()

  defp target_pid(:session) do
    (Process.get(:"$callers") || [])
    |> Enum.find(&(Registry.keys(Elara.Sessions, &1) != []))
  end

  defp public_state(state), do: Map.drop(state, [:arrival_from, :monitor])
  defp encode_pid(pid) when is_pid(pid), do: inspect(pid)
  defp encode_pid(_), do: nil

  defp bounded_call(pid, request, timeout) do
    started = Jobs.now()

    try do
      result = GenServer.call(pid, request, max(timeout, 1))
      if Jobs.now() - started <= timeout, do: result, else: {:error, :timeout}
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, {:noproc, _} -> {:error, :coordinator_down}
    end
  end
end

defmodule Elara.Lab.Scenarios.SessionRecovery.Deadline do
  @moduledoc false

  alias Elara.Lab.Jobs
  alias Elara.Lab.Scenarios.SessionRecovery.Coordinator

  def call(coordinator, operation, deadline, fun) when is_function(fun, 0) do
    if Jobs.now() >= deadline do
      {:error, {:timeout, operation}}
    else
      owner = self()
      token = make_ref()

      helper =
        spawn(fn ->
          receive do
            {:run, ^token} ->
              result = invoke(fun)
              send(owner, {token, result, Jobs.now()})

              receive do
                {:result_ack, ^token} -> :ok
              end
          end
        end)

      ref = Process.monitor(helper)
      send(coordinator, {:register_helper, owner, helper, token, deadline})
      await_registration(coordinator, operation, deadline, token, helper, ref)
    end
  end

  defp await_registration(coordinator, operation, deadline, token, helper, ref) do
    receive do
      {:helper_registered, ^token} ->
        if Jobs.now() < deadline do
          send(helper, {:run, token})
          await_result(coordinator, operation, deadline, token, helper, ref)
        else
          timeout(coordinator, operation, helper, ref, false)
        end

      {:helper_registration_expired, ^token} ->
        timeout(coordinator, operation, helper, ref, false)

      {:DOWN, ^ref, :process, ^helper, reason} ->
        send(coordinator, {:settle_helper, helper})
        {:error, {:helper_down, operation, reason}}
    after
      remaining(deadline) -> timeout(coordinator, operation, helper, ref, false)
    end
  end

  defp await_result(coordinator, operation, deadline, token, helper, ref) do
    receive do
      {^token, result, completed_at} ->
        send(helper, {:result_ack, token})
        settled = await_down(helper, ref, Jobs.now() + 100)
        if settled, do: send(coordinator, {:settle_helper, helper})

        cond do
          completed_at >= deadline -> timeout_result(operation, settled)
          not settled -> {:error, {:timeout_unsettled, operation}}
          true -> result
        end

      {:DOWN, ^ref, :process, ^helper, reason} ->
        send(coordinator, {:settle_helper, helper})
        {:error, {:helper_down, operation, reason}}
    after
      remaining(deadline) -> timeout(coordinator, operation, helper, ref, true)
    end
  end

  defp timeout(coordinator, operation, helper, ref, launched?) do
    Process.exit(helper, :kill)
    settled = await_down(helper, ref, Jobs.now() + 100)
    if settled, do: send(coordinator, {:settle_helper, helper})

    if launched? and operation in [:start, :reopen],
      do: send(coordinator, {:unresolved, operation})

    timeout_result(operation, settled)
  end

  defp timeout_result(operation, true), do: {:error, {:timeout, operation}}
  defp timeout_result(operation, false), do: {:error, {:timeout_unsettled, operation}}

  defp invoke(fun) do
    try do
      {:ok, fun.()}
    rescue
      error -> {:error, {:exception, Exception.message(error)}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp await_down(helper, ref, deadline) do
    receive do
      {:DOWN, ^ref, :process, ^helper, _} -> true
    after
      max(deadline - Jobs.now(), 0) -> not Process.alive?(helper)
    end
  end

  defp remaining(deadline), do: max(deadline - Jobs.now(), 0)
end

defmodule Elara.Lab.Scenarios.SessionRecovery.StoreView do
  @moduledoc false

  alias Elara.Lab.Jobs
  alias Elara.Lab.Scenarios.SessionRecovery.Deadline
  alias Elara.Message.{Assistant, ToolCall, ToolResult, User}
  alias Elara.Session.Store

  @labels ["A", "B", "C"]
  @marks "marks.txt"

  def find_path(cwd, session, coordinator, deadline) do
    poll(coordinator, :find_path, deadline, fn ->
      case Enum.find(Elara.list_sessions(cwd), &(&1.id == session)) do
        %{path: path} when is_binary(path) -> {:ok, path}
        _ -> :retry
      end
    end)
  end

  def await_pending(path, cwd, accepted, coordinator, deadline) do
    poll(coordinator, :store_read, deadline, fn ->
      with {:ok, store} <- Store.open(path, cwd),
           entries <- Enum.filter(store.inbox, &(&1.id in [accepted["B"].id, accepted["C"].id])),
           true <- Enum.map(entries, & &1.id) == [accepted["B"].id, accepted["C"].id],
           true <- Enum.all?(entries, &(&1.state in [:accepted, :queued])) do
        {:ok, %{store: store, ids: Enum.map(entries, & &1.id)}}
      else
        _ -> :retry
      end
    end)
  end

  def await_failed(path, cwd, id, coordinator, deadline) do
    poll_store(path, cwd, coordinator, deadline, fn store ->
      Enum.any?(store.inbox, &(&1.id == id and &1.state == :failed and is_binary(&1.error)))
    end)
  end

  def await_paused(path, cwd, accepted, coordinator, deadline) do
    poll_store(path, cwd, coordinator, deadline, fn store ->
      store.inputs_paused == true and
        Enum.all?(["B", "C"], fn label ->
          Enum.any?(store.inbox, fn entry ->
            entry.id == accepted[label].id and entry.state in [:accepted, :queued]
          end)
        end)
    end)
  end

  def await_settled(path, cwd, accepted, coordinator, deadline),
    do: poll_store(path, cwd, coordinator, deadline, &settled?(&1, accepted))

  def settled?(store, accepted) do
    store.active_input_id == nil and
      Enum.all?(["B", "C"], fn label ->
        Enum.any?(store.inbox, fn entry ->
          entry.id == accepted[label].id and entry.state == :consumed and is_nil(entry.error)
        end)
      end) and exact_store?(store, accepted)
  end

  def extra_inputs(store, accepted) do
    known = accepted |> Map.values() |> Enum.map(& &1.id) |> MapSet.new()
    Enum.count(store.inbox, &(not MapSet.member?(known, &1.id)))
  end

  def read_markers(cwd, coordinator, deadline) do
    case Deadline.call(coordinator, :marker_read, deadline, fn -> read_markers(cwd) end) do
      {:ok, markers} -> {:ok, markers}
      {:error, {:timeout, :marker_read}} -> {:error, :marker_deadline}
      {:error, {:timeout_unsettled, :marker_read}} -> {:error, :marker_deadline}
      {:error, reason} -> {:error, reason}
    end
  end

  def witness(store, attrs) do
    accepted = attrs.accepted
    history = encode_history(store)
    users = Enum.filter(history, &(&1["kind"] == "user"))

    inputs =
      Map.new(@labels, fn label ->
        accepted_entry = accepted[label]
        receipt = Enum.find(store.inbox, &(&1.id == accepted_entry.id))
        user = Enum.find(users, &(&1["text"] == accepted_entry.text))
        call = marker_call(segment(history, label), label)
        result = call && marker_result(segment(history, label), call["id"])

        {label,
         %{
           accepted_id: accepted_entry.id,
           persisted_user_id: user && user["id"],
           call_id: call && call["id"],
           label: label,
           receipt:
             receipt &&
               %{
                 state: receipt.state,
                 error: receipt.error,
                 session_id: receipt.session_id,
                 sender_id: receipt.sender_id,
                 kind: receipt.kind,
                 user_text: receipt.user.text
               },
           tool_outcome: result && result["outcome"],
           active_cleared: is_nil(store.active_input_id)
         }}
      end)

    %{
      fault: attrs.fault,
      inputs: inputs,
      accepted_order: Enum.map(store.inbox, & &1.id),
      history: history,
      marker_labels: logical_labels(history),
      marker_bytes: Map.get_lazy(attrs, :marker_bytes, fn -> read_markers(attrs.cwd) end),
      store_read: true,
      persisted_identity_valid: exact_store?(store, accepted),
      probe: attrs.probe,
      recovery_ms: attrs.recovery_ms,
      backlog_ms: attrs.backlog_ms,
      backlog_count: attrs.backlog_count,
      backlog_settled: attrs.backlog_settled,
      paused_inputs: attrs.paused_inputs,
      active_input_id: store.active_input_id,
      clocks: attrs.clocks
    }
  end

  def exact_history?(store_or_history, accepted) do
    history =
      if is_list(store_or_history), do: store_or_history, else: encode_history(store_or_history)

    users = Enum.filter(history, &(&1["kind"] == "user"))

    call_ids =
      Enum.flat_map(history, &Enum.map(Map.get(&1, "tool_calls", []), fn call -> call["id"] end))

    Enum.map(users, & &1["text"]) == Enum.map(@labels, &accepted[&1].text) and
      Enum.all?(call_ids, &(is_binary(&1) and &1 != "")) and
      length(call_ids) == length(Enum.uniq(call_ids)) and
      Enum.all?(@labels, fn label ->
        user = Enum.at(users, label_index(label))
        user && user["id"] && segment_valid?(segment(history, label), label)
      end)
  end

  defp segment_valid?(segment, "A") do
    calls = marker_calls(segment)
    results = Enum.filter(segment, &(&1["kind"] == "tool_result"))

    case segment do
      [] ->
        true

      [%{"kind" => "assistant", "tool_calls" => [], "interrupted" => true}] ->
        true

      [call_entry, result] ->
        marker_a_pair?([call_entry, result], calls, results)

      _ ->
        false
    end
  end

  defp segment_valid?(segment, label) do
    calls = marker_calls(segment)
    results = Enum.filter(segment, &(&1["kind"] == "tool_result"))
    terminals = Enum.filter(segment, &terminal?/1)

    length(segment) == 3 and marker_pair?(calls, results, label) and length(terminals) == 1 and
      ordered?(segment, hd(calls), hd(results), hd(terminals))
  end

  defp marker_pair?([call], [result], label) do
    call["name"] == "lab_marker" and call["args"]["label"] == label and
      result["call_id"] == call["id"] and result["name"] == "lab_marker" and
      result["outcome"] == %{"kind" => "ok", "text" => "marked #{label}"}
  end

  defp marker_pair?(_, _, _), do: false

  defp marker_a_pair?([call_entry, result] = segment, [call], [result]) do
    call_entry["kind"] == "assistant" and call_entry["tool_calls"] == [call] and
      call["name"] == "lab_marker" and call["args"]["label"] == "A" and
      result["call_id"] == call["id"] and result["name"] == "lab_marker" and
      get_in(result, ["outcome", "kind"]) in ["error", "indeterminate"] and
      ordered_pair?(segment, call, result)
  end

  defp marker_a_pair?(_segment, _calls, _results), do: false

  defp ordered?(segment, call, result, terminal) do
    call_entry = Enum.find(segment, &(call in Map.get(&1, "tool_calls", [])))

    indexes =
      Enum.map(
        [call_entry, result, terminal],
        &Enum.find_index(segment, fn item -> item == &1 end)
      )

    indexes == Enum.sort(indexes) and Enum.all?(indexes, &is_integer/1)
  end

  defp ordered_pair?(segment, call, result) do
    call_entry = Enum.find(segment, &(call in Map.get(&1, "tool_calls", [])))
    indexes = Enum.map([call_entry, result], &Enum.find_index(segment, fn item -> item == &1 end))
    indexes == Enum.sort(indexes) and Enum.all?(indexes, &is_integer/1)
  end

  defp terminal?(%{
         "kind" => "assistant",
         "tool_calls" => [],
         "text" => text,
         "interrupted" => false
       })
       when is_binary(text),
       do: true

  defp terminal?(_), do: false

  defp marker_calls(segment) do
    Enum.flat_map(segment, fn
      %{"kind" => "assistant", "tool_calls" => calls} -> calls
      _ -> []
    end)
  end

  defp marker_call(segment, label) do
    Enum.find(marker_calls(segment), fn call ->
      call["name"] == "lab_marker" and call["args"]["label"] == label
    end)
  end

  defp marker_result(segment, call_id),
    do: Enum.find(segment, &(&1["kind"] == "tool_result" and &1["call_id"] == call_id))

  defp segment(history, label) do
    start = Enum.find_index(history, &(&1["kind"] == "user" and &1["text"] == "input #{label}"))

    if is_integer(start) do
      history
      |> Enum.drop(start + 1)
      |> Enum.take_while(&(&1["kind"] != "user"))
    else
      []
    end
  end

  defp encode_history(store) do
    store
    |> selected_entries()
    |> Enum.map(fn entry -> encode_entry(entry.id, entry.message) end)
  end

  defp encode_entry(id, %User{text: text}),
    do: %{"id" => id, "kind" => "user", "text" => text}

  defp encode_entry(id, %Assistant{} = assistant) do
    %{
      "id" => id,
      "kind" => "assistant",
      "text" => assistant.text,
      "interrupted" => assistant.interrupted,
      "tool_calls" => Enum.map(assistant.tool_calls, &encode_call/1)
    }
  end

  defp encode_entry(id, %ToolResult{} = result) do
    %{
      "id" => id,
      "kind" => "tool_result",
      "call_id" => result.call_id,
      "name" => result.name,
      "outcome" => encode_outcome(result.outcome)
    }
  end

  defp encode_call(%ToolCall{id: id, name: name, args: args}),
    do: %{"id" => id, "name" => name, "args" => encode_args(args)}

  defp encode_args({:ok, args}), do: args
  defp encode_args({:malformed, text}), do: %{"malformed" => text}
  defp encode_outcome({kind, text}), do: %{"kind" => Atom.to_string(kind), "text" => text}

  defp logical_labels(history) do
    Enum.flat_map(history, fn
      %{"kind" => "assistant", "tool_calls" => calls} ->
        Enum.flat_map(calls, fn
          %{"name" => "lab_marker", "args" => %{"label" => label}} -> [label]
          _ -> []
        end)

      _ ->
        []
    end)
  end

  defp read_markers(cwd) do
    path = Path.join(cwd, @marks)
    if File.exists?(path), do: path |> File.read!() |> String.split("\n", trim: true), else: []
  end

  defp poll_store(path, cwd, coordinator, deadline, predicate) do
    poll(coordinator, :store_read, deadline, fn ->
      case Store.open(path, cwd) do
        {:ok, store} -> if predicate.(store), do: {:ok, store}, else: :retry
        {:error, _} -> :retry
      end
    end)
  end

  defp poll(coordinator, operation, deadline, fun) do
    case Deadline.call(coordinator, operation, deadline, fun) do
      {:ok, {:ok, value}} ->
        {:ok, value}

      {:ok, :retry} ->
        if Jobs.now() < deadline do
          Process.sleep(min(10, max(deadline - Jobs.now(), 0)))
          poll(coordinator, operation, deadline, fun)
        else
          {:error, :store_deadline}
        end

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, {:timeout, ^operation}} ->
        {:error, :store_deadline}

      {:error, {:timeout_unsettled, ^operation}} ->
        {:error, :store_deadline}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp exact_store?(store, accepted) do
    expected_ids = Enum.map(@labels, &accepted[&1].id)

    receipts_match =
      store.inbox
      |> Enum.zip(@labels)
      |> Enum.all?(fn {receipt, label} ->
        receipt.session_id == store.id and receipt.sender_id == "lab" and
          receipt.kind == :normal and match?(%User{text: "input " <> ^label}, receipt.user)
      end)

    selected_chain_covers_store?(store) and
      Enum.map(store.inbox, & &1.id) == expected_ids and
      receipts_match and exact_history?(encode_history(store), accepted)
  end

  defp selected_chain_covers_store?(%{entries: []}), do: false

  defp selected_chain_covers_store?(store) do
    store.leaf == List.last(store.entries).id and
      store.entries
      |> Enum.map(& &1.parent_id)
      |> Kernel.==([nil | Enum.map(Enum.drop(store.entries, -1), & &1.id)])
  end

  defp selected_entries(%{leaf: nil}), do: []

  defp selected_entries(store) do
    by_id = Map.new(store.entries, &{&1.id, &1})
    walk_selected(by_id, store.leaf, [])
  end

  defp walk_selected(by_id, id, acc) do
    case Map.fetch(by_id, id) do
      {:ok, entry} ->
        acc = [entry | acc]
        if entry.parent_id, do: walk_selected(by_id, entry.parent_id, acc), else: acc

      :error ->
        []
    end
  end

  defp label_index("A"), do: 0
  defp label_index("B"), do: 1
  defp label_index("C"), do: 2
end

defmodule Elara.Lab.Scenarios.SessionRecovery.Observer do
  @moduledoc false

  alias Elara.Lab.Scenarios.SessionRecovery.StoreView

  @labels ["A", "B", "C"]

  def judge(witness) do
    ids = Enum.map(@labels, &get_in(witness, [:inputs, &1, :accepted_id]))

    checks = %{
      known_fault: witness.fault in [:provider_started, :provider_streaming, :tool_running],
      fault_witnessed: witness.fault_seen == true,
      target_down_witnessed:
        witness.target_down == true and get_in(witness, [:death, :matched]) == true,
      unique_accepted_inputs: length(Enum.uniq(ids)) == 3 and Enum.all?(ids, &is_binary/1),
      backlog_witnessed_before_release: barrier?(witness),
      one_shot_gate: witness.one_shot == true and witness.fault_seen == true,
      stable_labels: witness.marker_labels == expected_labels(witness.fault),
      exact_identities: exact_identities?(witness),
      persisted_state_read: witness.store_read == true,
      settled_receipts: settled_receipts?(witness),
      active_input_cleared:
        witness.active_input_id == nil and Enum.all?(witness.inputs, &elem(&1, 1).active_cleared),
      history_identity: StoreView.exact_history?(witness.history, accepted_fixture(witness)),
      physical_marker_counts: witness.marker_bytes == expected_labels(witness.fault),
      no_unexpected_labels: witness.marker_labels == expected_labels(witness.fault),
      backlog_completed: witness.backlog_settled == true and settled_backlog?(witness),
      responsive_probe: witness.probe == :ok,
      timing_bounded: timing_evidence?(witness),
      indeterminate_without_receipt: typed_uncertainty?(witness),
      no_input_while_paused: witness.paused_inputs in [nil, 0],
      marker_hook_blocked_until_down: witness.hook_returned_before_down != true
    }

    %{
      checks: checks,
      cleanup_confirmed: get_in(witness, [:cleanup, :confirmed]) == true,
      recovery_ms: witness.recovery_ms,
      backlog_ms: witness.backlog_ms,
      history: witness.history,
      recovery: recovery(witness, ids)
    }
  end

  def report(witness, cleanup) do
    witness = Map.put(witness, :cleanup, cleanup)
    judged = judge(witness)

    evidence_complete =
      Enum.all?(judged.checks, fn {name, value} ->
        name == :indeterminate_without_receipt or value
      end)

    complete = evidence_complete and cleanup.confirmed

    Map.merge(judged, %{
      choices_digest: Elara.Lab.digest({witness.fault, witness.inputs, cleanup.choices}),
      completed_turns: terminal_count(witness.history),
      bounds: %{
        "recovery" => bound(complete, witness.recovery_ms, 5_000),
        "backlog" => bound(complete, witness.backlog_ms, backlog_limit(witness))
      },
      incomplete: if(complete, do: nil, else: "prerequisites_not_observed"),
      complete: complete,
      cleanup_confirmed: cleanup.confirmed,
      cleanup: cleanup,
      marker_count: length(witness.marker_bytes),
      fault: Atom.to_string(witness.fault),
      ordering: witness.ordering,
      death: witness.death,
      clocks: witness.clocks
    })
  end

  defp exact_identities?(witness) do
    users = Enum.filter(witness.history, &(&1["kind"] == "user"))
    accepted_ids = Enum.map(@labels, &witness.inputs[&1].accepted_id)

    Map.get(witness, :persisted_identity_valid, true) and
      accepted_ids == witness.accepted_order and
      Enum.with_index(@labels)
      |> Enum.all?(fn {label, index} ->
        input = witness.inputs[label]
        user = Enum.at(users, index)

        receipt_identity =
          case input.receipt do
            %{session_id: session_id, sender_id: "lab", kind: :normal, user_text: text}
            when is_binary(session_id) ->
              text == "input #{label}"

            _ ->
              not Map.has_key?(input.receipt || %{}, :session_id)
          end

        ((is_binary(input.accepted_id) and is_binary(input.persisted_user_id) and
            input.accepted_id != input.persisted_user_id and user) &&
           user["id"] == input.persisted_user_id) and user["text"] == "input #{label}" and
          receipt_identity
      end)
  end

  defp settled_receipts?(witness) do
    match?(%{state: :failed, error: error} when is_binary(error), witness.inputs["A"].receipt) and
      Enum.all?(["B", "C"], fn label ->
        match?(%{state: :consumed, error: nil}, witness.inputs[label].receipt)
      end)
  end

  defp settled_backlog?(witness) do
    Enum.all?(["B", "C"], fn label ->
      match?(%{state: :consumed, error: nil}, witness.inputs[label].receipt)
    end)
  end

  defp barrier?(witness) do
    ordering = witness.ordering
    expected_ids = [witness.inputs["B"].accepted_id, witness.inputs["C"].accepted_id]

    witness.backlog_count == 2 and ordering.backlog_ids == expected_ids and
      is_integer(ordering.arrived_at) and is_integer(ordering.monitor_installed_at) and
      is_integer(ordering.backlog_observed_at) and is_integer(ordering.released_at) and
      is_integer(ordering.injected_at) and is_integer(ordering.target_down_at) and
      get_in(witness, [:death, :at]) == ordering.target_down_at and
      get_in(witness, [:death, :target]) == ordering.target and
      ordering.monitor_installed_at <= ordering.arrived_at and
      ordering.arrived_at <= ordering.backlog_observed_at and
      ordering.backlog_observed_at <= ordering.released_at and
      ordering.released_at <= ordering.injected_at and
      ordering.injected_at <= ordering.target_down_at
  end

  defp timing_evidence?(witness) do
    expected_recovery_origin =
      if witness.fault == :tool_running, do: "immediately_before_reopen", else: "target_down"

    expected_backlog_origin =
      if witness.fault == :tool_running, do: "explicit_resume", else: "target_down"

    valid_clock?(witness.clocks.recovery, expected_recovery_origin) and
      valid_clock?(witness.clocks.backlog, expected_backlog_origin) and
      witness.recovery_ms == witness.clocks.recovery.ms and
      witness.backlog_ms == witness.clocks.backlog.ms
  end

  defp valid_clock?(
         %{origin: expected, origin_at: origin, endpoint_at: endpoint, ms: ms},
         expected
       ) do
    is_integer(origin) and is_integer(endpoint) and endpoint >= origin and ms == endpoint - origin
  end

  defp valid_clock?(_, _), do: false

  defp typed_uncertainty?(%{fault: :tool_running} = witness) do
    call_id = get_in(witness, [:inputs, "A", :call_id])

    Enum.any?(witness.history, fn
      %{
        "kind" => "tool_result",
        "call_id" => ^call_id,
        "name" => "lab_marker",
        "outcome" => %{"kind" => "indeterminate", "text" => text}
      }
      when is_binary(text) ->
        true

      _ ->
        false
    end)
  end

  defp typed_uncertainty?(witness),
    do: match?(%{state: :failed, error: error} when is_binary(error), witness.inputs["A"].receipt)

  defp accepted_fixture(witness) do
    Map.new(@labels, fn label ->
      {label, %{id: witness.inputs[label].accepted_id, text: "input #{label}"}}
    end)
  end

  defp expected_labels(:tool_running), do: @labels
  defp expected_labels(_), do: ["B", "C"]

  defp terminal_count(history) do
    Enum.count(history, fn
      %{"kind" => "assistant", "tool_calls" => [], "text" => text, "interrupted" => false}
      when is_binary(text) ->
        true

      _ ->
        false
    end)
  end

  defp recovery(witness, ids) do
    %{
      accepted_ids: ids,
      persisted_user_ids:
        Map.new(witness.inputs, fn {label, input} -> {label, input.persisted_user_id} end),
      receipts: Map.new(witness.inputs, fn {label, input} -> {label, input.receipt} end),
      tool_outcomes:
        Map.new(witness.inputs, fn {label, input} -> {label, input.tool_outcome} end),
      history_count: length(witness.history),
      marker_bytes: witness.marker_bytes,
      marker_labels: witness.marker_labels,
      fault: witness.fault,
      timing: witness.clocks
    }
  end

  defp backlog_limit(witness), do: 5_000 + witness.backlog_count * 1_000

  defp bound(false, _value, _limit), do: "undetermined"
  defp bound(true, value, limit) when value <= limit, do: "holds"
  defp bound(true, _value, _limit), do: "fails"
end
