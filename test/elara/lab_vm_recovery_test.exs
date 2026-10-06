defmodule Elara.Lab.VMRecoveryTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 60_000

  for stage <- ~w(provider_running mutation_running) do
    test "#{stage} recovers disk inputs after externally witnessed VM death" do
      owner = self()

      assert {:ok, [result]} =
               Elara.Lab.run("vm_recovery",
                 seed: 42,
                 params: %{"stage" => unquote(stage)},
                 hook: fn
                   {:before_fault, actors} ->
                     send(owner, {:owned, actors})
                     assert actors.target == actors.vm.os_pid
                     assert actors.target != actors.vm.stub
                     assert List.last(actors.vm.ancestors).pid == String.to_integer(System.pid())
                     assert actors.vm.port_owned

                   _ ->
                     :ok
                 end
               )

      assert result.complete, inspect({result.error, result.checks})
      assert_receive {:owned, actors}, 1_000
      assert Elara.Lab.failed_checks(result) == [], inspect(result)
      assert result.cleanup.confirmed
      assert result.observation.inputs["A"].state == :failed
      assert result.observation.inputs["B"].completed
      assert result.observation.inputs["C"].completed
      assert result.fault.exit_status == 137
      assert result.fault.vm_stopped
      assert result.reopened.os_pid != actors.target
      assert result.reopened.boot_id != result.source.boot_id
      assert result.source.max_restarts == 3
      assert result.reopened.max_restarts == 3
      assert result.launches == if(unquote(stage) == "mutation_running", do: 1, else: 0)
      assert is_binary(JSON.encode!(result))
    end
  end

  test "premature VM loss cannot count as the nominated fault" do
    owner = self()

    assert {:ok, [result]} =
             Elara.Lab.run("vm_recovery",
               seed: 42,
               hook: fn
                 {:before_fault, actors} ->
                   send(owner, {:owned, actors})
                   assert {_, 0} = System.cmd("kill", ["-KILL", to_string(actors.target)])
                   assert eventually(fn -> Elara.Lab.ProcessProbe.stopped?(actors.target) end)
                   assert eventually(fn -> Elara.Lab.VM.snapshot(actors.owner).port_down end)
                   assert {:error, :exited_or_unowned_port} = Elara.Lab.VM.kill(actors.owner)

                 _ ->
                   :ok
               end
             )

    refute result.complete
    assert_receive {:owned, _}, 1_000
    refute result.checks.fault_witnessed
    assert result.cleanup.confirmed, inspect(result.cleanup)
  end

  test "a released provider checkpoint cannot count as a held fault" do
    owner = self()

    assert {:ok, [result]} =
             Elara.Lab.run("vm_recovery",
               seed: 42,
               hook: fn
                 {:before_fault, actors} ->
                   File.write!(Path.join(actors.root, "release-provider"), "release")
                   source = Elara.Lab.VM.read(actors.root, "source")

                   assert eventually(fn ->
                            {:ok, view} =
                              Elara.Lab.InputObserver.read(
                                source["path"],
                                Elara.Lab.Scenarios.VMRecovery.expected()
                              )

                            view.inputs["A"].completed
                          end)

                   send(owner, {:released, actors.target})

                 _ ->
                   :ok
               end
             )

    assert_receive {:released, _}, 1_000
    refute result.complete
    refute result.checks.fault_witnessed
    assert result.cleanup.confirmed, inspect(result.cleanup)
  end

  test "forced failure cleans actual VM, stub and native descendants" do
    owner = self()

    assert {:ok, [result]} =
             Elara.Lab.run("vm_recovery",
               seed: 42,
               params: %{"stage" => "mutation_running"},
               hook: fn
                 {:before_fault, actors} ->
                   send(owner, {:owned, actors})
                   raise "forced whole-VM failure"

                 _ ->
                   :ok
               end
             )

    refute result.complete
    assert [:exception, "forced whole-VM failure", _] = result.error
    assert_receive {:owned, actors}, 1_000
    assert result.cleanup.confirmed, inspect(result.cleanup)
    refute Process.alive?(actors.owner)

    for pid <- [
          actors.target,
          actors.vm.stub,
          actors.native.root.pid,
          actors.native.child.pid,
          actors.native.guardian
        ] do
      assert Elara.Lab.ProcessProbe.stopped?(pid), inspect(pid)
    end
  end

  test "controller death stops its actual external VM and native stub" do
    root = Path.join(System.tmp_dir!(), "vm-owner-#{System.unique_integer([:positive])}")
    Enum.each(~w(workspace home), &File.mkdir_p!(Path.join(root, &1)))
    Elara.Lab.VM.write(root, "schedule", %{order: ~w(B C), work_ms: 1})
    owner = self()

    controller =
      spawn(fn ->
        {:ok, vm} =
          Elara.Lab.VM.start(root, "prepare", Elara.Lab.VMRecoveryPeer, [
            root,
            "prepare",
            "provider_running",
            "1",
            "controller-death-control"
          ])

        send(owner, {:vm_owner, vm})
        Process.sleep(:infinity)
      end)

    ref = Process.monitor(controller)
    cleanup_key = {__MODULE__, :external_vm}
    Process.put(cleanup_key, nil)

    try do
      assert_receive {:vm_owner, vm}, 1_000
      Process.put(cleanup_key, vm)
      boot = Elara.Lab.VM.wait(fn -> Elara.Lab.VM.read(root, "prepare-boot") end, 5_000)
      assert boot != nil
      assert boot["boot_id"] == "controller-death-control"
      assert Elara.Lab.VM.snapshot(vm).os_pid == boot["os_pid"]
      Process.exit(controller, :kill)
      assert_receive {:DOWN, ^ref, :process, ^controller, :killed}, 1_000
      assert eventually(fn -> not Process.alive?(vm) end)
      assert eventually(fn -> Elara.Lab.ProcessProbe.stopped?(boot["os_pid"]) end)
      assert eventually(fn -> Elara.Lab.ProcessProbe.stopped?(boot["stub"]) end)
    after
      Process.exit(controller, :kill)
      Process.demonitor(ref, [:flush])
      vm = Process.delete(cleanup_key)
      if is_pid(vm) and Process.alive?(vm), do: Elara.Lab.VM.stop(vm)

      case Elara.Lab.VM.read(root, "prepare-boot") do
        nil ->
          :ok

        boot ->
          assert eventually(fn ->
                   Elara.Lab.ProcessProbe.stopped?(boot["os_pid"]) and
                     Elara.Lab.ProcessProbe.stopped?(boot["stub"])
                 end)

          File.rm_rf!(root)
      end
    end
  end

  defp eventually(fun, tries \\ 200)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, tries) do
    fun.() or
      (
        Process.sleep(10)
        eventually(fun, tries - 1)
      )
  end
end
