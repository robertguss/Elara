defmodule Elara.Lab.Scenarios.ChildRecovery do
  @moduledoc "LAB-5 same-VM child recovery with durable input, capacity and uncertainty evidence."
  @behaviour Elara.Lab

  alias Elara.Lab.{Gate, InputObserver, Jobs, Tools}
  alias Elara.Lab.Scenarios.SessionRecovery
  alias Elara.Lab.Scenarios.SessionRecovery.{Coordinator, Deadline}
  alias Elara.Message.{Assistant, ToolResult, User}
  alias Elara.Session.{Handoff, Store}
  alias Elara.Threads

  @stages ~w(parent_delegated child_provider child_marker)
  @key {__MODULE__, :fixture}
  @recovery_ms 5_000
  # Two queued inputs, up to two report turns/remaining child work, at most 1s each.
  @backlog_ms 9_000

  def curve_fields, do: [{"recovery_ms", ["recovery_ms"]}, {"backlog_ms", ["backlog_ms"]}]
  def run(%{provider: :real}), do: raise("child_recovery uses only the lab provider")

  def run(context) do
    stage = get_in(context, [:params, "stage"]) || "parent_delegated"
    unless stage in @stages, do: raise(ArgumentError, "unknown child stage #{inspect(stage)}")
    schedule = schedule(context.seed, stage)
    cwd = Path.join(context.dir, "workspace")
    File.mkdir_p!(cwd)
    git!(cwd, ["init", "--quiet"])
    git!(cwd, ["config", "core.hooksPath", "/dev/null"])
    git!(cwd, ["config", "commit.gpgsign", "false"])

    git!(cwd, [
      "-c",
      "user.name=Lab",
      "-c",
      "user.email=lab@invalid",
      "commit",
      "--quiet",
      "--allow-empty",
      "-m",
      "fixture"
    ])

    {:ok, coordinator} = Coordinator.start_link([])
    {:ok, parent_gate} = Gate.start_link()
    {:ok, child_gate} = Gate.start_link()
    Enum.each([parent_gate, child_gate], &Process.unlink/1)

    config = %{
      parent_gate: parent_gate,
      child_gate: child_gate,
      schedule: schedule,
      coordinator: coordinator
    }

    log = Elara.Lab.choice_log()

    try do
      :persistent_term.put(@key, config)
      execute(context, cwd, config, log)
    after
      # Installed before any lifecycle wait. A missing serial barrier cannot be
      # reported as clean: the runner retains that root and stops repetitions.
      try do
        if Process.alive?(coordinator), do: cleanup(config, cwd, log)
      after
        :persistent_term.erase(@key)
        :persistent_term.erase({@key, :parent})
      end
    end
  end

  def schedule(seed, stage) do
    rand = :rand.seed_s(:exsss, {seed, 1085, 7})
    {order, rand} = :rand.uniform_s(2, rand)
    {work, _} = :rand.uniform_s(20, rand)

    %{
      seed: seed,
      stage: stage,
      order: if(order == 1, do: ["B", "C"], else: ["C", "B"]),
      ttft_ms: work
    }
  end

  defp execute(context, cwd, config, log) do
    result =
      try do
        flow(context, cwd, config)
      rescue
        error -> {:error, {:exception, Exception.message(error)}}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    events = events(config)
    evidence = Coordinator.evidence(config.coordinator)

    observations =
      case call(config.coordinator, :observation, Jobs.now() + 1_000, fn ->
             observe(config, events)
           end) do
        {:ok, value} -> value
        error -> error
      end

    child = event(events, :child)
    markers = if child, do: read_marks(child.details.cwd), else: {:error, :no_child}

    records =
      call(config.coordinator, :records, Jobs.now() + 1_000, fn ->
        if event(events, :parent),
          do: Threads.list(event(events, :parent).details.id).children,
          else: []
      end)

    after_capacity = Registry.count(Elara.ThreadSlots)
    cleanup = cleanup(config, cwd, log)

    report(
      config.schedule,
      result,
      events,
      evidence,
      observations,
      markers,
      records,
      after_capacity,
      cleanup
    )
    |> SessionRecovery.finalize()
  end

  defp flow(context, cwd, config) do
    co = config.coordinator
    pg = config.parent_gate
    cg = config.child_gate
    deadline = Jobs.now() + @recovery_ms
    baseline = Registry.count(Elara.ThreadSlots)
    provider = {Elara.Lab.ChildProvider, config}

    tools = [
      %{Threads.tool() | run: {__MODULE__, :delegate}},
      %{Tools.marker() | run: {__MODULE__, :run_marker}}
    ]

    parent =
      call!(co, :start, deadline, fn ->
        Elara.start_session(
          cwd: cwd,
          home: cwd,
          skill_paths: [],
          plugins: [],
          provider: provider,
          tools: tools,
          context_limit: 100_000,
          max_tool_output_bytes: 1_024,
          max_iterations: 3,
          effect_executor: nil
        )
      end)

    :ok = Coordinator.transfer_session(co, :start, parent)
    :persistent_term.put({@key, :parent}, parent)
    parent_pid = call!(co, :parent_pid, deadline, fn -> Elara.session_pid(parent) end)
    parent_store = call!(co, :parent_store, deadline, fn -> Handoff.store(parent) end)

    Gate.note(pg, :parent, %{
      id: parent,
      pid: parent_pid,
      path: parent_store.path,
      baseline_capacity: baseline
    })

    :ok = Gate.subscribe(pg, parent)
    call!(co, :submit, deadline, fn -> Elara.submit_input(parent, normal("parent", "A")) end)
    poll!(co, :parent_provider, deadline, fn -> event(Gate.snapshot(pg), :provider_ready) end)

    if config.schedule.stage == "parent_delegated" do
      queue(co, parent, "parent", config.schedule.order, deadline)
      backlog = witness_queue!(co, parent_store.path, parent_expected(config.schedule), deadline)
      Gate.note(pg, :backlog, %{ids: Enum.map(["B", "C"], &backlog.inputs[&1].accepted_id)})
    end

    :ok = Gate.release(pg, :provider_ready)

    delegation =
      poll!(co, :delegation, deadline, fn -> event(Gate.snapshot(pg), :child_created) end)

    child = delegation.details.id
    child_record = call!(co, :child_record, deadline, fn -> Threads.record(child) end)
    child_pid = call!(co, :child_pid, deadline, fn -> Elara.session_pid(child) end)

    Gate.note(cg, :child, %{
      id: child,
      parent: parent,
      pid: child_pid,
      path: child_record["session_path"],
      cwd: child_record["cwd"]
    })

    :ok = Gate.subscribe(cg, child)
    poll!(co, :child_provider, deadline, fn -> event(Gate.snapshot(cg), :provider_ready) end)

    if config.schedule.stage != "parent_delegated" do
      queue(co, child, "child", config.schedule.order, deadline)

      backlog =
        witness_queue!(
          co,
          child_record["session_path"],
          child_expected(parent, child, config.schedule),
          deadline
        )

      Gate.note(pg, :backlog, %{ids: Enum.map(["B", "C"], &backlog.inputs[&1].accepted_id)})

      :ok = Gate.release(pg, :child_created)

      poll!(co, :parent_finished, deadline, fn ->
        with {:ok, view} <-
               InputObserver.read(parent_store.path, parent_expected(config.schedule)),
             true <- view.all_completed,
             do: view
      end)
    end

    {target_id, target_pid, target_path, point, gate} =
      case config.schedule.stage do
        "parent_delegated" ->
          {parent, parent_pid, parent_store.path, delegation, pg}

        "child_provider" ->
          {child, child_pid, child_record["session_path"],
           event(Gate.snapshot(cg), :provider_ready), cg}

        "child_marker" ->
          :ok = Gate.release(cg, :provider_ready)
          marker = poll!(co, :marker, deadline, fn -> event(Gate.snapshot(cg), :child_marker) end)
          {child, child_pid, child_record["session_path"], marker, cg}
      end

    checkpoint = call!(co, :checkpoint, deadline, fn -> Store.open(target_path) end)
    monitors = Process.info(target_pid, :monitors)
    held = event(Gate.snapshot(gate), point.point)

    pending =
      for %Store.Entry{message: %Assistant{tool_calls: calls}} <- checkpoint.entries,
          call <- calls,
          not Enum.any?(
            checkpoint.entries,
            &match?(%Store.Entry{message: %ToolResult{call_id: id}} when id == call.id, &1)
          ),
          do: call.id

    Gate.note(pg, :checkpoint, %{
      target: target_pid,
      id: target_id,
      active: checkpoint.active_input_id,
      owner: held.details.owner,
      caller: held.caller,
      held: held.released_at == nil,
      caller_alive: Process.alive?(held.caller),
      monitors: monitors,
      pending_calls: pending,
      history: Enum.map(checkpoint.entries, &Store.encode_message(&1.message)),
      owns_caller:
        match?({:monitors, _}, monitors) and
          Enum.member?(elem(monitors, 1), {:process, held.caller}),
      capacity: Registry.count(Elara.ThreadSlots),
      child_slots: Registry.keys(Elara.ThreadSlots, child_pid),
      parent_record: child_record["parent_id"]
    })

    context.hook.(
      {:before_fault,
       %{
         target: target_pid,
         gates: [pg, cg],
         session_pids: [parent_pid, child_pid],
         point: point.point
       }}
    )

    latest = event(Gate.snapshot(gate), point.point)
    if latest.released_at != nil, do: throw(:released_before_fault)
    if not Process.alive?(latest.caller), do: throw(:callback_down_before_fault)
    :ok = Coordinator.observe_target(co, target_pid)
    ref = Process.monitor(target_pid)

    try do
      if not Process.alive?(target_pid), do: throw(:premature_target_death)
      Gate.note(pg, :injected, %{target: target_pid, ref: ref, monitor_installed_at: Jobs.now()})
      Process.exit(target_pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^target_pid, reason} ->
          Gate.note(pg, :target_down, %{target: target_pid, ref: ref, reason: reason})
      after
        @recovery_ms -> throw(:target_down_timeout)
      end

      call!(co, :target_down, Jobs.now() + @recovery_ms, fn ->
        Coordinator.await_down(co, @recovery_ms)
      end)
    after
      Process.demonitor(ref, [:flush])
    end

    Gate.note(pg, :reopen)
    origin = event(Gate.snapshot(pg), :reopen).at

    reopened =
      call!(co, :reopen, origin + @recovery_ms, fn ->
        if config.schedule.stage == "parent_delegated",
          do:
            Elara.start_session(
              resume: target_path,
              cwd: checkpoint.cwd,
              home: cwd,
              skill_paths: [],
              plugins: [],
              provider: provider,
              tools: tools,
              effect_executor: nil,
              pause_inputs: true
            ),
          else:
            Threads.resume(child,
              cwd: checkpoint.cwd,
              home: cwd,
              skill_paths: [],
              plugins: [],
              provider: provider,
              tools: tools,
              effect_executor: nil,
              pause_inputs: true
            )
      end)

    :ok = Coordinator.transfer_session(co, :reopen, reopened)

    expected =
      if target_id == parent,
        do: parent_expected(config.schedule),
        else: child_expected(parent, child, config.schedule)

    poll!(co, :recovered, origin + @recovery_ms, fn ->
      with {:ok, view} <- InputObserver.read(target_path, expected),
           true <- Enum.all?(view.checks, fn {_, ok} -> ok end),
           true <- Enum.all?(view.inputs, fn {_, i} -> i.terminal or i.state == :paused end),
           do: view
    end)

    Gate.note(pg, :recovered)

    # Release only the old admitted callback, after the witnessed target death.
    if config.schedule.stage == "parent_delegated", do: Gate.release(pg, :child_created)
    if config.schedule.stage != "child_marker", do: Gate.release(cg, :provider_ready)
    call!(co, :resume, origin + @backlog_ms, fn -> Elara.resume_inputs(reopened) end)

    if config.schedule.stage == "parent_delegated" do
      poll!(co, :child_marker, origin + @backlog_ms, fn ->
        event(Gate.snapshot(cg), :child_marker)
      end)
    end

    if config.schedule.stage != "child_provider", do: Gate.release(cg, :child_marker)

    settled =
      poll!(co, :settled, origin + @backlog_ms, fn ->
        case observe(config, events(config)) do
          {:ok, %{parent: parent_view, child: child_view} = views}
          when parent_view.all_terminal and child_view.all_terminal ->
            views

          _ ->
            nil
        end
      end)

    if config.schedule.stage == "child_marker" do
      blocked =
        call(co, :before_ack, origin + @backlog_ms, fn -> Threads.integrate(parent, child) end)

      review =
        call!(co, :review, origin + @backlog_ms, fn -> Threads.review_child(parent, child) end)

      acknowledgment =
        call!(co, :acknowledge, origin + @backlog_ms, fn ->
          Threads.acknowledge_child(parent, child, review.digest, review.call_ids)
        end)

      integrated =
        call!(co, :integrate, origin + @backlog_ms, fn -> Threads.integrate(parent, child) end)

      Gate.note(pg, :acknowledgment, %{
        call_ids: review.call_ids,
        digest: review.digest,
        receipt: acknowledgment,
        blocked_before_ack: blocked == {:ok, {:error, :indeterminate_effects_preserved}},
        integrated_after_ack: is_map(integrated)
      })
    end

    poll!(co, :capacity, origin + @backlog_ms, fn ->
      if Registry.count(Elara.ThreadSlots) == 0, do: %{released: true}
    end)

    Gate.note(pg, :settled)
    {:ok, settled}
  end

  @doc false
  def delegate(args, ctx) do
    config = :persistent_term.get(@key)
    :ok = Gate.observe(config.parent_gate, :delegate_task, %{owner: ctx.session_id})
    result = Threads.run(args, ctx)
    # The public call has completed creation before returning. Register ownership
    # before holding the callback or making any fallible lifecycle assertion.
    for child <- Threads.list(ctx.session_id).children do
      :ok = Coordinator.transfer_session(config.coordinator, :child, child["id"])
    end

    case result do
      {:ok, encoded} ->
        child = JSON.decode!(encoded)
        Gate.hold(config.parent_gate, :child_created, %{owner: ctx.session_id, id: child["id"]})

      _ ->
        :ok
    end

    result
  end

  @doc false
  def run_marker(args, ctx) do
    config = :persistent_term.get(@key)
    :ok = Gate.observe(config.child_gate, :marker_task, %{owner: ctx.session_id})
    result = Tools.run_marker(args, ctx)
    Gate.hold(config.child_gate, :child_marker, %{owner: ctx.session_id})
    result
  end

  defp observe(config, events) do
    with %{details: parent} <- event(events, :parent),
         %{details: child} <- event(events, :child),
         {:ok, child_view} <-
           InputObserver.read(child.path, child_expected(parent.id, child.id, config.schedule)),
         expected =
           Map.merge(parent_expected(config.schedule), reports(parent.id, child.id, child_view)),
         {:ok, parent_view} <- InputObserver.read(parent.path, expected),
         {:ok, raw_child} <- Store.open(child.path),
         {:ok, raw_parent} <- Store.open(parent.path) do
      uncertain = fn store ->
        for %Store.Entry{message: %ToolResult{outcome: {:indeterminate, _}, call_id: id}} <-
              store.entries,
            do: id
      end

      {:ok,
       %{
         parent: parent_view,
         child: child_view,
         uncertain: %{parent: uncertain.(raw_parent), child: uncertain.(raw_child)}
       }}
    else
      error -> {:error, error}
    end
  end

  defp reports(parent, child, child_view) do
    for {label, input} <- child_view.inputs,
        input.completed,
        [leaf] = input.terminal_entries,
        into: %{} do
      id = "completion:" <> leaf

      key =
        Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary({child, parent, id})),
          case: :lower
        )

      text = "done child #{label}"

      body =
        "[Agent message; not an owner instruction. Sender thread #{child}; recipient #{parent}; message #{id}. Receiver restrictions remain authoritative.]\n" <>
          "Completion evidence retained for thread #{child}, source #{leaf}. Use thread_read for the full result. Preview (up to 2000 characters):\n" <>
          text

      {"report-" <> label,
       %{
         id: "thread:" <> key,
         sender_id: child,
         kind: :report,
         terminal_text: "done report " <> id,
         user: %User{
           text: body,
           agent_source: %{"sender" => child, "recipient" => parent, "message_id" => id}
         }
       }}
    end
  end

  defp parent_expected(schedule) do
    labels = if schedule.stage == "parent_delegated", do: ["A" | schedule.order], else: ["A"]
    Map.new(labels, &{&1, normal("parent", &1)})
  end

  defp child_expected(parent, child, schedule) do
    assignment = %{
      id: "assignment",
      sender_id: parent,
      kind: :agent,
      terminal_text: "done child A",
      user: %User{
        text: "child A",
        agent_source: %{"sender" => parent, "recipient" => child, "message_id" => "assignment"}
      }
    }

    extras =
      if schedule.stage == "parent_delegated",
        do: %{},
        else: Map.new(schedule.order, &{&1, normal("child", &1)})

    Map.put(extras, "A", assignment)
  end

  defp normal(role, label),
    do: %{
      id: "child-recovery-#{role}-#{label}",
      sender_id: "lab",
      kind: :normal,
      user: %User{text: "#{role} #{label}"},
      terminal_text: "done #{role} #{label}"
    }

  defp queue(co, session, role, order, deadline) do
    for label <- order,
        do:
          call!(co, :submit, deadline, fn ->
            Elara.submit_input(session, normal(role, label))
          end)
  end

  defp witness_queue!(co, path, expected, deadline) do
    poll!(co, :backlog, deadline, fn ->
      with {:ok, view} <- InputObserver.read(path, expected),
           true <- Enum.all?(view.checks, fn {_, ok} -> ok end),
           true <-
             Enum.all?(["B", "C"], fn label ->
               i = view.inputs[label]

               i.receipt != nil and i.receipt.state in [:accepted, :queued] and
                 i.user_entries == []
             end),
           do: view
    end)
  end

  defp cleanup(config, cwd, log) do
    gates =
      Enum.map([config.parent_gate, config.child_gate], fn gate ->
        if Process.alive?(gate), do: Gate.stop(gate), else: true
      end)

    # Stop admitted creators first, then serialize with the durable delegation
    # actor so a dispatched creation cannot appear after a false clean snapshot.
    parent = config_parent()

    barrier =
      call(config.coordinator, :threads_barrier, Jobs.now() + 2_000, fn ->
        if parent, do: Threads.list(parent).children, else: []
      end)

    case barrier do
      {:ok, children} when is_list(children) ->
        Enum.each(children, &Coordinator.transfer_session(config.coordinator, :child, &1["id"]))

      _ ->
        :ok
    end

    cleanup = SessionRecovery.cleanup(config.coordinator, cwd, log, true)
    capacity = Registry.count(Elara.ThreadSlots)

    Map.merge(cleanup, %{
      confirmed:
        cleanup.confirmed and Enum.all?(gates) and
          match?({:ok, children} when is_list(children), barrier) and capacity == 0,
      gates_settled: gates,
      threads_barrier: barrier,
      after_capacity: capacity
    })
  end

  defp config_parent do
    # The record survives Gate.stop; ownership is also in the coordinator.
    :persistent_term.get({@key, :parent}, nil)
  end

  defp report(
         schedule,
         result,
         events,
         evidence,
         observation,
         markers,
         records,
         capacity,
         cleanup
       ) do
    views =
      case observation do
        {:ok, views} -> views
        _ -> nil
      end

    checkpoint = event(events, :checkpoint)
    injection = event(events, :injected)
    direct_down = event(events, :target_down)
    recovered = duration(event(events, :reopen), event(events, :recovered))
    settled = duration(event(events, :reopen), event(events, :settled))
    parent = event(events, :parent)
    child = event(events, :child)
    ack = event(events, :acknowledgment)
    backlog = event(events, :backlog)

    children_count =
      case records do
        {:ok, children} when is_list(children) -> length(children)
        _ -> nil
      end

    pending =
      case schedule.stage do
        "parent_delegated" -> ["delegate-A"]
        "child_provider" -> []
        "child_marker" -> ["child-marker-A"]
      end

    target_attrs =
      if schedule.stage == "parent_delegated",
        do: normal("parent", "A"),
        else: %{id: "assignment"}

    target_point =
      case schedule.stage do
        "parent_delegated" ->
          event(events, :child_created)

        "child_provider" ->
          Enum.find(
            events,
            &(&1.point == :provider_ready and &1.details.owner == (child && child.details.id))
          )

        "child_marker" ->
          event(events, :child_marker)
      end

    fault =
      checkpoint != nil and injection != nil and target_point != nil and
        checkpoint.details.id == checkpoint.details.owner and
        checkpoint.details.active == target_attrs.id and checkpoint.details.held and
        checkpoint.details.caller_alive and checkpoint.details.owns_caller and
        checkpoint.details.pending_calls == pending and
        (target_point.released_at == nil or target_point.released_at >= injection.at) and
        target_point.at <= injection.at and target_point.monitor_installed_at <= injection.at and
        checkpoint.at <= injection.at and Enum.count(events, &(&1.point == :injected)) == 1

    death =
      injection != nil and direct_down != nil and evidence.death.matched and
        evidence.death.reason == :killed and direct_down.details.reason == :killed and
        direct_down.details.target == injection.details.target and
        direct_down.details.ref == injection.details.ref and
        evidence.death.target == inspect(injection.details.target) and
        evidence.ordering.monitor_installed_at <= injection.at and
        evidence.death.at >= injection.at and direct_down.at >= injection.at

    uncertain =
      if views do
        if schedule.stage == "parent_delegated",
          do: views.uncertain.parent,
          else: views.uncertain.child
      else
        []
      end

    expected_uncertain =
      case schedule.stage do
        "parent_delegated" -> ["delegate-A"]
        "child_provider" -> []
        "child_marker" -> ["child-marker-A"]
      end

    checks = %{
      fault_witnessed: fault == true,
      target_down_witnessed: death == true,
      backlog_before_fault:
        backlog != nil and injection != nil and
          length(backlog.details.ids) == 2 and backlog.at <= injection.at,
      files_openable: views != nil,
      input_identities:
        views != nil and
          Enum.all?([views.parent, views.child], fn v ->
            Enum.all?(v.checks, fn {_, ok} -> ok end)
          end),
      all_inputs_terminal:
        views != nil and views.parent.all_terminal and views.child.all_terminal,
      fault_input_not_successful:
        views != nil and
          if(schedule.stage == "parent_delegated",
            do: views.parent.inputs["A"],
            else: views.child.inputs["A"]
          ).state == :failed,
      child_once: children_count == 1,
      parent_link:
        parent != nil and child != nil and checkpoint != nil and views != nil and
          checkpoint.details.parent_record == parent.details.id and
          hd(views.child.stores).parent_session == parent.details.id,
      capacity_owned:
        parent != nil and checkpoint != nil and parent.details.baseline_capacity == 0 and
          checkpoint.details.capacity == 1 and checkpoint.details.child_slots != [],
      capacity_released: capacity == 0,
      markers_once: markers == {:ok, if(schedule.stage == "child_provider", do: [], else: ["A"])},
      uncertainty_preserved: uncertain == expected_uncertain,
      scoped_acknowledgment:
        if(schedule.stage == "child_marker",
          do:
            ack != nil and
              ack.details.call_ids == uncertain and ack.details.blocked_before_ack and
              ack.details.integrated_after_ack,
          else: true
        ),
      recovery_bounded: is_integer(recovered) and recovered <= @recovery_ms,
      backlog_bounded: is_integer(settled) and settled <= @backlog_ms
    }

    %{
      checks: checks,
      complete:
        fault == true and death == true and views != nil and
          is_integer(children_count) and cleanup.confirmed,
      error:
        case result do
          {:ok, _} -> nil
          {:error, error} -> error
        end,
      schedule: schedule,
      choices_digest: Elara.Lab.digest(schedule),
      ordering: events,
      death: evidence.death,
      parent_observation: views && views.parent,
      child_observation: views && views.child,
      observation_error: if(views, do: nil, else: observation),
      uncertain_call_ids: uncertain,
      acknowledgment: ack && ack.details,
      marker_labels: markers,
      children_created: children_count,
      children_observation: records,
      capacity: %{
        before: checkpoint && checkpoint.details.capacity,
        after: capacity,
        after_cleanup: cleanup.after_capacity
      },
      recovery_ms: recovered,
      backlog_ms: settled,
      bounds: %{recovery_ms: @recovery_ms, backlog_ms: @backlog_ms},
      cleanup: cleanup,
      cleanup_confirmed: cleanup.confirmed
    }
  end

  defp read_marks(cwd) do
    case File.read(Path.join(cwd, "marks.txt")) do
      {:ok, text} -> {:ok, String.split(text, "\n", trim: true)}
      {:error, :enoent} -> {:ok, []}
      error -> error
    end
  end

  defp events(config), do: Gate.snapshot(config.parent_gate) ++ Gate.snapshot(config.child_gate)
  defp event(events, point), do: Enum.find(events, &(&1.point == point))
  defp duration(nil, _), do: nil
  defp duration(_, nil), do: nil
  defp duration(a, b), do: b.at - a.at

  defp poll!(co, op, deadline, fun) do
    case call!(co, op, deadline, fun) do
      value when is_map(value) ->
        value

      _ ->
        if Jobs.now() >= deadline,
          do: throw({:timeout, op}),
          else:
            (
              Process.sleep(5)
              poll!(co, op, deadline, fun)
            )
    end
  end

  defp call!(co, op, deadline, fun) do
    case call(co, op, deadline, fun) do
      {:ok, {:ok, value}} -> value
      {:ok, {:error, error}} -> throw({op, error})
      {:ok, value} -> value
      {:error, error} -> throw({op, error})
    end
  end

  defp call(co, op, deadline, fun), do: Deadline.call(co, op, deadline, fun)

  defp git!(cwd, args) do
    {output, status} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    if status != 0, do: raise("fixture git failed: #{output}")
  end
end

defmodule Elara.Lab.ChildProvider do
  @moduledoc "Stateless scripted replies for the declared same-VM child fixture."
  @behaviour Elara.Provider
  alias Elara.Lab.Gate
  alias Elara.Message.{User, ToolCall}

  def chat(config, request), do: stream(config, request, fn _ -> :ok end)

  def stream(config, request, sink) do
    user = Enum.find(Enum.reverse(request.messages), &is_struct(&1, User))
    # Provider requests annotate agent-authored text. Match the durable
    # assignment identity, not that presentation prefix.
    input =
      if user.agent_source && user.agent_source["message_id"] == "assignment",
        do: "child A",
        else: user.text

    child = String.starts_with?(input, "child ")
    gate = if child, do: config.child_gate, else: config.parent_gate
    owner = user.agent_source && user.agent_source["recipient"]

    :ok =
      Gate.observe(gate, :provider_task, %{
        user: Elara.Session.Store.encode_message(user),
        owner: owner
      })

    if List.last(request.messages) == user and input in ["parent A", "child A"],
      do: Gate.hold(gate, :provider_ready, %{owner: owner})

    Process.sleep(config.schedule.ttft_ms)

    {text, calls} =
      cond do
        user.agent_source && String.starts_with?(user.agent_source["message_id"], "completion:") ->
          {"done report " <> user.agent_source["message_id"], []}

        List.last(request.messages) == user and input == "parent A" ->
          {"",
           [
             %ToolCall{
               id: "delegate-A",
               name: "start_child",
               args: {:ok, %{"assignment" => "child A", "coding" => true}}
             }
           ]}

        List.last(request.messages) == user and input == "child A" ->
          {"",
           [
             %ToolCall{
               id: "child-marker-A",
               name: "lab_marker",
               args:
                 {:ok,
                  %{
                    "path" => "marks.txt",
                    "label" => "A",
                    "hook" => "child-recovery",
                    "key" => "A"
                  }}
             }
           ]}

        input in ["parent A", "parent B", "parent C", "child A", "child B", "child C"] ->
          {"done " <> input, []}

        true ->
          raise "unknown child fixture input"
      end

    {:ok, answer} = Elara.Message.assistant(text, calls)
    sink.(text)
    {:ok, answer, config}
  end
end
