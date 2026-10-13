defmodule Elara.Lab.GateTest do
  use ExUnit.Case, async: false
  alias Elara.Lab.{Gate, GatedScripted}
  alias Elara.Message.Assistant

  test "closing admission snapshots existing callers and rejects work starting afterward" do
    {:ok, gate} = Gate.start_link()
    Process.unlink(gate)
    {:ok, script} = Agent.start_link(fn -> [{:ok, %Assistant{text: "unused"}}] end)
    parent = self()

    {worker, ref} =
      spawn_monitor(fn ->
        :ok = Gate.observe(gate, :existing)
        send(parent, :admitted)

        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn ->
      Process.exit(worker, :kill)
      if Process.alive?(gate), do: Gate.stop(gate)
      if Process.alive?(script), do: Agent.stop(script)
    end)

    assert_receive :admitted, 1_000
    assert [%{caller: ^worker}] = Gate.close(gate)

    {late, late_ref} =
      spawn_monitor(fn ->
        result =
          try do
            GatedScripted.stream(
              %{gate: gate, script: script, input: nil},
              %Elara.Provider.Request{messages: []},
              fn _ -> :ok end
            )
          rescue
            e in MatchError -> {:rejected, e.term}
          end

        send(parent, {:late, result})
      end)

    on_exit(fn -> Process.exit(late, :kill) end)
    assert_receive {:late, {:rejected, {:error, :closed}}}, 1_000
    assert_receive {:DOWN, ^late_ref, :process, ^late, :normal}, 1_000
    assert Agent.get(script, & &1) == [{:ok, %Assistant{text: "unused"}}]
    assert Gate.stop(gate)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1_000
    refute Process.alive?(gate)
  end
end
