defmodule Elara.Lab.Scenarios.Concurrency do
  @moduledoc """
  RQ-2 reference workload (note 003) and its per-repetition bound verdicts, on
  the simulated provider. Establishes runtime properties of one VM, not
  user-visible behavior; judging across repetitions is not its job.
  """

  @behaviour Elara.Lab

  alias Elara.Lab.{Client, Histogram, Sampler, Verdict}
  alias Elara.Lab.Scenarios.Concurrency.Evidence
  alias Elara.Message.{Assistant, ToolResult}
  alias Elara.Provider.Simulated
  alias Elara.Session.{Handoff, Store}

  @tool_rounds 2
  @deferred {__MODULE__, :deferred}
  @defaults %{
    "sessions" => 10,
    "turns" => 20,
    "answer_deltas" => 250,
    "ttft_ms" => 300,
    "deltas_per_sec" => 50,
    "delta_bytes" => 20,
    "bash_ms" => 200,
    "read_bytes" => 4_096,
    "ramp_ms" => 30_000,
    "duration_ms" => 600_000,
    "window_start_ms" => 60_000,
    "drain_ms" => 120_000,
    "watchdog_ms" => 30_000,
    "baseline_ms" => 10_000,
    "sample_ms" => 1_000,
    "guard_memory_mb" => 32_768,
    "guard_mailbox" => 100_000,
    "guard_lag_ms" => 60_000,
    "shutdown_ms" => 30_000,
    "client_close_ms" => 30_000,
    # Test-only faults: stream a different answer length than the accounting
    # expects, stall each session's first answer after its ledger row, keep
    # clients from reading until their session has stopped, or bind the
    # embedded server to a given port.
    "simulated_answer_deltas" => nil,
    "stall_first_answer_ms" => 0,
    "client_hold" => 0,
    "server_port" => 0
  }
  @counted [
    {:file, :sync, 1},
    {Elara.Session.Store, :save, 1},
    {Elara.Session.Context, :budget, 2},
    {Elara.Session.Handoff, :lineage, 1},
    {Elara.FlightRecorder, :complete_transition, 4},
    {Elara.Exec, :run, 2}
  ]

  @impl true
  def curve_fields do
    [
      {"latency_p50_ms", ["latency_ms", "p50"]},
      {"latency_p95_ms", ["latency_ms", "p95"]},
      {"latency_p99_ms", ["latency_ms", "p99"]},
      {"latency_cohort", ["latency_ms", "cohort"]},
      {"throughput_ratio", ["throughput", "ratio"]},
      {"memory_max_per_session", ["memory", "max_per_session"]},
      {"memory_max_per_session_client_adjusted", ["memory", "max_per_session_client_adjusted"]},
      {"memory_mean_per_session", ["memory", "mean_per_session"]},
      {"session_mailbox_max", ["queues", "session", "max"]},
      {"connection_mailbox_max", ["queues", "connection", "max"]},
      {"exec_mailbox_max", ["queues", "exec", "max"]},
      {"stub_port_queue_bytes_max", ["queues", "stub_port_bytes", "max"]},
      {"bash_excess_p95_ms", ["bash_excess_ms", "p95"]},
      {"scheduler_normal", ["schedulers", "normal"]},
      {"scheduler_dirty_cpu", ["schedulers", "dirty_cpu"]},
      {"scheduler_dirty_io", ["schedulers", "dirty_io"]},
      {"history_bytes_max", ["history_bytes", "max"]},
      {"cumulative_sessions", ["cumulative_sessions"]},
      {"completed_turns", ["completed_turns"]}
    ] ++
      for {m, f, a} <- @counted do
        name = "#{inspect(m)}.#{f}/#{a}"
        {"#{name} per delta", ["counts", name, "per_delta"]}
      end
  end

  @impl true
  def run(%{provider: :real}),
    do: raise(ArgumentError, "the concurrency scenario runs on the simulated provider only")

  def run(%{seed: seed, dir: dir, params: params}) do
    p = params(params)

    if Elara.Exec.status().jobs != 0,
      do: raise(ArgumentError, "the concurrency scenario needs an idle Elara.Exec")

    workspace = Path.join(dir, "workspace")
    File.mkdir_p!(workspace)
    fixture = String.duplicate("lab fixture\n", div(p.read_bytes, 12) + 1)
    File.write!(Path.join(workspace, "fixture.txt"), binary_part(fixture, 0, p.read_bytes))

    snapshot = %{
      sessions: children(Elara.SessionSup),
      tasks: children(Elara.TaskSup),
      exec: Elara.Exec.token()
    }

    # Every global resource is released on every exit path, setup failures included.
    try do
      swt_previous = :erlang.system_flag(:scheduler_wall_time, true)
      defer(fn -> :erlang.system_flag(:scheduler_wall_time, swt_previous) end)

      trace = if p.trace == "counts", do: :trace.session_create(:elara_lab_counts, self(), [])
      if trace, do: defer(fn -> :trace.session_destroy(trace) end)

      ledger = :ets.new(:lab_ledger, [:ordered_set, :public, write_concurrency: true])
      defer(fn -> release_ledger(ledger, snapshot) end)

      clients = :ets.new(:lab_clients, [:set, :public, write_concurrency: true])

      defer(fn ->
        for {pid, _sim} <- :ets.tab2list(clients), do: Process.exit(pid, :kill)
        :ets.delete(clients)
      end)

      {:ok, server} = Elara.Server.start(port: p.server_port)
      defer(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

      execute(%{
        p: p,
        seed: seed,
        dir: dir,
        workspace: workspace,
        snapshot: snapshot,
        trace: trace,
        ledger: ledger,
        clients: clients,
        server: server
      })
    after
      run_deferred()
    end
  end

  defp defer(fun), do: Process.put(@deferred, [fun | Process.get(@deferred, [])])

  defp run_deferred do
    Enum.each(Process.delete(@deferred) || [], fn fun ->
      try do
        fun.()
      catch
        _kind, _reason -> :ok
      end
    end)
  end

  # Provider tasks write the ledger. While any run-owned task survives, a holder
  # keeps the table until those tasks end, so no writer loses its storage.
  defp release_ledger(ledger, snapshot) do
    case children(Elara.TaskSup) -- snapshot.tasks do
      [] ->
        :ets.delete(ledger)

      writers ->
        holder =
          spawn(fn ->
            receive do
              {:"ETS-TRANSFER", _table, _from, _data} -> :ok
            end

            writers
            |> Enum.map(&Process.monitor/1)
            |> Enum.each(&receive(do: ({:DOWN, ^&1, _, _, _} -> :ok)))
          end)

        :ets.give_away(ledger, holder, nil)
    end
  end

  defp params(params) do
    ints =
      Map.new(@defaults, fn {key, default} ->
        value =
          case Map.fetch(params, key) do
            {:ok, value} -> String.to_integer(value)
            :error -> default
          end

        {String.to_atom(key), value}
      end)

    trace = Map.get(params, "trace", "none")

    unless trace in ["none", "counts"],
      do: raise(ArgumentError, "trace must be none or counts, got #{inspect(trace)}")

    Map.put(ints, :trace, trace)
  end

  # ── Load ────────────────────────────────────────────────────────────────

  defp execute(run) do
    p = run.p
    port = Elara.Server.port(run.server)
    listen = :sys.get_state(run.server).listen

    sampler =
      Sampler.start(
        owner: self(),
        sample_ms: p.sample_ms,
        listen: listen,
        server_port: port,
        clients: run.clients,
        stub_os_pid: Elara.Exec.status().os_pid,
        guard_memory_bytes: p.guard_memory_mb * 1_048_576,
        guard_mailbox: p.guard_mailbox
      )

    defer(fn -> Process.exit(sampler, :kill) end)
    Process.sleep(p.baseline_ms)
    t0 = System.monotonic_time(:millisecond)
    shared = Client.shared(t0)
    Sampler.load(sampler, t0, t0 + p.window_start_ms, t0 + p.duration_ms, shared)

    run =
      Map.merge(run, %{
        coordinator: self(),
        port: port,
        sampler: sampler,
        t0: t0,
        window_from: t0 + p.window_start_ms,
        load_end: t0 + p.duration_ms,
        offsets: offsets(run.seed, p),
        shared: shared,
        tools: Enum.filter(Elara.Tool.builtins(), &(&1.name in ["read", "bash"]))
      })

    users =
      for {offset, index} <- Enum.with_index(run.offsets, 1), into: %{} do
        {pid, ref} = spawn_monitor(fn -> user(run, index, offset) end)
        {ref, pid}
      end

    Process.send_after(self(), :window_start, max(run.window_from - t0, 0))
    Process.send_after(self(), :load_end, p.duration_ms)

    coordinate(
      Map.merge(run, %{
        users: users,
        client_refs: %{},
        phase: :load,
        stop: nil,
        cutoff: nil,
        swt: %{},
        counts: nil,
        window_to: nil,
        drain_deadline: nil,
        sessions: [],
        attaches: [],
        turns: [],
        summaries: %{},
        user_failures: []
      })
    )
  end

  defp offsets(seed, p) do
    rand = :rand.seed_s(:exsss, {seed, 17, 0x3C6EF372})

    {offsets, _rand} =
      Enum.map_reduce(1..p.sessions//1, rand, fn _, rand ->
        {u, rand} = :rand.uniform_s(rand)
        {floor(u * p.ramp_ms), rand}
      end)

    offsets
  end

  defp coordinate(%{stop: stop} = run) when stop != nil, do: finalize(run)

  defp coordinate(run) do
    receive do
      :window_start ->
        coordinate(open_window(run))

      :load_end ->
        run = close_window(run, run.load_end)
        send(self(), :tick)
        coordinate(%{run | phase: :drain, drain_deadline: run.load_end + run.p.drain_ms})

      :tick ->
        coordinate(drain_tick(run))

      {:guard, kind, _at, _detail} ->
        coordinate(stop(run, :"guard_#{kind}"))

      {:start_client, from, ref, sim_id} ->
        {client, monitor} = start_client(run, sim_id)
        send(from, {ref, client})
        coordinate(put_in(run.client_refs[monitor], client))

      message ->
        case record(run, message) do
          {:ok, run} -> coordinate(run)
          :user_down -> user_down(run, message)
          :ignored -> coordinate(run)
        end
    end
  end

  # Reports that arrive both while coordinating and while settling.
  defp record(run, {:session, sim_id, id}),
    do: {:ok, %{run | sessions: [{sim_id, id} | run.sessions]}}

  defp record(run, {:attached, id, result}),
    do: {:ok, %{run | attaches: [{id, result} | run.attaches]}}

  defp record(run, {:turn, id, at, result}),
    do: {:ok, %{run | turns: [{id, at, result} | run.turns]}}

  defp record(run, {:client_summary, pid, sim_id, summary}),
    do: {:ok, put_in(run.summaries[pid], {sim_id, summary})}

  defp record(run, {:DOWN, ref, :process, _pid, _reason}) when is_map_key(run.users, ref),
    do: :user_down

  defp record(run, {:DOWN, ref, :process, _pid, _reason}) when is_map_key(run.client_refs, ref),
    do: {:ok, %{run | client_refs: Map.delete(run.client_refs, ref)}}

  defp record(_run, _message), do: :ignored

  defp user_down(run, {:DOWN, ref, :process, _pid, reason}) do
    run = %{run | users: Map.delete(run.users, ref)}

    run =
      if reason == :normal, do: run, else: %{run | user_failures: [reason | run.user_failures]}

    cond do
      run.users != %{} -> coordinate(run)
      System.monotonic_time(:millisecond) >= run.load_end -> finalize(run)
      true -> coordinate(stop(run, :users_exited))
    end
  end

  defp drain_tick(%{phase: :drain} = run) do
    now = System.monotonic_time(:millisecond)

    cond do
      now >= run.drain_deadline ->
        stop(run, :drain_timeout)

      now - Client.progress(run.shared) >= run.p.watchdog_ms ->
        stop(run, :watchdog)

      true ->
        Process.send_after(self(), :tick, run.p.sample_ms)
        run
    end
  end

  defp drain_tick(run), do: run

  defp stop(%{stop: nil} = run, reason) do
    cutoff = Client.cut(run.shared, System.monotonic_time(:millisecond))
    run = if run.window_to, do: run, else: close_window(run, cutoff)
    %{run | stop: reason, cutoff: cutoff}
  end

  defp stop(run, _reason), do: run

  defp open_window(%{window_to: nil} = run) do
    if run.trace,
      do: Enum.each(@counted, &:trace.function(run.trace, &1, true, [:call_count]))

    put_in(run.swt[:start], :erlang.statistics(:scheduler_wall_time_all))
  end

  defp open_window(run), do: run

  defp close_window(%{window_to: nil} = run, at) do
    opened? = Map.has_key?(run.swt, :start)

    counts =
      if run.trace && opened? do
        Map.new(@counted, fn {m, f, a} = mfa ->
          {:call_count, n} = :trace.info(run.trace, mfa, :call_count)
          {"#{inspect(m)}.#{f}/#{a}", n || 0}
        end)
      end

    swt =
      if opened?,
        do: Map.put(run.swt, :end, :erlang.statistics(:scheduler_wall_time_all)),
        else: run.swt

    %{run | window_to: at, counts: counts, swt: swt}
  end

  defp close_window(run, _at), do: run

  # ── Users ───────────────────────────────────────────────────────────────

  defp user(run, index, offset) do
    wait_until(run.t0 + offset)
    cycle(run, index, 1)
  end

  defp cycle(run, index, number) do
    if System.monotonic_time(:millisecond) < run.load_end do
      sim_id = "u#{index}c#{number}"
      client = request_client(run, sim_id)

      provider =
        Simulated.new(
          seed: run.seed,
          id: sim_id,
          profile: profile(run.p),
          ledger: run.ledger,
          fault: stall_hook(run.p.stall_first_answer_ms)
        )

      {:ok, id} =
        Elara.start_session(
          provider: provider,
          cwd: run.workspace,
          plugins: [],
          tools: run.tools,
          context_limit: 1_000_000
        )

      send(run.coordinator, {:session, sim_id, id})
      attach = Client.attach(client, id, 10_000)
      send(run.coordinator, {:attached, id, attach})
      if attach == :ok, do: turns(run, id, 1)

      with {:ok, pid} <- Elara.session_pid(id) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end

      Client.finish(client)
      cycle(run, index, number + 1)
    end
  end

  defp turns(run, id, turn) do
    if turn <= run.p.turns and System.monotonic_time(:millisecond) < run.load_end do
      result = Elara.ask(id, "turn #{turn}")
      now = System.monotonic_time(:millisecond)
      Client.advance(run.shared, now)
      send(run.coordinator, {:turn, id, now, result})
      turns(run, id, turn + 1)
    end
  end

  # The coordinator creates, registers and monitors every client, so a user
  # killed at any point cannot leave one untracked.
  defp request_client(run, sim_id) do
    ref = make_ref()
    send(run.coordinator, {:start_client, self(), ref, sim_id})

    receive do
      {^ref, client} -> client
    after
      30_000 -> exit(:no_client)
    end
  end

  defp start_client(run, sim_id) do
    p = run.p

    client =
      Client.start(
        owner: run.coordinator,
        sim_id: sim_id,
        ledger: run.ledger,
        accounting: [
          sim_id: sim_id,
          ttft_ms: p.ttft_ms,
          interval_ms: 1000 / p.deltas_per_sec,
          answer_deltas: p.answer_deltas,
          window: {run.window_from, run.load_end}
        ],
        shared: run.shared,
        port: run.port,
        sample_ms: p.sample_ms,
        guard_lag_ms: p.guard_lag_ms,
        bash_ms: p.bash_ms,
        close_ms: p.client_close_ms,
        hold: p.client_hold == 1
      )

    :ets.insert(run.clients, {client, sim_id})
    {client, Process.monitor(client)}
  end

  defp profile(p) do
    [
      ttft_ms: p.ttft_ms,
      deltas_per_sec: p.deltas_per_sec,
      delta_bytes: p.delta_bytes,
      answer_deltas: p.simulated_answer_deltas || p.answer_deltas,
      tool_rounds: @tool_rounds,
      stamp_deltas: true,
      tool_plan: [
        {"read", %{"path" => "fixture.txt"}},
        {"bash",
         %{"command" => "sleep #{:erlang.float_to_binary(p.bash_ms / 1000, decimals: 3)}"}}
      ]
    ]
  end

  # Stalls each session's first answer request after its ledger row is written,
  # leaving its recorded start and intended schedule unchanged.
  defp stall_hook(0), do: nil

  defp stall_hook(ms) do
    fn
      :provider_started, key ->
        [_id, request] = String.split(key, ":")
        if String.to_integer(request) == @tool_rounds + 1, do: Process.sleep(ms)
        :ok

      _point, _key ->
        :ok
    end
  end

  # ── Settlement ──────────────────────────────────────────────────────────

  defp finalize(run) do
    run = close_window(run, run.cutoff || run.load_end)
    users = run.users
    Enum.each(users, fn {_ref, pid} -> Process.exit(pid, :kill) end)
    {run, left_users} = await_users(run, Map.keys(users), 5_000)

    deadline = System.monotonic_time(:millisecond) + run.p.shutdown_ms
    sessions = children(Elara.SessionSup) -- run.snapshot.sessions
    {left_sessions, killed} = stop_sessions(sessions, deadline)
    left_tasks = await_exit(children(Elara.TaskSup) -- run.snapshot.tasks, deadline)
    jobs = await_exec_idle(deadline)
    ledger_final = left_sessions == [] and left_tasks == []

    run = collect_clients(run, ledger_final)
    left_clients = Map.values(run.client_refs)
    Enum.each(left_clients, &Process.exit(&1, :kill))
    samples = Sampler.stop(run.sampler)
    GenServer.stop(run.server)

    settlement = %{
      ledger_final: ledger_final,
      killed_sessions: killed,
      leftover_users: left_users,
      leftover_sessions: length(left_sessions),
      leftover_tasks: length(left_tasks),
      leftover_clients: length(left_clients),
      exec_jobs_pending: jobs,
      exec_epoch_changed: Elara.Exec.token() != run.snapshot.exec
    }

    result(
      run,
      samples,
      Map.put(settlement, :cleanup_confirmed, Evidence.cleanup_confirmed?(settlement))
    )
  end

  defp await_users(run, refs, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Enum.reduce(refs, {run, 0}, fn ref, {run, left} ->
      receive do
        {:DOWN, ^ref, :process, _, _} -> {%{run | users: Map.delete(run.users, ref)}, left}
      after
        max(deadline - System.monotonic_time(:millisecond), 0) -> {run, left + 1}
      end
    end)
  end

  defp stop_sessions(sessions, deadline) do
    Enum.each(sessions, fn pid ->
      spawn(fn ->
        try do
          GenServer.stop(pid, :shutdown, max(deadline - System.monotonic_time(:millisecond), 0))
        catch
          :exit, _ -> :ok
        end
      end)
    end)

    case await_exit(sessions, deadline) do
      [] ->
        {[], 0}

      left ->
        Enum.each(left, &Process.exit(&1, :kill))
        {await_exit(left, System.monotonic_time(:millisecond) + 5_000), length(left)}
    end
  end

  defp await_exit(pids, deadline) do
    refs = Map.new(pids, &{Process.monitor(&1), &1})
    await_refs(refs, deadline)
  end

  defp await_refs(refs, _deadline) when map_size(refs) == 0, do: []

  defp await_refs(refs, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, ref, :process, _pid, _reason} when is_map_key(refs, ref) ->
        await_refs(Map.delete(refs, ref), deadline)
    after
      remaining -> Map.values(refs)
    end
  end

  # Native execution settles separately from the tasks that asked for it. The
  # scenario required an idle Exec at start, so any job left is the run's.
  defp await_exec_idle(deadline) do
    case Elara.Exec.status().jobs do
      0 ->
        0

      jobs ->
        if System.monotonic_time(:millisecond) >= deadline do
          jobs
        else
          Process.sleep(20)
          await_exec_idle(deadline)
        end
    end
  end

  # Every client not yet reported finishes now: finally if no ledger writer can
  # still write, provisionally otherwise. Each reports once, then goes DOWN.
  defp collect_clients(run, ledger_final) do
    Enum.each(run.client_refs, fn {_ref, pid} ->
      unless is_map_key(run.summaries, pid), do: Client.finish(pid, ledger_final)
    end)

    deadline = System.monotonic_time(:millisecond) + run.p.client_close_ms + 5_000
    await_clients(run, deadline)
  end

  defp await_clients(%{client_refs: refs} = run, _deadline) when map_size(refs) == 0, do: run

  defp await_clients(run, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      message ->
        case record(run, message) do
          {:ok, run} -> await_clients(run, deadline)
          _other -> await_clients(run, deadline)
        end
    after
      remaining -> run
    end
  end

  # ── Result ──────────────────────────────────────────────────────────────

  defp result(run, sampled, settlement) do
    p = run.p
    n = p.sessions
    summaries = Map.values(run.summaries)
    totals = totals(Enum.map(summaries, &elem(&1, 1)))
    missing_summaries = :ets.info(run.clients, :size) - length(summaries)
    reached_end? = run.cutoff == nil or run.cutoff >= run.load_end
    censored = run.cutoff != nil
    transcripts = transcripts(run, censored)

    latency_snapshot = Histogram.snapshot(run.shared.latency)
    latency = Histogram.percentiles(latency_snapshot, totals.unreceived_in_cohort)
    cohort = totals.expected_in_cohort
    cohort_known = reached_end? and settlement.ledger_final and missing_summaries == 0

    proven =
      Histogram.at_least(latency_snapshot, Verdict.latency_bound_ms()) +
        totals.proven_late_unreceived

    arrivals = :counters.get(run.shared.arrivals, 1)
    window_s = (run.load_end - run.window_from) / 1000
    r_ideal = r_ideal(p)
    ratio = if reached_end? and window_s > 0, do: arrivals / (window_s * n * r_ideal)
    memory = memory(sampled.samples, n)

    turns =
      for {id, at, result} <- run.turns, run.cutoff == nil or at <= run.cutoff, do: {id, result}

    checks = %{
      attach_before_first_turn: Enum.all?(run.attaches, &(elem(&1, 1) == :ok)),
      turns_ok: Enum.all?(turns, &match?({_, {:ok, _}}, &1)),
      tools_ok: transcripts.tool_failures == 0,
      answers_complete:
        totals.fully_received_answers == totals.completed_answers and
          totals.non_compliant_answers == 0 and transcripts.wrong_answer_sizes == 0,
      accounting_reconciled:
        missing_summaries == 0 and
          Enum.all?(summaries, fn {_sim, s} ->
            s.ledger_final and s.expected == s.emitted and s.emitted == s.received and
              s.unattributed == 0 and s.out_of_order == 0 and s.post_cutoff == 0 and
              s.duplicates == 0 and s.invalid == 0
          end),
      clients_closed: Enum.all?(summaries, fn {_sim, s} -> s.close == :closed end),
      users_ok: run.user_failures == [],
      no_handoff: transcripts.frozen == 0,
      sessions_openable: transcripts.unopenable == 0,
      sessions_persisted: transcripts.reconciled.sessions_persisted,
      answers_persisted: transcripts.reconciled.answers_persisted,
      guard_not_tripped: not guard?(run.stop),
      drain_completed: run.stop not in [:watchdog, :drain_timeout]
    }

    compliant =
      checks.attach_before_first_turn and checks.turns_ok and checks.tools_ok and
        checks.no_handoff and checks.sessions_openable and checks.users_ok and
        checks.sessions_persisted and checks.answers_persisted and
        totals.non_compliant_answers == 0 and transcripts.wrong_answer_sizes == 0

    complete =
      run.stop == nil and checks.accounting_reconciled and checks.clients_closed and
        settlement.ledger_final and totals.interrupted == 0

    bounds =
      Verdict.bounds(%{
        compliant: compliant,
        complete: complete,
        latency: %{
          p95: latency && latency.p95,
          cohort: cohort,
          cohort_known: cohort_known,
          proven_failures: proven
        },
        memory: %{
          samples: Enum.map(memory.samples, &Map.take(&1, [:t, :per_session])),
          from: run.window_from,
          to: min(run.load_end, run.cutoff || run.load_end),
          sample_ms: p.sample_ms,
          baseline: memory.baseline_ok
        },
        throughput: %{ratio: ratio}
      })

    %{
      sessions: n,
      cumulative_sessions: length(run.sessions),
      session_files: transcripts.files,
      sessions_root_files: transcripts.all_files,
      completed_turns: Enum.count(turns, &match?({_, {:ok, _}}, &1)),
      failed_turns: Enum.count(turns, &(not match?({_, {:ok, _}}, &1))),
      incomplete: run.stop,
      stopped_at_ms: run.cutoff && run.cutoff - run.t0,
      compliant: compliant,
      complete: complete,
      window_ms: run.window_to && run.window_to - run.window_from,
      latency_ms:
        Map.merge(latency || %{}, %{
          cohort: cohort,
          cohort_known: cohort_known,
          overflow: latency_snapshot.overflow,
          unreceived: totals.unreceived_in_cohort,
          proven_failures: proven
        }),
      throughput: %{arrivals_in_window: arrivals, r_ideal: Float.round(r_ideal, 3), ratio: ratio},
      memory: Map.delete(memory, :samples),
      queues: queues(sampled),
      bash_excess_ms: Histogram.percentiles(Histogram.snapshot(run.shared.bash)),
      schedulers: schedulers(run.swt),
      counts: counts(run.counts, run.window_to && run.window_to - run.window_from, arrivals),
      accounting:
        totals
        |> Map.take([
          :expected,
          :emitted,
          :received,
          :expected_unemitted,
          :emitted_unreceived,
          :unattributed,
          :post_cutoff,
          :out_of_order,
          :duplicates,
          :invalid,
          :interrupted
        ])
        |> Map.put(:missing_summaries, missing_summaries),
      history_bytes: transcripts.history_bytes,
      transcripts:
        transcripts.reconciled
        |> Map.drop([:sessions_persisted, :answers_persisted])
        |> Map.put(:tool_failures, transcripts.tool_failures),
      settlement: Map.delete(settlement, :cleanup_confirmed),
      bounds: bounds,
      checks: checks,
      host: Elara.Lab.host(),
      choices_digest: Elara.Lab.digest({run.offsets, profile(p)}),
      cleanup_confirmed: settlement.cleanup_confirmed
    }
  end

  defp guard?(stop), do: stop in [:guard_memory, :guard_mailbox, :guard_lag]

  defp r_ideal(p) do
    interval = 1000 / p.deltas_per_sec
    cycle_ms = (@tool_rounds + 1) * p.ttft_ms + p.bash_ms + (p.answer_deltas - 1) * interval
    p.answer_deltas / (cycle_ms / 1000)
  end

  @summed [
    :expected,
    :emitted,
    :received,
    :expected_unemitted,
    :emitted_unreceived,
    :expected_in_cohort,
    :unreceived_in_cohort,
    :proven_late_unreceived,
    :non_compliant_answers,
    :completed_answers,
    :fully_received_answers,
    :interrupted,
    :unattributed,
    :post_cutoff,
    :out_of_order,
    :duplicates,
    :invalid
  ]

  defp totals(summaries),
    do:
      Map.new(@summed, fn key ->
        {key, summaries |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum()}
      end)

  defp memory(samples, n) do
    {baseline, measured} = Enum.split_with(samples, &(&1.phase == :baseline))
    baseline_ok = baseline != [] and Enum.all?(baseline, &is_integer(&1.stub_rss))

    base =
      if baseline_ok,
        do: div(Enum.sum(Enum.map(baseline, &(&1.total + &1.stub_rss))), length(baseline))

    measured =
      Enum.map(measured, fn s ->
        available = base && is_integer(s.stub_rss)

        Map.merge(s, %{
          per_session: available && div(s.total + s.stub_rss - base, n),
          per_session_client_adjusted:
            available && div(s.total + s.stub_rss - s.clients - base, n)
        })
      end)

    eligible = Enum.filter(measured, &(&1.phase == :window and &1.per_session))
    per_session = Enum.map(eligible, & &1.per_session)

    %{
      samples: measured,
      baseline_bytes: base,
      baseline_ok: baseline_ok,
      eligible_samples: length(eligible),
      max_per_session: Enum.max(per_session, fn -> nil end),
      max_per_session_client_adjusted:
        Enum.max(Enum.map(eligible, & &1.per_session_client_adjusted), fn -> nil end),
      mean_per_session:
        if(per_session != [], do: div(Enum.sum(per_session), length(per_session))),
      peak_total: Enum.max(Enum.map(samples, & &1.total), fn -> nil end),
      stub_rss_max: Enum.max(Enum.filter(Enum.map(samples, & &1.stub_rss), & &1), fn -> nil end),
      unavailable: Enum.count(measured, &(&1.per_session == nil))
    }
  end

  # Governing queue statistics come from window samples only; other phases are
  # reported as their maxima.
  defp queues(sampled) do
    window = Map.get(sampled.mailboxes, :window, %{})

    mailboxes =
      Map.new([:session, :connection, :exec], fn class ->
        {class, stats(Map.get(window, class, %{counts: %{}, unavailable: 0}))}
      end)

    port = for %{phase: :window, stub_queue_bytes: bytes} <- sampled.samples, do: bytes
    known = Enum.filter(port, &is_integer/1)

    port_stats =
      stats(%{counts: Enum.frequencies(known), unavailable: length(port) - length(known)})

    other =
      for {phase, by_class} <- sampled.mailboxes, phase != :window, into: %{} do
        {phase, Map.new(by_class, fn {class, h} -> {class, stats(h).max} end)}
      end

    mailboxes |> Map.put(:stub_port_bytes, port_stats) |> Map.put(:other_phases_max, other)
  end

  defp stats(%{counts: counts, unavailable: unavailable}) do
    percentiles = Histogram.percentiles(%{counts: counts, underflow: 0, overflow: 0})

    %{
      max: percentiles && percentiles.max,
      p99: percentiles && percentiles.p99,
      observations: Enum.sum(Map.values(counts)),
      unavailable: unavailable
    }
  end

  defp schedulers(%{start: start, end: finish}) do
    normal = :erlang.system_info(:schedulers)
    dirty_cpu = :erlang.system_info(:dirty_cpu_schedulers)
    before = Map.new(start, fn {id, active, total} -> {id, {active, total}} end)

    by_type =
      Enum.group_by(finish, fn {id, _, _} ->
        cond do
          id <= normal -> :normal
          id <= normal + dirty_cpu -> :dirty_cpu
          true -> :dirty_io
        end
      end)

    Map.new(by_type, fn {type, entries} ->
      {active, total} =
        Enum.reduce(entries, {0, 0}, fn {id, a, t}, {sa, st} ->
          {a0, t0} = Map.get(before, id, {0, 0})
          {sa + a - a0, st + t - t0}
        end)

      {type, if(total > 0, do: Float.round(active / total, 4))}
    end)
  end

  defp schedulers(_swt), do: nil

  defp counts(nil, _window_ms, _arrivals), do: nil

  defp counts(counts, window_ms, arrivals) do
    Map.new(counts, fn {name, n} ->
      {name,
       %{
         total: n,
         per_s: if(window_ms && window_ms > 0, do: Float.round(n * 1000 / window_ms, 2)),
         per_delta: if(arrivals > 0, do: Float.round(n / arrivals, 4))
       }}
    end)
  end

  # Off the timing path. Every persisted session is opened and reconciled with
  # what users reported; every persisted tool failure counts, since wall-clock
  # entry timestamps cannot place it relative to the monotonic cutoff.
  defp transcripts(run, censored) do
    p = run.p
    root = Path.join(run.dir, "sessions")
    all = Path.wildcard(Path.join(root, "**/*"))
    expected = p.answer_deltas * p.delta_bytes

    files =
      Enum.filter(all, fn path ->
        Path.extname(path) == ".jsonl" and
          not String.starts_with?(Path.relative_to(path, root), "_")
      end)

    stats =
      Enum.map(files, fn path ->
        case Store.open(path) do
          {:ok, store} ->
            history = Store.history(store)

            answers =
              for %Assistant{text: text, tool_calls: []} <- history, is_binary(text), do: text

            tools =
              for %{message: %ToolResult{outcome: outcome}} <- store.entries,
                  do: match?({:ok, _}, outcome)

            %{
              id: store.id,
              answers: length(answers),
              frozen: if(Handoff.frozen?(store), do: 1, else: 0),
              wrong: Enum.count(answers, &(byte_size(&1) != expected)),
              tools: tools,
              bytes: byte_size(JSON.encode!(Enum.map(history, &Store.encode_message/1)))
            }

          {:error, _reason} ->
            :unopenable
        end
      end)

    opened = Enum.reject(stats, &(&1 == :unopenable))
    bytes = opened |> Enum.map(& &1.bytes) |> Enum.sort()

    turns =
      for {id, at, result} <- run.turns,
          run.cutoff == nil or at <= run.cutoff,
          do: {id, match?({:ok, _}, result)}

    %{
      files: length(files),
      all_files: Enum.count(all, &File.regular?/1),
      unopenable: length(stats) - length(opened),
      frozen: Enum.sum(Enum.map(opened, & &1.frozen)),
      wrong_answer_sizes: Enum.sum(Enum.map(opened, & &1.wrong)),
      tool_failures: Evidence.tool_failures(Enum.flat_map(opened, & &1.tools)),
      reconciled:
        Evidence.reconcile(
          Enum.map(run.sessions, &elem(&1, 1)),
          turns,
          Enum.map(opened, &Map.take(&1, [:id, :answers])),
          censored
        ),
      history_bytes:
        if(bytes == [],
          do: nil,
          else: %{p50: Enum.at(bytes, div(length(bytes) - 1, 2)), max: List.last(bytes)}
        )
    }
  end

  defp children(Elara.TaskSup), do: Task.Supervisor.children(Elara.TaskSup)

  defp children(supervisor),
    do:
      for(
        {_id, pid, _type, _mods} <- DynamicSupervisor.which_children(supervisor),
        is_pid(pid),
        do: pid
      )

  defp wait_until(target) do
    remaining = target - System.monotonic_time(:millisecond)
    if remaining > 0, do: Process.sleep(remaining)
  end
end
