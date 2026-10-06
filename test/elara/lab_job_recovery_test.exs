defmodule Elara.Lab.JobRecoveryTest do
  use ExUnit.Case, async: false

  alias Elara.Lab.Gate
  alias Elara.Lab.Scenarios.JobRecovery

  @moduletag timeout: 60_000

  for stage <- ~w(session_running runner_running manager_running) do
    test "#{stage} retains job and input evidence without replay" do
      stage = unquote(stage)

      assert {:ok, [result]} =
               Elara.Lab.run("job_recovery", seed: 42, params: %{"stage" => stage})

      assert result.complete, inspect({result.error, result.checks})
      assert Elara.Lab.failed_checks(result) == [], inspect(result)
      assert result.cleanup.confirmed, inspect(result.cleanup)
      assert result.launches == 1
      assert result.native.before.alive
      assert result.native.before.owned
      refute result.native.before.pgid == result.native.before.controller_pgid
      assert result.native.after.stopped
      assert result.job["slot"] == "released"

      assert result.job["status"] ==
               if(stage == "session_running", do: "passed", else: "indeterminate")

      assert result.observation.inputs["A"].state ==
               if(stage == "session_running", do: :failed, else: :completed)

      assert result.observation.inputs["report"].completed
      assert is_binary(JSON.encode!(result))
    end
  end

  test "the seed reproduces and varies the declared order and bounded work" do
    schedules = for seed <- 42..61, do: JobRecovery.schedule(seed, "runner_running")
    assert hd(schedules) == JobRecovery.schedule(42, "runner_running")
    assert length(Enum.uniq(Enum.map(schedules, & &1.order))) == 2
    assert length(Enum.uniq(Enum.map(schedules, & &1.ttft_ms))) > 5
  end

  test "a released source callback rejects the nominated fault" do
    assert {:ok, [result]} =
             Elara.Lab.run("job_recovery",
               seed: 42,
               params: %{"stage" => "session_running"},
               hook: fn
                 {:before_fault, %{gate: gate, point: point}} ->
                   assert :ok = Gate.release(gate, point)

                 _ ->
                   :ok
               end
             )

    assert result.cleanup.confirmed, inspect(result.cleanup)
    refute result.complete
    refute result.checks.fault_witnessed
    refute result.checks.target_down_witnessed
  end

  test "premature runner death is not the nominated injection" do
    assert {:ok, [result]} =
             Elara.Lab.run("job_recovery",
               seed: 42,
               params: %{"stage" => "runner_running"},
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

  test "a job which finishes before the nominated fault is rejected" do
    assert {:ok, [result]} =
             Elara.Lab.run("job_recovery",
               seed: 42,
               params: %{"stage" => "manager_running"},
               hook: fn
                 {:before_fault, %{runner_pid: runner, native: native}} ->
                   ref = Process.monitor(runner)
                   File.write!(Path.join(native.cwd, "release"), "")
                   assert_receive {:DOWN, ^ref, :process, ^runner, :normal}, 5_000

                 _ ->
                   :ok
               end
             )

    assert result.cleanup.confirmed, inspect(result.cleanup)
    refute result.complete
    refute result.checks.fault_witnessed
    refute result.checks.target_down_witnessed
  end

  for stage <- ~w(session_running manager_running) do
    test "forced failure at #{stage} settles actors and the real command group" do
      stage = unquote(stage)
      test_owner = self()

      assert {:ok, [result]} =
               Elara.Lab.run("job_recovery",
                 seed: 42,
                 params: %{"stage" => stage},
                 hook: fn
                   {:before_fault,
                    %{gate: gate, session_pid: session, runner_pid: runner, native: native}} ->
                     callers =
                       Gate.snapshot(gate) |> Enum.map(& &1.caller) |> Enum.filter(&is_pid/1)

                     send(
                       test_owner,
                       {:owned, Enum.uniq([gate, session, runner | callers]), native}
                     )

                     raise "forced job preparation failure"

                   _ ->
                     :ok
                 end
               )

      assert_receive {:owned, actors, native}, 1_000
      assert Enum.all?(actors, &(not Process.alive?(&1)))
      assert result.cleanup.confirmed, inspect(result.cleanup)
      refute result.complete
      {rows, status} = System.cmd("ps", ["-p", Integer.to_string(native.pid), "-o", "stat="])

      assert (status == 1 and rows == "") or
               (status == 0 and String.starts_with?(String.trim(rows), "Z"))

      {groups, 0} = System.cmd("ps", ["-ax", "-o", "pid=,pgid=,stat="])

      for row <- String.split(groups, "\n", trim: true),
          [_pid, group, state] = String.split(row),
          group == Integer.to_string(native.pgid),
          do: assert(String.starts_with?(state, "Z"))
    end
  end
end
