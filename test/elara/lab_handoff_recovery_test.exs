defmodule Elara.Lab.HandoffRecoveryTest do
  use ExUnit.Case, async: false

  alias Elara.Lab.Scenarios.HandoffRecovery
  alias Elara.Lab.Gate

  @moduletag timeout: 60_000

  for stage <- ~w(prepared created transferred activated started) do
    test "public recovery at #{stage} preserves input identities and completes its successor" do
      stage = unquote(stage)

      assert {:ok, [result]} =
               Elara.Lab.run("handoff_recovery", n: 1, seed: 42, params: %{"stage" => stage})

      assert result.cleanup.confirmed, inspect(result.cleanup)
      assert result.complete, inspect({result.error, result.checks})
      assert Elara.Lab.failed_checks(result) == [], inspect(result)
      assert result.marker_labels == ["A" | result.schedule.order]
      assert length(result.observation.stores) == 2
      assert result.observation.inputs["H"].state == :completed
      assert result.observation.inputs["A"].state in [:failed, :interrupted]
    end
  end

  test "seed fixes queue order and bounded work while schedules actually vary" do
    schedules = for seed <- 42..61, do: HandoffRecovery.schedule(seed, "started")
    assert hd(schedules) == HandoffRecovery.schedule(42, "started")
    assert Enum.uniq(Enum.map(schedules, & &1.order)) |> length() == 2
    assert Enum.uniq(Enum.map(schedules, &{&1.ttft_ms, &1.gap_ms})) |> length() > 10
  end

  for point <- [:backlog_witnessed, :before_fault] do
    test "failure at #{point} cleans up the held source and all observed tasks" do
      point = unquote(point)
      parent = self()

      assert {:ok, [result]} =
               Elara.Lab.run("handoff_recovery",
                 seed: 42,
                 params: %{"stage" => "transferred"},
                 hook: fn
                   {^point, %{source_pid: source, gate: gate}} ->
                     callers =
                       Gate.snapshot(gate) |> Enum.map(& &1.caller) |> Enum.filter(&is_pid/1)

                     send(parent, {:owned, [gate, source | callers]})
                     raise "forced preparation failure"

                   _ ->
                     :ok
                 end
               )

      assert_receive {:owned, pids}
      assert Enum.all?(pids, &(not Process.alive?(&1)))
      assert result.cleanup.confirmed
      refute result.complete
      assert result.error == [:exception, "forced preparation failure"]
      refute result.checks.fault_witnessed
      refute result.checks.target_down_witnessed
    end
  end

  test "death before the nominated injection is not a valid fault row" do
    assert {:ok, [result]} =
             Elara.Lab.run("handoff_recovery",
               seed: 42,
               params: %{"stage" => "transferred"},
               hook: fn
                 {:before_fault, %{source_pid: source, gate: gate}} ->
                   ref = Process.monitor(source)
                   Process.exit(source, :kill)
                   assert_receive {:DOWN, ^ref, :process, ^source, :killed}
                   await_gate_down(gate, System.monotonic_time(:millisecond) + 1_000)
                   Process.sleep(5)

                 _ ->
                   :ok
               end
             )

    assert result.cleanup.confirmed
    refute result.complete
    refute result.checks.target_down_witnessed
  end

  test "releasing the lifecycle barrier before killing the source misses the nominated fault" do
    assert {:ok, [result]} =
             Elara.Lab.run("handoff_recovery",
               seed: 42,
               params: %{"stage" => "transferred"},
               hook: fn
                 {:before_fault, %{gate: gate}} -> Gate.release(gate, :handoff_stage)
                 _ -> :ok
               end
             )

    assert result.cleanup.confirmed
    refute result.complete
    refute result.checks.fault_witnessed
  end

  defp await_gate_down(gate, deadline) do
    event = Enum.find(Gate.snapshot(gate), &(&1.point == :handoff_stage))

    if event.down_at == nil do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(1)
      await_gate_down(gate, deadline)
    end
  end
end
