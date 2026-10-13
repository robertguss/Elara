defmodule Elara.Lab.NativeRecoveryTest do
  use ExUnit.Case, async: false

  alias Elara.Lab.Scenarios.SessionRecovery.Coordinator

  @moduletag timeout: 60_000

  for stage <- ~w(executor_running stub_running) do
    test "#{stage} preserves uncertainty until scoped native-stop acknowledgment" do
      stage = unquote(stage)

      assert {:ok, [result]} =
               Elara.Lab.run("job_recovery",
                 seed: 42,
                 params: %{"stage" => stage},
                 hook: fn
                   {:before_ack, %{parent: parent, native: native}} ->
                     assert {:ok, record} = Elara.Lab.Jobs.record(parent, "focused")
                     assert record["slot"] == "held"

                     for pid <- [native.pid, native.guardian, native.stub] do
                       {state, status} =
                         System.cmd("ps", ["-p", Integer.to_string(pid), "-o", "stat="])

                       assert (status == 1 and state == "") or
                                (status == 0 and String.starts_with?(String.trim(state), "Z"))
                     end

                   _ ->
                     :ok
                 end
               )

      assert result.complete, inspect({result.error, result.checks})
      assert Elara.Lab.failed_checks(result) == [], inspect(result)
      assert result.cleanup.confirmed
      assert result.launches == 1
      assert result.job["status"] == "indeterminate"
      assert result.job["slot"] == "released"
      assert result.job["settlement"] == "operator_confirmed"
      assert result.epoch.held["slot"] == "held"
      assert result.epoch.held["settlement"] == "unknown"
      assert result.native.after.stopped
      assert result.native.after.guardian_stopped
      assert result.native.after.stub_stopped
      assert result.observation.inputs["A"].completed
      assert result.observation.inputs["report"].completed
    end
  end

  test "the coordinator witnesses the actual nominated Port DOWN" do
    {:ok, co} = Coordinator.start_link([])
    port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary])
    ref = :erlang.monitor(:port, port)

    try do
      assert :ok = Coordinator.observe_port(co, port)
      send(co, {:DOWN, make_ref(), :port, port, :normal})
      refute Coordinator.evidence(co).death.matched
      assert Port.close(port)
      assert_receive {:DOWN, ^ref, :port, ^port, _}, 1_000
      assert {:ok, down} = Coordinator.await_down(co, 1_000)
      assert down.target == port
      assert Coordinator.evidence(co).death.target == inspect(port)
    after
      if Port.info(port), do: Port.close(port)
      Process.demonitor(ref, [:flush])
      if Process.alive?(co), do: GenServer.stop(co)
    end
  end

  test "native stub loss before injection cannot become the nominated fault" do
    assert {:ok, [result]} =
             Elara.Lab.run("job_recovery",
               seed: 42,
               params: %{"stage" => "stub_running"},
               hook: fn
                 {:before_fault, %{target: port, stub_os_pid: pid}} ->
                   ref = :erlang.monitor(:port, port)
                   {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(pid)])
                   assert_receive {:DOWN, ^ref, :port, ^port, _}, 1_000

                 _ ->
                   :ok
               end
             )

    assert result.cleanup.confirmed, inspect(result.cleanup)
    refute result.complete
    refute result.checks.fault_witnessed
    refute result.checks.target_down_witnessed
  end

  test "a held native guardian prevents acknowledgment while its command lives" do
    key = {__MODULE__, :held_guardian}

    try do
      assert {:ok, [result]} =
               Elara.Lab.run("job_recovery",
                 seed: 42,
                 params: %{"stage" => "stub_running"},
                 hook: fn
                   {:before_fault, %{native: %{guardian: guardian}}} ->
                     Process.put(key, guardian)
                     {_, 0} = System.cmd("kill", ["-STOP", Integer.to_string(guardian)])
                     :ok

                   {:before_cleanup, _} ->
                     {_, 0} = System.cmd("kill", ["-CONT", Integer.to_string(Process.get(key))])
                     Process.delete(key)
                     :ok

                   _ ->
                     :ok
                 end
               )

      assert result.cleanup.confirmed, inspect(result.cleanup)
      assert result.checks.fault_witnessed, inspect(result.error)
      assert result.checks.target_down_witnessed, inspect(result.error)

      assert result.error in [
               [:throw, [:timeout, :held_unknown_epoch]],
               [:throw, [:held_unknown_epoch, [:timeout, :held_unknown_epoch]]]
             ],
             inspect(result.error)

      assert result.job["status"] == "indeterminate"
      assert result.job["slot"] == "held"
      assert result.job["settlement"] == "unknown"
      assert result.epoch.acknowledged == nil
      refute result.checks.native_stopped_before_cleanup
      refute result.checks.held_before_ack
    after
      if guardian = Process.delete(key),
        do: System.cmd("kill", ["-CONT", Integer.to_string(guardian)], stderr_to_stdout: true)
    end
  end

  for stage <- ~w(executor_running stub_running) do
    test "forced failure at #{stage} stops the owned command and guardian" do
      stage = unquote(stage)
      owner = self()

      assert {:ok, [result]} =
               Elara.Lab.run("job_recovery",
                 seed: 42,
                 params: %{"stage" => stage},
                 hook: fn
                   {:before_fault, %{session_pid: source, runner_pid: runner, native: native}} ->
                     send(owner, {:owned_native, source, runner, native})
                     raise "forced native recovery failure"

                   _ ->
                     :ok
                 end
               )

      assert_receive {:owned_native, source, runner, native}, 1_000
      refute Process.alive?(source)
      refute Process.alive?(runner)
      assert result.cleanup.confirmed, inspect(result.cleanup)
      refute result.complete

      for pid <- [native.pid, native.guardian] do
        {state, status} = System.cmd("ps", ["-p", Integer.to_string(pid), "-o", "stat="])

        assert (status == 1 and state == "") or
                 (status == 0 and String.starts_with?(String.trim(state), "Z"))
      end
    end
  end
end
