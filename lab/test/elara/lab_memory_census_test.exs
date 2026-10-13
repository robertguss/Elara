defmodule Elara.Lab.MemoryCensusTest do
  use ExUnit.Case, async: true

  alias Elara.Lab.MemoryCensus

  @mib 1_048_576

  # A process that holds `binaries` (and optionally an ETS table) until told to stop.
  defp holder(binaries, opts \\ []) do
    parent = self()

    pid =
      spawn(fn ->
        table = if opts[:ets], do: :ets.new(:census_test, [:public])
        if table, do: :ets.insert(table, {:key, :binary.copy("x", 4096)})
        send(parent, {:ready, self(), table})
        receive(do: (:stop -> binaries))
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:ready, ^pid, table}
    {pid, table}
  end

  test "a binary held by one class is exclusive to it; one held by two is shared by that pair" do
    own = :binary.copy("a", @mib)
    both = :binary.copy("b", @mib)
    {a, _} = holder([own, both])
    {b, _} = holder([both])
    {c, _} = holder([])

    classes = %{a => :session, b => :task, c => :exec}
    capture = MemoryCensus.capture([a, b, c], fn _ -> true end)
    summary = MemoryCensus.summarize(capture, &Map.get(classes, &1))

    assert summary.classes.session.binary_exclusive_bytes == @mib
    assert summary.classes.task.binary_exclusive_bytes == 0
    assert summary.binary_shared.bytes == @mib
    assert summary.binary_shared.pairs == %{"session+task" => @mib}
    assert summary.binary_unique_total == 2 * @mib
    assert summary.classes.exec.pids == 1
  end

  test "a binary shared by three classes adds to each pair, and once to the shared total" do
    three = :binary.copy("t", @mib)
    holders = for class <- [:session, :task, :connection], do: {elem(holder([three]), 0), class}
    classes = Map.new(holders)
    capture = MemoryCensus.capture(Map.keys(classes), fn _ -> true end)
    summary = MemoryCensus.summarize(capture, &Map.get(classes, &1))

    assert summary.binary_shared.bytes == @mib
    assert summary.binary_unique_total == @mib

    assert summary.binary_shared.pairs == %{
             "connection+session" => @mib,
             "connection+task" => @mib,
             "session+task" => @mib
           }
  end

  test "process memory sums only live measured pids of each class" do
    {a, _} = holder([])
    {b, _} = holder([])
    {c, _} = holder([])
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, _, _, _}

    capture = MemoryCensus.capture([a, b, c, dead], &(&1 != c))
    classes = %{a => :session, b => :session, c => :session, dead => :session}
    summary = MemoryCensus.summarize(capture, &Map.get(classes, &1))

    {:memory, ma} = Process.info(a, :memory)
    {:memory, mb} = Process.info(b, :memory)
    assert summary.classes.session.pids == 2
    assert_in_delta summary.classes.session.process_bytes, ma + mb, 2_048
  end

  test "an unmeasured pid is not attributed to a class" do
    {a, _} = holder([:binary.copy("u", @mib)])
    capture = MemoryCensus.capture([a], fn _ -> true end)
    summary = MemoryCensus.summarize(capture, fn _ -> nil end)

    assert summary.classes == %{}
    assert summary.binary_unique_total == 0
  end

  test "an ETS table goes to its owner's class, or to unmeasured" do
    {a, table} = holder([], ets: true)
    capture = MemoryCensus.capture([a], fn _ -> true end)
    summary = MemoryCensus.summarize(capture, &if(&1 == a, do: :task))

    row = Enum.find(summary.ets, &(&1.table == inspect(table)))
    assert row.class == :task
    assert row.bytes == :ets.info(table, :memory) * :erlang.system_info(:wordsize)
    assert summary.ets_by_class.task >= row.bytes

    summary = MemoryCensus.summarize(capture, fn _ -> nil end)
    assert Enum.find(summary.ets, &(&1.table == inspect(table))).class == :unmeasured
  end

  test "the unreconciled binary difference keeps its sign and is attributed to nothing" do
    {a, _} = holder([:binary.copy("n", @mib)])
    capture = MemoryCensus.capture([a], fn _ -> true end)
    capture = %{capture | binary_memory: 1_000}
    summary = MemoryCensus.summarize(capture, fn _ -> :session end)

    assert summary.binary_memory == 1_000
    assert summary.unreconciled_binary_difference == 1_000 - @mib
  end

  test "a capture records its start and end and the VM's memory categories" do
    {a, _} = holder([])
    slow = fn _pid -> Process.sleep(20) || true end
    capture = MemoryCensus.capture([a], slow)
    summary = MemoryCensus.summarize(capture, fn _ -> nil end)

    assert summary.ended_ms - summary.started_ms >= 20
    assert Map.has_key?(summary.memory, :system) and Map.has_key?(summary.memory, :binary)
  end
end
