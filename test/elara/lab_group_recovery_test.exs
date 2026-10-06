defmodule Elara.Lab.GroupRecoveryTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 60_000

  for stage <- ~w(owner_running executor_running stub_running) do
    test "#{stage} stops the witnessed ordinary command group" do
      assert {:ok, [result]} =
               Elara.Lab.run("group_recovery",
                 seed: 42,
                 params: %{"stage" => unquote(stage)}
               )

      assert result.complete, inspect({result.error, result.checks})
      assert Elara.Lab.failed_checks(result) == [], inspect(result)
      assert result.cleanup.confirmed
      assert result.native.before.root.pgid == result.native.before.child.pgid
      assert result.native.before.child.parent == result.native.before.root.pid
      assert result.native.after.stopped
      assert result.launches == 1
      assert is_binary(JSON.encode!(result))
    end
  end

  test "an ordinary child which exits before nomination rejects the fault" do
    assert {:ok, [result]} =
             Elara.Lab.run("group_recovery",
               seed: 42,
               params: %{"stage" => "stub_running"},
               hook: fn
                 {:before_fault, %{native: %{child: child}}} ->
                   {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(child.pid)])
                   deadline = System.monotonic_time(:millisecond) + 1_000

                   wait = fn wait ->
                     case Elara.Lab.ProcessProbe.info(child.pid) do
                       {:ok, nil} ->
                         :ok

                       {:ok, %{stat: "Z" <> _}} ->
                         :ok

                       _ ->
                         assert System.monotonic_time(:millisecond) < deadline
                         Process.sleep(5)
                         wait.(wait)
                     end
                   end

                   wait.(wait)

                 _ ->
                   :ok
               end
             )

    assert result.cleanup.confirmed, inspect(result.cleanup)
    refute result.complete
    refute result.checks.fault_witnessed
  end

  test "a held guardian cannot hide a living ordinary child" do
    key = {__MODULE__, :held_guardian}
    owner = self()

    try do
      assert {:ok, [result]} =
               Elara.Lab.run("group_recovery",
                 seed: 42,
                 params: %{"stage" => "stub_running"},
                 hook: fn
                   {:before_fault, %{native: native}} ->
                     Process.put(key, native.guardian)
                     Process.put({key, :child}, native.child.pid)
                     {_, 0} = System.cmd("kill", ["-STOP", Integer.to_string(native.guardian)])

                     assert {:ok, %{stat: "T" <> _}} =
                              Elara.Lab.ProcessProbe.info(native.guardian)

                   {:before_cleanup, _} ->
                     guardian = Process.delete(key)
                     {:ok, child} = Elara.Lab.ProcessProbe.info(Process.get({key, :child}))
                     send(owner, {:live_child, child})
                     {_, 0} = System.cmd("kill", ["-CONT", Integer.to_string(guardian)])
                     :ok

                   _ ->
                     :ok
                 end
               )

      assert_receive {:live_child, child}, 1_000
      assert is_map(child)
      refute String.starts_with?(child.stat, "Z")
      assert result.cleanup.confirmed, inspect(result.cleanup)
      assert result.checks.fault_witnessed
      assert result.checks.target_down_witnessed
      refute result.native.after.stopped
      refute result.checks.native_stopped_before_cleanup
      refute result.complete
    after
      if guardian = Process.delete(key),
        do: System.cmd("kill", ["-CONT", Integer.to_string(guardian)], stderr_to_stdout: true)

      Process.delete({key, :child})
    end
  end

  for stage <- ~w(owner_running stub_running) do
    test "forced failure at #{stage} stops actual native actors" do
      owner = self()

      assert {:ok, [result]} =
               Elara.Lab.run("group_recovery",
                 seed: 42,
                 params: %{"stage" => unquote(stage)},
                 hook: fn
                   {:before_fault, %{owner: caller, native: native}} ->
                     send(owner, {:owned, caller, native})
                     raise "forced ordinary-group preparation failure"

                   _ ->
                     :ok
                 end
               )

      assert_receive {:owned, caller, native}, 1_000
      refute Process.alive?(caller)
      assert result.cleanup.confirmed, inspect(result.cleanup)
      refute result.complete

      for pid <- [native.root.pid, native.child.pid, native.guardian] do
        assert Elara.Lab.ProcessProbe.stopped?(pid)
      end

      assert {:ok, members} = Elara.Lab.ProcessProbe.group(native.root.pgid)
      assert Enum.all?(members, &String.starts_with?(&1.stat, "Z"))
    end
  end
end
