defmodule Elara.Lab.ConcurrencyTest do
  use ExUnit.Case, async: false

  alias Elara.Lab.Scenarios.Concurrency

  import ExUnit.CaptureLog

  @moduletag timeout: 120_000

  # Registered-shape workload scaled down to run in about two seconds.
  @tiny %{
    "sessions" => "2",
    "turns" => "2",
    "answer_deltas" => "5",
    "ttft_ms" => "5",
    "deltas_per_sec" => "200",
    "bash_ms" => "10",
    "ramp_ms" => "0",
    "duration_ms" => "1500",
    "window_start_ms" => "0",
    "drain_ms" => "5000",
    "watchdog_ms" => "2000",
    "baseline_ms" => "100",
    "sample_ms" => "50",
    "shutdown_ms" => "5000",
    "client_close_ms" => "3000"
  }

  # One teardown for every run in this module. A run whose cleanup is unconfirmed
  # leaves its sessions root bound, and a resumed transport keeps ticking there, so
  # permissions, directories and the root change only once the test's own tasks
  # and execution jobs have ended, and only while Threads and the transport are
  # confirmed suspended.
  setup do
    previous =
      Map.new(
        [:sessions_root, :skills_home, :thread_limit],
        &{&1, Application.fetch_env(:elara, &1)}
      )

    tasks = Task.Supervisor.children(Elara.TaskSup)
    {:ok, dirs} = Agent.start(fn -> [] end)
    Process.put(:lab_dirs, dirs)
    on_exit(fn -> teardown(dirs, previous, tasks) end)
  end

  defp teardown(dirs, previous, tasks) do
    unless writers_settled?(tasks, 300),
      do:
        raise(
          "lab teardown: run tasks or jobs still alive; directories and root left as they are"
        )

    held =
      Elara.Lab.with_held([Elara.Threads, Elara.Threads.Communication], 5_000, fn ->
        for dir <- Agent.get(dirs, & &1) do
          try do
            writable(dir)
            File.rm_rf!(dir)
          rescue
            error -> IO.warn("lab teardown could not remove #{dir}: #{inspect(error)}")
          end
        end

        Enum.each(previous, fn
          {key, {:ok, value}} -> Application.put_env(:elara, key, value)
          {key, :error} -> Application.delete_env(:elara, key)
        end)
      end)

    with {:error, reason} <- held,
         do:
           raise(
             "lab teardown not held (#{inspect(reason)}); directories and root left as they are"
           )
  after
    try do
      Agent.stop(dirs)
    catch
      :exit, _ -> :ok
    end
  end

  # Up to 15 s for tasks started during the test, and any execution job, to end.
  defp writers_settled?(tasks, tries) do
    cond do
      Task.Supervisor.children(Elara.TaskSup) -- tasks == [] and Elara.Exec.status().jobs == 0 ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(50)
        writers_settled?(tasks, tries - 1)
    end
  end

  defp writable(dir) do
    for path <- [dir | Path.wildcard(Path.join(dir, "**"), match_dot: true)],
        File.dir?(path),
        do: File.chmod(path, 0o755)
  end

  defp run(overrides, seed \\ 42, opts \\ []) do
    {:ok, [result]} =
      Elara.Lab.run(Concurrency, [seed: seed, params: Map.merge(@tiny, overrides)] ++ opts)

    for key <- [:evidence_dir, :retained_dir],
        dir = result[key],
        do: Agent.update(Process.get(:lab_dirs), &[dir | &1])

    result
  end

  defp failed(result), do: Elara.Lab.failed_checks(result)

  @counted ~w(:file.sync/1 Elara.Session.Store.save/1 Elara.Session.Context.budget/2
              Elara.Session.Handoff.lineage/1 Elara.FlightRecorder.complete_transition/4
              Elara.Exec.run/2)

  # Every registered measurement a sweep reports per repetition.
  @required ~w(latency_p50_ms latency_p95_ms latency_p99_ms latency_cohort latency_overflow
               latency_unreceived latency_proven_failures throughput_ratio arrivals_in_window
               memory_max_per_session memory_max_per_session_client_adjusted
               memory_mean_per_session session_mailbox_max session_mailbox_p99
               connection_mailbox_max connection_mailbox_p99 exec_mailbox_max exec_mailbox_p99
               threads_mailbox_max threads_mailbox_p99 transport_mailbox_max
               transport_mailbox_p99
               stub_port_queue_bytes_max stub_port_queue_bytes_p99 bash_excess_p50_ms
               bash_excess_p95_ms bash_excess_p99_ms scheduler_normal scheduler_dirty_cpu
               scheduler_dirty_io history_bytes_max cumulative_sessions session_files
               sessions_root_files completed_turns expected_unemitted emitted_unreceived
               stopped_at_ms window_ms tool_failures) ++
              Enum.flat_map(@counted, &["#{&1} per second", "#{&1} per delta"])

  # Each curve path, walked with key presence at every step: absent is not nil.
  defp missing_paths(result, fields) do
    decoded = result |> JSON.encode!() |> JSON.decode!()
    for {label, path} <- fields, fetch_path(decoded, path) == :error, do: label
  end

  defp fetch_path(value, []), do: {:ok, value}

  defp fetch_path(%{} = map, [key | rest]) do
    case Map.fetch(map, key) do
      {:ok, value} -> fetch_path(value, rest)
      :error -> :error
    end
  end

  defp fetch_path(_value, _path), do: :error

  defp count_field?({_label, ["counts" | _]}), do: true
  defp count_field?(_field), do: false

  defp children_field?({_label, [root | _]}), do: root in ["children", "reports", "parent"]

  test "curve fields name every registered measurement" do
    labels = Enum.map(Concurrency.curve_fields(), &elem(&1, 0))
    assert @required -- labels == []
    assert Enum.uniq(labels) == labels
  end

  test "a tiny complete run passes every check and measures every part" do
    result = run(%{})

    assert failed(result) == []
    refute Map.has_key?(result, :retained_dir)
    assert result.complete and result.compliant
    assert result.cumulative_sessions > 2
    assert result.session_files == result.cumulative_sessions

    %{expected: expected, emitted: emitted, received: received} = result.accounting
    assert expected > 0 and expected == emitted and emitted == received

    assert %{count: count, p50: p50, p95: _, p99: _, cohort: cohort, cohort_known: true} =
             result.latency_ms

    assert count == cohort and is_integer(p50)
    assert result.throughput.ratio > 0
    assert result.memory.baseline_ok and result.memory.eligible_samples > 0
    assert is_integer(result.memory.max_per_session)
    assert %{session: %{max: _}, connection: %{max: _}, exec: %{max: _}} = result.queues
    # Governing queue statistics come from the window's samples only.
    assert result.queues.exec.observations == result.memory.eligible_samples

    for class <- [:threads, :transport],
        do: assert(result.queues[class].observations == result.memory.eligible_samples)

    assert Map.has_key?(result.queues.other_phases_max, :baseline)
    assert Enum.all?(Map.values(result.schedulers), &(&1 >= 0 and &1 <= 1))
    assert result.counts == nil
    assert %{count: _} = result.bash_excess_ms
    assert result.history_bytes.max > 0
    assert result.transcripts.tool_failures == 0
    assert result.bounds.latency in ["holds", "fails"]
    assert result.host.logical_cpus > 0

    # Every other curve path is present; counts are an intentional null in timing
    # runs, and the children fields in the sessions topology.
    {counted, measured} = Enum.split_with(Concurrency.curve_fields(), &count_field?/1)
    {children, measured} = Enum.split_with(measured, &children_field?/1)
    assert missing_paths(result, measured) == []
    assert counted != [] and result.counts == nil
    assert children != [] and result.children == nil and result.reports == nil
    assert result.parent == nil
  end

  test "a count run reports each suspect's calls and restores tracing and scheduler timing" do
    assert :erlang.statistics(:scheduler_wall_time) == :undefined
    result = run(%{"trace" => "counts"})

    assert failed(result) == []
    assert %{":file.sync/1" => %{total: syncs}} = result.counts
    assert syncs > 0

    for name <- [
          "Elara.Session.Store.save/1",
          "Elara.Session.Context.budget/2",
          "Elara.Session.Handoff.lineage/1",
          "Elara.FlightRecorder.complete_transition/4",
          "Elara.Exec.run/2"
        ] do
      assert %{total: n, per_s: _, per_delta: _} = result.counts[name]
      assert n > 0, name
    end

    assert missing_paths(result, Enum.filter(Concurrency.curve_fields(), &count_field?/1)) == []
    refute Enum.any?(:trace.session_info(:all), &match?({:elara_lab_counts, _}, &1))
    assert :erlang.statistics(:scheduler_wall_time) == :undefined
  end

  test "a completed answer shorter than registered is non-compliant: checks fail, bounds undetermined" do
    result = run(%{"simulated_answer_deltas" => "4"})

    assert :answers_complete in failed(result)
    assert :accounting_reconciled in failed(result)
    refute result.compliant
    assert result.accounting.expected_unemitted > 0

    assert result.bounds == %{
             latency: "undetermined",
             memory: "undetermined",
             throughput: "undetermined"
           }
  end

  test "the drain watchdog stops a drain with no delta or turn progress" do
    result =
      run(%{"ttft_ms" => "400", "watchdog_ms" => "100", "duration_ms" => "300", "turns" => "1"})

    assert result.incomplete == :watchdog
    assert :drain_completed in failed(result)
    refute result.complete
    assert result.bounds.latency == "undetermined"
    refute Map.has_key?(result, :retained_dir)
  end

  test "the memory guard stops the run at once and every started session is stopped" do
    before = DynamicSupervisor.which_children(Elara.SessionSup)
    result = run(%{"guard_memory_mb" => "1", "sessions" => "8", "ramp_ms" => "300"})

    assert result.incomplete == :guard_memory
    assert is_integer(result.stopped_at_ms)
    assert :guard_not_tripped in failed(result)
    assert result.settlement.leftover_users == 0 and result.settlement.leftover_clients == 0
    assert Map.has_key?(result.accounting, :expected_unemitted)
    assert Map.has_key?(result.accounting, :emitted_unreceived)
    refute Map.has_key?(result, :retained_dir)
    assert DynamicSupervisor.which_children(Elara.SessionSup) == before
  end

  test "the lag guard trips during the load on an answer stalled after its ledger row" do
    result =
      run(%{
        "ttft_ms" => "50",
        "guard_lag_ms" => "200",
        "stall_first_answer_ms" => "2000",
        "duration_ms" => "10000"
      })

    assert result.incomplete == :guard_lag
    assert result.window_ms < 10_000
    assert result.accounting.received == 0
    refute Map.has_key?(result, :retained_dir)
  end

  test "time to first token is not lateness: a TTFT above the lag guard does not trip it" do
    result = run(%{"ttft_ms" => "400", "guard_lag_ms" => "200", "turns" => "1"})
    assert result.incomplete == nil
    assert failed(result) == []
  end

  test "final patches still in the socket when ask returns are received before the client retires" do
    result = run(%{"client_hold" => "1"})

    assert failed(result) == []
    assert result.accounting.received == result.accounting.emitted
    assert result.accounting.received > 0
  end

  test "a task outliving the shutdown deadline leaves cleanup unconfirmed and the root retained" do
    result =
      run(%{
        "bash_ms" => "3000",
        "duration_ms" => "300",
        "drain_ms" => "500",
        "shutdown_ms" => "200"
      })

    assert result.incomplete == :drain_timeout
    assert result.settlement.leftover_tasks > 0
    assert result.settlement.exec_jobs_pending > 0
    assert Map.has_key?(result, :retained_dir)
    wait_for_exec_idle()
  end

  test "a provider task outliving shutdown keeps the ledger it writes; cohort stays unknown" do
    result =
      run(%{
        "duration_ms" => "300",
        "drain_ms" => "300",
        "stall_first_answer_ms" => "2500",
        "shutdown_ms" => "200"
      })

    assert result.incomplete == :drain_timeout
    assert result.settlement.leftover_tasks > 0
    refute result.latency_ms.cohort_known
    assert Map.has_key?(result, :retained_dir)

    # The stalled tasks resume and write their ledger rows after the run returned.
    log = capture_log(fn -> Process.sleep(3_000) end)
    refute log =~ "ArgumentError"
    refute log =~ "ets"
  end

  test "a setup failure still restores scheduler timing and destroys the trace session" do
    {:ok, busy} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(busy)
    on_exit(fn -> :gen_tcp.close(busy) end)

    assert_raise MatchError, fn ->
      Elara.Lab.run(Concurrency,
        seed: 1,
        params: Map.merge(@tiny, %{"server_port" => "#{port}", "trace" => "counts"})
      )
    end

    assert :erlang.statistics(:scheduler_wall_time) == :undefined
    refute Enum.any?(:trace.session_info(:all), &match?({:elara_lab_counts, _}, &1))
  end

  test "the scenario refuses to start while Elara.Exec runs a job" do
    task = Task.async(fn -> Elara.Exec.run(["sleep", "1"]) end)
    wait_for(fn -> Elara.Exec.status().jobs == 1 end)

    assert_raise ArgumentError, ~r/idle Elara.Exec/, fn ->
      Elara.Lab.run(Concurrency, seed: 1, params: @tiny)
    end

    Task.await(task, 5_000)
  end

  test "a changed execution epoch leaves cleanup unconfirmed" do
    os_pid = Elara.Exec.status().os_pid

    spawn(fn ->
      Process.sleep(700)
      System.cmd("kill", ["-9", Integer.to_string(os_pid)])
    end)

    result = run(%{"duration_ms" => "1500"})

    assert result.settlement.exec_epoch_changed
    assert Map.has_key?(result, :retained_dir)
    wait_for_exec_idle()
  end

  @children %{"topology" => "children", "sessions" => "2"}

  # Hooks run in the runner, whose receive loops drop unknown messages, so they
  # record what they did in an Agent instead of messaging the test.
  defp released do
    {:ok, flag} = Agent.start_link(fn -> false end)
    flag
  end

  test "a tiny children run lifts the thread limit, passes every check and settles its actors" do
    limit = Application.fetch_env(:elara, :thread_limit)
    result = run(%{"topology" => "children", "sessions" => "6"})

    assert failed(result) == []
    refute Map.has_key?(result, :retained_dir)
    assert result.complete and result.compliant
    assert Application.fetch_env(:elara, :thread_limit) == limit

    %{expected: expected, emitted: emitted, received: received} = result.accounting
    assert expected > 0 and expected == emitted and emitted == received

    children = result.children
    assert result.cumulative_sessions >= 6
    assert children.attempts == result.cumulative_sessions
    assert children.returned_ok == children.attempts and children.censored == 0
    assert children.records == children.attempts and children.worktrees == children.attempts
    assert children.start_ms.count == children.attempts
    assert result.session_files == result.cumulative_sessions + 1

    assert result.reports.staged > 0 and result.reports.accepted == result.reports.staged
    assert result.parent.inbox_entries == result.reports.delivered
    assert result.settlement.leftover_watchers == 0

    assert missing_paths(result, Enum.filter(Concurrency.curve_fields(), &children_field?/1)) ==
             []
  end

  test "a child whose client attaches after the load ends is stopped with its assignment pending" do
    result = run(Map.merge(@children, %{"resume_delay_ms" => "2000", "watchdog_ms" => "5000"}))

    assert failed(result) == []
    refute Map.has_key?(result, :retained_dir)
    assert result.completed_turns == 0
    assert result.accounting.expected == 0
    assert result.children.records == 2 and result.cumulative_sessions == 2
    assert result.settlement.leftover_watchers == 0
  end

  test "starts accepted before the users die are created, then stopped by settlement" do
    threads = Process.whereis(Elara.Threads)
    :ok = :sys.suspend(threads)
    flag = released()

    hook = fn
      {:waiting, :threads} ->
        :sys.resume(threads)
        Agent.update(flag, fn _ -> true end)

      _point ->
        :ok
    end

    result = run(Map.put(@children, "watchdog_ms", "500"), 42, hook: hook)

    assert Agent.get(flag, & &1)
    assert result.incomplete == :watchdog
    assert %{attempts: 2, censored: 2, returned_ok: 0, records: 2} = result.children
    assert result.settlement.children_stopped and result.settlement.leftover_sessions == 0
    refute Map.has_key?(result, :retained_dir)
  end

  test "settlement waits for the transport to accept every staged report" do
    transport = Process.whereis(Elara.Threads.Communication)
    :ok = :sys.suspend(transport)
    flag = released()

    hook = fn
      {:waiting, :transport} ->
        :sys.resume(transport)
        Agent.update(flag, fn _ -> true end)

      _point ->
        :ok
    end

    result = run(@children, 42, hook: hook)

    assert Agent.get(flag, & &1)
    assert failed(result) == []
    assert result.reports.staged > 0 and result.reports.accepted == result.reports.staged
    assert result.settlement.reports_settled
    refute Map.has_key?(result, :retained_dir)
  end

  test "reports the transport cannot accept keep the run retained" do
    hook = fn
      :setup ->
        root = Application.fetch_env!(:elara, :sessions_root)
        File.mkdir_p!(Path.join([root, "_thread_messages", "completions"]))
        File.chmod!(Path.join(root, "_thread_messages"), 0o555)

      _point ->
        :ok
    end

    result = run(@children, 42, hook: hook)

    assert result.reports.staged > 0 and result.reports.accepted == 0
    refute result.settlement.reports_settled
    assert Map.has_key?(result, :retained_dir)
  end

  # The stalled provider tasks outlive the run; the teardown waits for them before
  # it moves the root, whether or not these assertions pass.
  test "watchers die with their users when a run stops inside turn 1" do
    result =
      run(Map.merge(@children, %{"stall_first_answer_ms" => "10000", "watchdog_ms" => "2000"}))

    assert result.incomplete == :watchdog
    assert result.settlement.leftover_watchers == 0
    assert result.settlement.leftover_tasks >= 1
    assert Map.has_key?(result, :retained_dir)
  end

  # A cwd key is the cwd's basename plus a hash, and a child's worktree basename is
  # a random token, so a session directory can begin with "_" like the internal ones.
  test "session files are the root's depth-two .jsonl files, whatever their key begins with" do
    root = Path.join(System.tmp_dir!(), "lab-session-files-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    for path <- [
          "_Tok3n-0a1b2c3d/child.jsonl",
          "workspace-4e5f6a7b/top.jsonl",
          ".dot-8c9d0e1f/hidden.jsonl",
          "_threads/r.json",
          "_threads/workspaces/_Tok3n/deep.jsonl",
          "_thread_messages/m.json",
          "workspace-4e5f6a7b/notes.txt"
        ] do
      File.mkdir_p!(Path.dirname(Path.join(root, path)))
      File.write!(Path.join(root, path), "")
    end

    assert root
           |> Concurrency.session_files()
           |> Enum.map(&Path.relative_to(&1, root))
           |> Enum.sort() ==
             [
               ".dot-8c9d0e1f/hidden.jsonl",
               "_Tok3n-0a1b2c3d/child.jsonl",
               "workspace-4e5f6a7b/top.jsonl"
             ]
  end

  test "an unknown topology is refused" do
    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert_raise ArgumentError, ~r/topology/, fn ->
        Elara.Lab.run(Concurrency, seed: 1, params: Map.put(@tiny, "topology", "mesh"))
      end
    end)
  end

  test "the scenario refuses the real provider" do
    assert_raise ArgumentError, ~r/simulated provider only/, fn ->
      Elara.Lab.run(Concurrency, seed: 1, provider: :real, max_requests: 10)
    end
  end

  describe "profile runs" do
    @profiled %{"trace" => "profile", "profile_window_ms" => "1000"}

    defp profile_sessions do
      for {name, _id} <- :trace.session_info(:all),
          String.starts_with?(Atom.to_string(name), "elara_lab_profile"),
          do: name
    end

    defp classifiers do
      for pid <- Process.list(),
          {:current_function, {Elara.Lab.Profile, :classify, 1}} <- [
            Process.info(pid, :current_function)
          ],
          do: pid
    end

    test "a profile run collects its window's profile and both censuses, and carries no verdict" do
      result = run(@profiled)
      profile = result.profile

      assert failed(result) == []
      assert result.bounds == %{}
      assert result.counts == nil
      assert profile.validity.status in [:valid, :qualified], inspect(profile.validity)

      for class <- [:session, :task, :connection, :exec, :client],
          do: assert(Map.has_key?(profile.classes, class), inspect(class))

      assert Enum.any?(profile.functions, &(&1.module == Elara.Session))

      w = profile.window
      assert w.from == 500 and w.to == 1_500
      assert w.a1 >= 500 and w.a1 <= w.n and w.n <= w.a2 and w.a2 <= w.f1
      assert w.f1 >= 1_500 and w.f1 <= w.f2
      assert profile.memory.before_activation.ended_ms <= profile.memory.after_freeze.started_ms
      assert is_integer(profile.collection_ms)
      assert is_binary(JSON.encode!(result))
      assert profile_sessions() == [] and classifiers() == []
    end

    test "every client of the run is a client, exited ones included" do
      # The window spans the run, so every client is censused or born traced.
      result = run(Map.put(@profiled, "profile_window_ms", "1500"))

      assert failed(result) == []
      assert result.cumulative_sessions > 2
      assert result.profile.classes.client.pids == result.cumulative_sessions
    end

    test "a stop before the profile window leaves the profile not activated" do
      result =
        run(Map.merge(@profiled, %{"guard_memory_mb" => "1", "profile_window_ms" => "500"}))

      assert result.incomplete == :guard_memory
      assert result.profile.validity.status == :invalid
      assert :not_activated in result.profile.validity.reasons
      assert profile_sessions() == [] and classifiers() == []
    end

    test "a stop inside the profile window still freezes, censuses and collects" do
      result =
        run(%{
          "trace" => "profile",
          "profile_window_ms" => "10000",
          "ttft_ms" => "50",
          "guard_lag_ms" => "200",
          "stall_first_answer_ms" => "2000",
          "duration_ms" => "10000"
        })

      profile = result.profile
      assert result.incomplete == :guard_lag
      assert profile.window.f1 < 10_000
      assert is_map(profile.classes) and profile.memory.after_freeze != nil
      assert profile.validity.status == :invalid
      assert :run_incomplete in profile.validity.reasons
      assert profile_sessions() == [] and classifiers() == []
    end

    test "a profile run that fails its checks is invalid" do
      result = run(Map.put(@profiled, "simulated_answer_deltas", "4"))

      assert failed(result) != []
      assert result.profile.validity.status == :invalid
      assert :run_checks_failed in result.profile.validity.reasons
    end

    test "a collector that raises is a collection failure, and the profile is disposed" do
      hook = fn
        :profile_collect -> raise "boom in collector"
        _point -> :ok
      end

      result = run(@profiled, 42, hook: hook)

      assert :collection_failed in result.profile.validity.reasons
      assert result.profile.collection_failure =~ "boom in collector"
      assert profile_sessions() == [] and classifiers() == []
    end

    test "a collection past its deadline is cancelled and reported as a timeout" do
      {:ok, seen} = Agent.start_link(fn -> nil end)

      hook = fn
        :profile_collect ->
          collector = self()
          Agent.update(seen, fn _ -> collector end)
          Process.sleep(5_000)

        _point ->
          :ok
      end

      result = run(Map.put(@profiled, "profile_collect_ms", "100"), 42, hook: hook)

      assert :collection_timeout in result.profile.validity.reasons
      refute Process.alive?(Agent.get(seen, & &1))
      assert profile_sessions() == [] and classifiers() == []
    end

    test "an exception after activation cancels the collector and disposes the profile" do
      {:ok, seen} = Agent.start_link(fn -> nil end)
      dirs = Process.get(:lab_dirs)

      hook = fn
        :profile_collect ->
          collector = self()
          Agent.update(seen, fn _ -> collector end)
          receive do: (:never -> :ok)

        :profile_await ->
          root = Application.get_env(:elara, :sessions_root)
          Agent.update(dirs, &[Path.dirname(root) | &1])
          raise "boom at await"

        _point ->
          :ok
      end

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert_raise RuntimeError, ~r/boom at await/, fn ->
          Elara.Lab.run(Concurrency, seed: 42, params: Map.merge(@tiny, @profiled), hook: hook)
        end
      end)

      refute Process.alive?(Agent.get(seen, & &1))
      assert profile_sessions() == [] and classifiers() == []
    end

    test "profile knobs are validated for profile runs only" do
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        for {params, message} <- [
              {%{"profile_window_ms" => "0"}, ~r/profile_window_ms/},
              {%{"profile_window_ms" => "1501"}, ~r/profile_window_ms/},
              {%{"profile_collect_ms" => "0"}, ~r/profile_collect_ms/},
              {%{"topology" => "children"}, ~r/topology=sessions only/},
              {%{"trace" => "bogus"}, ~r/trace must be/}
            ] do
          assert_raise ArgumentError, message, fn ->
            Elara.Lab.run(Concurrency,
              seed: 1,
              params: @tiny |> Map.merge(@profiled) |> Map.merge(params)
            )
          end
        end
      end)
    end
  end

  defp wait_for(done?, tries \\ 100) do
    cond do
      done?.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> Process.sleep(20) && wait_for(done?, tries - 1)
    end
  end

  defp wait_for_exec_idle(tries \\ 100) do
    status = Elara.Exec.status()

    cond do
      status.available and status.jobs == 0 -> :ok
      tries == 0 -> flunk("exec did not settle: #{inspect(status)}")
      true -> Process.sleep(50) && wait_for_exec_idle(tries - 1)
    end
  end
end
