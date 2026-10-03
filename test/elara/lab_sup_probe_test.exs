defmodule Elara.Lab.SupProbeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Elara.Lab.{RunningTrace, SupProbe}

  defmodule BlockedChild do
    @moduledoc false
    use GenServer

    def start_link(test), do: GenServer.start_link(__MODULE__, test)

    @impl true
    def init(test) do
      send(test, {:in_init, self()})

      receive do
        :go -> {:ok, nil}
      end
    end
  end

  defp agent_spec,
    do: %{id: :agent, start: {Agent, :start_link, [fn -> 0 end]}, restart: :temporary}

  defp wait_for(done?, tries \\ 200) do
    cond do
      done?.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> Process.sleep(10) && wait_for(done?, tries - 1)
    end
  end

  describe "classify/1" do
    test "one message of each class gives exactly one count per class" do
      from = {self(), make_ref()}

      messages = [
        {:"$gen_call", from, {:start_child, agent_spec()}},
        {:"$gen_call", from, :which_children},
        {:"$gen_call", from, :count_children},
        {:"$gen_call", from, {:terminate_child, self()}},
        {:"$gen_call", from, {:something_unknown, 1}},
        {:EXIT, self(), :normal},
        :not_a_tuple
      ]

      assert SupProbe.classify(messages) == %{
               start_child: 1,
               which_children: 1,
               count_children: 1,
               terminate_child: 1,
               other_call: 1,
               exit: 1,
               other: 1
             }
    end

    test "a mailbox of three start_child calls and two exits counts both" do
      from = {self(), make_ref()}
      calls = for _ <- 1..3, do: {:"$gen_call", from, {:start_child, agent_spec()}}
      exits = for _ <- 1..2, do: {:EXIT, self(), :shutdown}

      counts = SupProbe.classify(calls ++ exits)
      assert counts.start_child == 3 and counts.exit == 2
      assert counts.other == 0 and counts.other_call == 0
    end
  end

  describe "read/1" do
    test "a suspended supervisor's queue is counted by class without keeping payloads" do
      {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
      :ok = :sys.suspend(sup)
      spawn(fn -> DynamicSupervisor.which_children(sup) end)
      spawn(fn -> DynamicSupervisor.start_child(sup, agent_spec()) end)
      wait_for(fn -> Process.info(sup, :message_queue_len) == {:message_queue_len, 2} end)

      reading = SupProbe.read(sup)

      assert reading.available
      assert reading.queue_len == 2
      assert reading.composition.which_children == 1
      assert reading.composition.start_child == 1
      assert is_integer(reading.read_us) and reading.read_us >= 0
      assert is_integer(reading.run_queue)
      assert is_binary(reading.current_function)
      assert is_list(reading.frames) and length(reading.frames) <= 4
      assert Enum.all?(reading.frames, &is_binary/1)
      assert is_binary(JSON.encode!(reading))

      :ok = :sys.resume(sup)
    end

    test "a dead target is unavailable, never zeros" do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, _, _, _}

      assert SupProbe.read(pid) == %{available: false}
      assert SupProbe.read(:no_such_registered_name_for_probe) == %{available: false}
    end

    test "a supervisor blocked in a child's init reads waiting inside sync_start" do
      {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
      test = self()

      spawn(fn ->
        spec = %{id: :blocked, start: {BlockedChild, :start_link, [test]}, restart: :temporary}
        DynamicSupervisor.start_child(sup, spec)
      end)

      assert_receive {:in_init, child}, 5_000
      reading = SupProbe.read(sup)

      assert reading.available
      assert reading.status == :waiting
      assert ":proc_lib.sync_start/2" in reading.frames

      send(child, :go)
    end

    test "a helper that crashes is an unavailable reading, promptly and silently" do
      started = System.monotonic_time(:millisecond)

      log =
        capture_log(fn ->
          assert SupProbe.read("not a process") == %{available: false}
          # An error report from a crashed helper would arrive after the helper's DOWN.
          Process.sleep(100)
        end)

      assert System.monotonic_time(:millisecond) - started < 2_000
      assert log == ""
    end
  end

  describe "RunningTrace.stop/2" do
    test "a tracer that cannot answer in time is unavailable within the timeout" do
      target = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, tracer} = RunningTrace.start(self(), target, 20)
      :erlang.suspend_process(tracer)
      started = System.monotonic_time(:millisecond)

      assert RunningTrace.stop(tracer, 100) == :unavailable
      assert System.monotonic_time(:millisecond) - started < 1_000

      Process.exit(tracer, :kill)
      Process.exit(target, :kill)
    end

    test "a tracer that died is unavailable, not an empty trace" do
      target = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, tracer} = RunningTrace.start(self(), target, 20)
      Process.exit(tracer, :kill)

      assert RunningTrace.stop(tracer, 1_000) == :unavailable
      Process.exit(target, :kill)
    end
  end

  describe "RunningTrace buckets" do
    defp spin_until(at),
      do: if(System.monotonic_time(:millisecond) < at, do: spin_until(at), else: :ok)

    # The real monotonic clock, which is negative here: no time is shifted.
    test "every bucket stays within its own bounds and holds the events that happened in it" do
      test = self()
      bucket_ms = 100

      target =
        spawn(fn ->
          receive do: (:go -> send(test, {:started, System.monotonic_time(:millisecond)}))
          spin_until(System.monotonic_time(:millisecond) + 250)
          receive do: (:again -> :ok)
          receive do: (:never -> :ok)
        end)

      {:ok, tracer} = RunningTrace.start(self(), target, bucket_ms)
      before = System.monotonic_time(:millisecond)
      send(target, :go)
      assert_receive {:started, started}, 2_000
      # Wait past the spin's end and a few more buckets, off CPU in the target.
      spin_until(started + 600)
      send(target, :again)
      Process.sleep(50)
      buckets = RunningTrace.stop(tracer, 5_000)

      assert before < 0 and buckets != []

      for b <- buckets do
        assert rem(b.start, bucket_ms) == 0
        off = b.off_us |> Map.values() |> Enum.sum()
        assert b.running_us + off <= bucket_ms * 1000, inspect(b)
      end

      # The schedule-in happened between `before` and `started`.
      [first | _] = Enum.filter(buckets, &(&1.ins > 0))
      assert first.start <= started and before < first.start + bucket_ms

      # On-CPU time is positive and cannot exceed the 250 ms wall-clock spin by much.
      running = Enum.sum(Enum.map(buckets, & &1.running_us))
      assert running > 0 and running <= 300_000
      Process.exit(target, :kill)
    end
  end
end
