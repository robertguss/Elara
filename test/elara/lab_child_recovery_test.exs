defmodule Elara.Lab.ChildRecoveryTest do
  use ExUnit.Case, async: false

  alias Elara.Lab.Gate
  alias Elara.Lab.Scenarios.ChildRecovery

  @moduletag timeout: 60_000

  for stage <- ~w(parent_delegated child_provider child_marker) do
    test "#{stage} recovers accepted inputs without duplicating child work" do
      stage = unquote(stage)

      assert {:ok, [result]} =
               Elara.Lab.run("child_recovery", seed: 42, params: %{"stage" => stage})

      assert result.complete, inspect({result.error, result.checks})
      assert Elara.Lab.failed_checks(result) == [], inspect(result)
      assert result.cleanup.confirmed, inspect(result.cleanup)
      assert result.children_created == 1
      assert result.capacity.before == 1
      assert result.capacity.after == 0
      assert result.capacity.after_cleanup == 0

      expected_uncertainty =
        case stage do
          "parent_delegated" -> ["delegate-A"]
          "child_provider" -> []
          "child_marker" -> ["child-marker-A"]
        end

      assert result.uncertain_call_ids == expected_uncertainty

      reports =
        result.parent_observation.inputs
        |> Map.keys()
        |> Enum.filter(&String.starts_with?(&1, "report-"))

      assert Enum.sort(reports) ==
               if(stage == "parent_delegated", do: ["report-A"], else: ["report-B", "report-C"])

      if stage == "child_marker" do
        assert result.uncertain_call_ids == ["child-marker-A"]
        assert result.acknowledgment.call_ids == result.uncertain_call_ids
        assert result.acknowledgment.blocked_before_ack
        assert result.acknowledgment.integrated_after_ack
        refute result.child_observation.inputs["A"].completed
      end
    end
  end

  test "a released delegation callback is not a valid nominated fault" do
    assert {:ok, [result]} =
             Elara.Lab.run("child_recovery",
               seed: 42,
               params: %{"stage" => "parent_delegated"},
               hook: fn
                 {:before_fault, %{gates: [parent_gate | _], point: point}} ->
                   assert :ok = Gate.release(parent_gate, point)

                 _ ->
                   :ok
               end
             )

    assert result.cleanup.confirmed, inspect(result.cleanup)
    refute result.complete
    refute result.checks.fault_witnessed
    refute result.checks.target_down_witnessed
  end

  test "premature child death is not the nominated injection" do
    assert {:ok, [result]} =
             Elara.Lab.run("child_recovery",
               seed: 42,
               params: %{"stage" => "child_marker"},
               hook: fn
                 {:before_fault, %{target: target}} ->
                   ref = Process.monitor(target)
                   Process.exit(target, :kill)
                   assert_receive {:DOWN, ^ref, :process, ^target, :killed}, 1_000

                 _ ->
                   :ok
               end
             )

    assert result.cleanup.confirmed, inspect(result.cleanup)
    refute result.complete
    refute result.checks.fault_witnessed
    refute result.checks.target_down_witnessed
  end

  test "seed fixes and varies queue order and bounded provider work" do
    schedules = for seed <- 42..61, do: ChildRecovery.schedule(seed, "child_marker")
    assert hd(schedules) == ChildRecovery.schedule(42, "child_marker")
    assert length(Enum.uniq(Enum.map(schedules, & &1.order))) == 2
    assert length(Enum.uniq(Enum.map(schedules, & &1.ttft_ms))) > 5
  end

  for stage <- ~w(parent_delegated child_marker) do
    test "failure with #{stage} held settles all discovered child actors" do
      stage = unquote(stage)
      parent = self()

      assert {:ok, [result]} =
               Elara.Lab.run("child_recovery",
                 seed: 42,
                 params: %{"stage" => stage},
                 hook: fn
                   {:before_fault, %{gates: gates, session_pids: sessions}} ->
                     callers =
                       Enum.flat_map(gates, fn gate ->
                         Gate.snapshot(gate) |> Enum.map(& &1.caller) |> Enum.filter(&is_pid/1)
                       end)

                     send(parent, {:owned, Enum.uniq(gates ++ sessions ++ callers)})
                     raise "forced child preparation failure"

                   _ ->
                     :ok
                 end
               )

      assert_receive {:owned, pids}, 1_000
      assert Enum.all?(pids, &(not Process.alive?(&1)))
      assert result.cleanup.confirmed, inspect(result.cleanup)
      assert result.capacity.after_cleanup == 0
      refute result.complete
      refute result.checks.fault_witnessed
    end
  end
end
