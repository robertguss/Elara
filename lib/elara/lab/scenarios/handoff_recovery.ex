defmodule Elara.Lab.Scenarios.HandoffRecovery do
  @moduledoc "LAB-5 public handoff crashes with witnessed queued inputs and persisted recovery."
  @behaviour Elara.Lab

  alias Elara.Lab.{Gate, GatedScripted, InputObserver, Jobs, Tools}
  alias Elara.Lab.Scenarios.SessionRecovery
  alias Elara.Lab.Scenarios.SessionRecovery.{Coordinator, Deadline}
  alias Elara.Message.{Assistant, ToolCall, User}
  alias Elara.Session.{Handoff, Store}

  @stages ~w(prepared created transferred activated started)
  @hook "handoff-recovery"
  @gate_key {__MODULE__, :gate}
  @recovery_ms 5_000
  @backlog_ms 7_000

  def curve_fields, do: [{"recovery_ms", ["recovery_ms"]}, {"backlog_ms", ["backlog_ms"]}]

  def run(%{provider: :real}), do: raise("handoff_recovery uses only the scripted provider")

  def run(context) do
    stage = get_in(context, [:params, "stage"]) || "prepared"
    unless stage in @stages, do: raise(ArgumentError, "unknown handoff stage #{inspect(stage)}")
    schedule = schedule(context.seed, stage)
    cwd = Path.join(context.dir, "workspace")
    File.mkdir_p!(cwd)
    {:ok, coordinator} = Coordinator.start_link([])
    {:ok, gate} = Gate.start_link()
    Process.unlink(gate)
    {:ok, script} = Agent.start_link(fn -> script(schedule) end)
    Process.unlink(script)
    log = Elara.Lab.choice_log()

    try do
      :persistent_term.put(@gate_key, gate)
      exercise(context, schedule, cwd, coordinator, gate, script, log)
    after
      # Register cleanup before the first lifecycle wait; unexpected evidence
      # or report exceptions must not leave a held source/provider alive.
      try do
        if Process.alive?(coordinator),
          do: SessionRecovery.cleanup(coordinator, cwd, log, true)
      after
        try do
          if Process.alive?(gate), do: Gate.stop(gate)
        after
          if Process.alive?(script), do: stop(script)
          :persistent_term.erase(@gate_key)
        end
      end
    end
  end

  defp exercise(context, schedule, cwd, coordinator, gate, script, log) do
    result =
      try do
        flow(context, schedule, cwd, coordinator, gate, script)
      rescue
        error -> {:error, {:exception, Exception.message(error)}}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    # Capture evidence before cleanup changes any still-running workload.
    evidence = Coordinator.evidence(coordinator)
    events = Gate.snapshot(gate)
    source = Enum.find(events, &(&1.point == :source))
    observation = observe(coordinator, source, public_events(events))

    markers =
      call(coordinator, :markers, Jobs.now() + 1_000, fn ->
        case File.read(Path.join(cwd, "marks.txt")) do
          {:ok, text} -> String.split(text, "\n", trim: true)
          {:error, :enoent} -> []
        end
      end)

    # The fixture has only session-owned provider and marker tasks. Gate.stop
    # independently settles their monitored callers after stopping sessions.
    cleanup = SessionRecovery.cleanup(coordinator, cwd, log, true)
    gate_settled = Gate.stop(gate)
    script_settled = stop(script)

    cleanup =
      Map.put(cleanup, :confirmed, cleanup.confirmed and gate_settled and script_settled)
      |> Map.put(:gate_settled, gate_settled)
      |> Map.put(:script_settled, script_settled)

    report(schedule, result, evidence, events, observation, markers, cleanup)
    |> SessionRecovery.finalize()
  end

  def schedule(seed, stage) do
    rand = :rand.seed_s(:exsss, {seed, 1085, 5})
    {order, rand} = :rand.uniform_s(2, rand)
    {ttft, rand} = :rand.uniform_s(20, rand)
    {gap, _rand} = :rand.uniform_s(10, rand)

    %{
      seed: seed,
      stage: stage,
      order: if(order == 1, do: ["B", "C"], else: ["C", "B"]),
      ttft_ms: ttft,
      gap_ms: gap,
      late_observer: stage in ["activated", "started"] and rem(seed, 2) == 0
    }
  end

  defp flow(context, schedule, cwd, coordinator, gate, script) do
    deadline = Jobs.now() + @recovery_ms
    provider = {GatedScripted, %{script: script, gate: gate, input: attrs("A").user}}

    session =
      call!(coordinator, :start, deadline, fn ->
        Elara.start_session(
          cwd: cwd,
          home: cwd,
          skill_paths: [],
          plugins: [],
          provider: provider,
          tools: [%{Tools.marker() | run: {__MODULE__, :run_marker}}],
          context_limit: 100_000,
          max_tool_output_bytes: 1_024,
          max_iterations: 3,
          handoff_fault_hook: fn stage ->
            if stage == schedule.stage, do: Gate.hold(gate, :handoff_stage, %{stage: stage})
          end
        )
      end)

    :ok = Coordinator.transfer_session(coordinator, :start, session)
    source_pid = call!(coordinator, :source_pid, deadline, fn -> Elara.session_pid(session) end)
    :ok = Gate.subscribe(gate, session)
    expected = Map.new(["A", "B", "C"], &{&1, attrs(&1)})
    call!(coordinator, :submit, deadline, fn -> Elara.submit_input(session, attrs("A")) end)
    poll!(coordinator, :provider_gate, deadline, fn -> find_event(gate, :provider_ready) end)

    for label <- schedule.order do
      call!(coordinator, :submit, deadline, fn -> Elara.submit_input(session, attrs(label)) end)
    end

    source = call!(coordinator, :source_store, deadline, fn -> Handoff.store(session) end)
    Gate.note(gate, :source, %{path: source.path})

    backlog =
      poll!(coordinator, :backlog, deadline, fn ->
        with {:ok, view} <-
               InputObserver.read(source.path, expected, public_events(Gate.snapshot(gate))),
             true <-
               Enum.all?(schedule.order, fn label ->
                 input = view.inputs[label]

                 input.receipt != nil and input.receipt.state in [:accepted, :queued] and
                   input.user_entries == []
               end),
             do: view
      end)

    Gate.note(gate, :backlog, %{ids: Enum.map(schedule.order, &backlog.inputs[&1].accepted_id)})
    context.hook.({:backlog_witnessed, %{source_pid: source_pid, gate: gate}})
    :ok = Gate.release(gate, :provider_ready)

    point =
      poll!(coordinator, :handoff_gate, deadline, fn -> find_event(gate, :handoff_stage) end)

    if point.caller != source_pid, do: throw(:wrong_handoff_target)

    {source, activated} =
      call!(coordinator, :source_store, deadline, fn ->
        with {:ok, store} <- Store.open(source.path) do
          child = store.context["handoff"]["path"]

          activated =
            if File.exists?(child) do
              case Store.open(child) do
                {:ok, successor} -> successor.context["activated"]
                error -> error
              end
            else
              :absent
            end

          {store, activated}
        end
      end)

    Gate.note(gate, :persisted_fault_stage, %{
      stage: source.context["handoff"]["stage"],
      successor_activated: activated
    })

    successor = source.context["handoff"]["id"]
    expected = Map.put(expected, "H", continuation(session, successor))

    if schedule.late_observer do
      poll!(coordinator, :already_finished_successor, deadline, fn ->
        with {:ok, view} <-
               InputObserver.read(source.path, expected, public_events(Gate.snapshot(gate))),
             true <- Enum.all?(["H", "B", "C"], &view.inputs[&1].completed),
             do: view
      end)
    end

    :ok = Coordinator.observe_target(coordinator, source_pid)

    context.hook.(
      {:before_fault,
       %{source_pid: source_pid, gate: gate, stage: schedule.stage, successor: successor}}
    )

    Gate.note(gate, :injected, %{target: source_pid})
    Process.exit(source_pid, :kill)

    call!(coordinator, :target_down, Jobs.now() + @recovery_ms, fn ->
      Coordinator.await_down(coordinator, @recovery_ms)
    end)

    Gate.note(gate, :reopen)

    reopened =
      call!(coordinator, :reopen, Jobs.now() + @recovery_ms, fn ->
        Elara.start_session(resume: source.path, provider: provider, pause_inputs: true)
      end)

    :ok = Coordinator.transfer_session(coordinator, :reopen, reopened)
    origin = find_event(gate, :reopen).at

    poll!(coordinator, :recovery, origin + @recovery_ms, fn ->
      with {:ok, view} <-
             InputObserver.read(source.path, expected, public_events(Gate.snapshot(gate))),
           true <-
             Enum.all?(view.inputs, fn {_label, input} ->
               input.terminal or input.state == :paused
             end),
           true <- Enum.all?(view.checks, fn {_name, passed} -> passed end),
           do: view
    end)

    Gate.note(gate, :recovered)
    Gate.note(gate, :resume)
    call!(coordinator, :resume, origin + @backlog_ms, fn -> Elara.resume_inputs(reopened) end)

    settled =
      poll!(coordinator, :settlement, origin + @backlog_ms, fn ->
        with {:ok, view} <-
               InputObserver.read(source.path, expected, public_events(Gate.snapshot(gate))),
             true <- view.all_terminal,
             do: view
      end)

    Gate.note(gate, :settled)
    {:ok, settled}
  end

  defp observe(_coordinator, nil, _events), do: {:error, :source_not_created}

  defp observe(coordinator, source, events) do
    call(coordinator, :observation, Jobs.now() + 1_000, fn ->
      with {:ok, store} <- Store.open(source.details.path) do
        expected = Map.new(["A", "B", "C"], &{&1, attrs(&1)})

        expected =
          case store.context["handoff"] do
            %{"id" => successor} -> Map.put(expected, "H", continuation(store.id, successor))
            _ -> expected
          end

        InputObserver.read(store.path, expected, events)
      end
    end)
  end

  defp report(schedule, result, evidence, events, observation, markers, cleanup) do
    view =
      case observation do
        {:ok, {:ok, view}} -> view
        _ -> nil
      end

    event = fn point -> Enum.find(events, &(&1.point == point)) end
    stage = event.(:handoff_stage)
    backlog = event.(:backlog)
    injection = event.(:injected)
    checkpoint = event.(:persisted_fault_stage)
    recovery = duration(event.(:reopen), event.(:recovered))
    drain = duration(event.(:reopen), event.(:settled))

    checkpoint_matches =
      case {schedule.stage, checkpoint && checkpoint.details} do
        {"prepared", %{stage: "prepared", successor_activated: :absent}} -> true
        {"created", %{stage: "created", successor_activated: false}} -> true
        {"transferred", %{stage: "transferred", successor_activated: false}} -> true
        {"activated", %{stage: "transferred", successor_activated: true}} -> true
        {"started", %{stage: "started", successor_activated: true}} -> true
        _ -> false
      end

    fault =
      stage != nil and injection != nil and stage.caller == injection.details.target and
        stage.at <= injection.at and stage.monitor_installed_at <= injection.at and
        stage.details.stage == schedule.stage and stage.released_at == nil and
        Enum.count(events, &(&1.point == :injected)) == 1

    death =
      evidence.death.matched and evidence.death.reason == :killed and
        stage != nil and injection != nil and evidence.death.target == inspect(stage.caller) and
        evidence.death.at >= injection.at and is_integer(stage.down_at) and
        stage.down_at >= injection.at and stage.reason == :killed

    checks =
      Map.merge(if(view, do: view.checks, else: %{}), %{
        fault_witnessed: fault == true,
        fault_checkpoint_persisted:
          checkpoint_matches and injection != nil and
            checkpoint.at <= injection.at,
        target_down_witnessed: death,
        backlog_before_fault:
          backlog != nil and injection != nil and stage != nil and backlog.at <= stage.at and
            length(backlog.details.ids) == 2,
        persisted_observation: view != nil,
        files_openable: view != nil,
        source_terminal: view != nil and view.inputs["A"].state in [:failed, :interrupted],
        continuation_and_backlog_completed:
          view != nil and Map.has_key?(view.inputs, "H") and
            Enum.all?(["H", "B", "C"], &view.inputs[&1].completed),
        physical_markers_once: markers == {:ok, ["A" | schedule.order]},
        recovery_bounded: is_integer(recovery) and recovery <= @recovery_ms,
        backlog_bounded: is_integer(drain) and drain <= @backlog_ms
      })

    %{
      checks: checks,
      complete:
        fault == true and death and checks.backlog_before_fault and
          checks.fault_checkpoint_persisted and
          view != nil and cleanup.confirmed,
      error:
        case result do
          {:ok, _} -> nil
          {:error, reason} -> reason
        end,
      schedule: schedule,
      choices_digest: Elara.Lab.digest(schedule),
      recovery_ms: recovery,
      backlog_ms: drain,
      bounds: %{recovery_ms: @recovery_ms, backlog_ms: @backlog_ms},
      ordering: events,
      death: evidence.death,
      observation: view,
      observation_error: if(view == nil, do: observation, else: nil),
      marker_labels:
        case markers do
          {:ok, labels} -> labels
          _ -> nil
        end,
      cleanup: cleanup,
      cleanup_confirmed: cleanup.confirmed
    }
  end

  defp attrs(label),
    do: %{
      id: "handoff-#{label}",
      sender_id: "lab",
      kind: :normal,
      user: %User{text: "input #{label}"},
      terminal_text: "done #{label}"
    }

  defp continuation(source, successor),
    do: %{
      id: "handoff:" <> successor,
      sender_id: source,
      kind: :agent,
      terminal_text: "continued A",
      user: %User{
        text:
          "Continue the unfinished work indexed by the assistant-authored handoff. " <>
            "Read original evidence before acting; later owner corrections take precedence. Do not replay uncertain effects.",
        agent_source: %{
          "sender" => source,
          "recipient" => successor,
          "message_id" => "handoff:" <> successor
        }
      }
    }

  defp script(schedule) do
    first = %Assistant{text: String.duplicate("x", 60_000), tool_calls: [marker("A")]}

    [
      stream(schedule, first),
      stream(schedule, %Assistant{text: "continued A"})
      | Enum.flat_map(schedule.order, fn label ->
          [
            stream(schedule, %Assistant{tool_calls: [marker(label)]}),
            stream(schedule, %Assistant{text: "done #{label}"})
          ]
        end)
    ]
  end

  defp marker(label),
    do: %ToolCall{
      id: "marker-#{label}",
      name: "lab_marker",
      args: {:ok, %{"path" => "marks.txt", "label" => label, "hook" => @hook, "key" => label}}
    }

  @doc false
  def run_marker(args, ctx) do
    gate = :persistent_term.get(@gate_key)
    :ok = Gate.observe(gate, :marker_task, %{key: args["key"]})
    Tools.run_marker(args, ctx)
  end

  defp stream(schedule, answer) do
    text = if is_binary(answer.text), do: [answer.text], else: []
    steps = [{:sleep, schedule.ttft_ms}] ++ text ++ [{:sleep, schedule.gap_ms}]
    {:stream, steps, {:ok, answer}}
  end

  defp duration(nil, _), do: nil
  defp duration(_, nil), do: nil
  defp duration(from, to), do: to.at - from.at

  defp find_event(gate, point), do: Enum.find(Gate.snapshot(gate), &(&1.point == point))

  defp public_events(events),
    do:
      for(
        event <- events,
        event.point == :public_event,
        do: Map.put(event.details, :at, event.at)
      )

  defp poll!(coordinator, operation, deadline, fun) do
    value = call!(coordinator, operation, deadline, fun)

    cond do
      is_map(value) ->
        value

      Jobs.now() >= deadline ->
        throw({:timeout, operation})

      true ->
        Process.sleep(5)
        poll!(coordinator, operation, deadline, fun)
    end
  end

  defp call!(coordinator, operation, deadline, fun) do
    case call(coordinator, operation, deadline, fun) do
      {:ok, {:ok, result}} -> result
      {:ok, {:error, reason}} -> throw({operation, reason})
      {:ok, value} -> value
      {:error, reason} -> throw({operation, reason})
    end
  end

  defp call(coordinator, operation, deadline, fun),
    do: Deadline.call(coordinator, operation, deadline, fun)

  defp stop(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> true
    after
      1_000 -> false
    end
  end
end
