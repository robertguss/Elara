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

  # A run whose cleanup is unconfirmed leaves its sessions root bound.
  setup do
    previous = Map.new([:sessions_root, :skills_home], &{&1, Application.get_env(:elara, &1)})

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:elara, key, value) end)
    end)
  end

  defp run(overrides, seed \\ 42) do
    {:ok, [result]} = Elara.Lab.run(Concurrency, seed: seed, params: Map.merge(@tiny, overrides))

    on_exit(fn ->
      for key <- [:evidence_dir, :retained_dir], dir = result[key], do: File.rm_rf!(dir)
    end)

    result
  end

  defp failed(result), do: Elara.Lab.failed_checks(result)

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
    assert Map.has_key?(result.queues.other_phases_max, :baseline)
    assert Enum.all?(Map.values(result.schedulers), &(&1 >= 0 and &1 <= 1))
    assert result.counts == nil
    assert %{count: _} = result.bash_excess_ms
    assert result.history_bytes.max > 0
    assert result.transcripts.tool_failures == 0
    assert result.bounds.latency in ["holds", "fails"]
    assert result.host.logical_cpus > 0
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

  test "the scenario refuses the real provider" do
    assert_raise ArgumentError, ~r/simulated provider only/, fn ->
      Elara.Lab.run(Concurrency, seed: 1, provider: :real, max_requests: 10)
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
