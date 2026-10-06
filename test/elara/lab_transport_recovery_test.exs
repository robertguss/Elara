defmodule Elara.Lab.TransportRecoveryTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 60_000

  for stage <- ~w(client_running handler_running worker_running) do
    test "#{stage} preserves inputs and uncertain remote mutation without replay" do
      assert {:ok, [result]} =
               Elara.Lab.run("transport_recovery",
                 seed: 42,
                 params: %{"stage" => unquote(stage)},
                 hook: fn
                   {:before_fault, actors} ->
                     expected =
                       case unquote(stage) do
                         "client_running" -> actors.client
                         "handler_running" -> actors.handler
                         "worker_running" -> actors.worker
                       end

                     assert actors.target == expected

                     assert Enum.uniq([
                              actors.client,
                              actors.handler,
                              actors.worker,
                              actors.job,
                              actors.guardian
                            ])
                            |> length() == 5

                     shell = :sys.get_state(actors.source)

                     assert Enum.any?(shell.tasks, fn
                              {_, {:tool, _, pid, _}} -> pid == actors.client
                              _ -> false
                            end)

                     {:monitors, monitors} = Process.info(actors.source, :monitors)
                     assert {:process, actors.client} in monitors

                   _ ->
                     :ok
                 end
               )

      assert result.complete, inspect({result.error, result.checks})
      assert Elara.Lab.failed_checks(result) == [], inspect(result)
      assert result.cleanup.confirmed
      assert result.observation.all_completed
      assert result.mutation.outcome == :indeterminate
      assert result.native.after.stopped
      assert result.launches == 1
      assert result.route == :direct_tool_task
      refute result.receipt_backend
      assert result.intent.tool_call_id == "transport-A"
      assert result.intent.arguments == %{"command" => Elara.Lab.NativeGroup.command()}
      assert is_binary(JSON.encode!(result))
    end
  end

  test "a prematurely dead worker cannot count as the nominated fault" do
    assert {:ok, [result]} =
             Elara.Lab.run("transport_recovery",
               seed: 42,
               params: %{"stage" => "worker_running"},
               hook: fn
                 {:before_fault, %{worker: worker}} ->
                   ref = Process.monitor(worker)
                   Process.exit(worker, :kill)
                   assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1_000

                 _ ->
                   :ok
               end
             )

    assert result.cleanup.confirmed, inspect(result.cleanup)
    refute result.complete
    refute result.checks.fault_witnessed
  end

  test "released handler admission invalidates the named held checkpoint" do
    assert {:ok, [result]} =
             Elara.Lab.run("transport_recovery",
               seed: 42,
               params: %{"stage" => "client_running"},
               hook: fn
                 {:before_fault, %{gate: gate}} ->
                   :ok = Elara.Lab.Gate.release(gate, :handler_running)

                 _ ->
                   :ok
               end
             )

    assert result.cleanup.confirmed, inspect(result.cleanup)
    refute result.complete
    refute result.checks.fault_witnessed
  end

  test "forced failure stops real session, TCP and native actors" do
    owner = self()

    assert {:ok, [result]} =
             Elara.Lab.run("transport_recovery",
               seed: 42,
               params: %{"stage" => "worker_running"},
               hook: fn
                 {:before_fault, actors} ->
                   send(owner, {:owned, actors})
                   raise "forced transport preparation failure"

                 _ ->
                   :ok
               end
             )

    assert_receive {:owned, actors}, 1_000
    assert result.cleanup.confirmed, inspect(result.cleanup)
    refute result.complete

    for pid <- [
          actors.source,
          actors.worker,
          actors.client,
          actors.handler,
          actors.job,
          actors.guardian
        ] do
      refute Process.alive?(pid)
    end

    for pid <- [actors.native.root.pid, actors.native.child.pid, actors.native.guardian] do
      assert Elara.Lab.ProcessProbe.stopped?(pid)
    end
  end
end
