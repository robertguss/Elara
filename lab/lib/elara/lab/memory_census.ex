defmodule Elara.Lab.MemoryCensus do
  @moduledoc """
  What holds memory at one time, per process class. Holders, not allocation:
  it does not explain a peak or where memory was allocated, and its readings are
  not simultaneous, so totals are not reconciled.
  """

  @doc """
  A raw, timestamped capture of `pids` (monotonic ms). `member?.(pid)` is read
  at capture time; a pid it rejects is unmeasured. Classification comes later,
  in `summarize/2`.
  """
  @spec capture([pid()], (pid() -> boolean())) :: map()
  def capture(pids, member?) do
    started = System.monotonic_time(:millisecond)
    memory = Map.new(:erlang.memory())

    processes =
      for pid <- pids,
          member?.(pid),
          info = Process.info(pid, [:memory, :binary]),
          info != nil,
          do:
            {pid, info[:memory],
             Enum.map(info[:binary], fn {addr, size, _refc} -> {addr, size} end)}

    binary_memory = :erlang.memory(:binary)
    wordsize = :erlang.system_info(:wordsize)

    ets =
      for table <- :ets.all(),
          owner = safe_ets(table, :owner),
          words = safe_ets(table, :memory),
          is_pid(owner) and is_integer(words),
          do: {table, owner, words * wordsize}

    %{
      started_ms: started,
      ended_ms: System.monotonic_time(:millisecond),
      memory: memory,
      processes: processes,
      binary_memory: binary_memory,
      ets: ets
    }
  end

  @doc """
  Join a capture to classes. `classify.(pid)` returns a class, or nil for
  unmeasured. Each off-heap binary (by address) is exclusive to the one class
  that references it, or in the shared bucket; the buckets sum to the unique
  total. Its difference from `:erlang.memory(:binary)` is reported with its sign
  and attributed to nothing.
  """
  @spec summarize(map(), (pid() -> atom() | nil)) :: map()
  def summarize(capture, classify) do
    measured =
      for {pid, bytes, binaries} <- capture.processes,
          class = classify.(pid),
          class != nil,
          do: {class, bytes, binaries}

    holders =
      Enum.reduce(measured, %{}, fn {class, _bytes, binaries}, acc ->
        Enum.reduce(binaries, acc, fn {addr, size}, acc ->
          Map.update(acc, addr, {size, MapSet.new([class])}, fn {s, cs} ->
            {s, MapSet.put(cs, class)}
          end)
        end)
      end)

    # Pair figures overlap when three or more classes share a binary, so the
    # shared total is summed separately, never from the pairs.
    {exclusive, shared, pairs} =
      Enum.reduce(holders, {%{}, 0, %{}}, fn {_addr, {size, classes}},
                                             {exclusive, shared, pairs} ->
        case classes |> Enum.map(&Atom.to_string/1) |> Enum.sort() do
          [_one] ->
            {Map.update(exclusive, Enum.at(MapSet.to_list(classes), 0), size, &(&1 + size)),
             shared, pairs}

          many ->
            pairs =
              for {x, i} <- Enum.with_index(many),
                  y <- Enum.drop(many, i + 1),
                  reduce: pairs,
                  do: (pairs -> Map.update(pairs, "#{x}+#{y}", size, &(&1 + size)))

            {exclusive, shared + size, pairs}
        end
      end)

    classes =
      measured
      |> Enum.group_by(&elem(&1, 0))
      |> Map.new(fn {class, rows} ->
        {class,
         %{
           pids: length(rows),
           process_bytes: rows |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
           binary_exclusive_bytes: Map.get(exclusive, class, 0)
         }}
      end)

    unique = (exclusive |> Map.values() |> Enum.sum()) + shared

    ets =
      for {table, owner, bytes} <- capture.ets do
        %{table: inspect(table), class: classify.(owner) || :unmeasured, bytes: bytes}
      end

    %{
      started_ms: capture.started_ms,
      ended_ms: capture.ended_ms,
      memory: capture.memory,
      classes: classes,
      binary_shared: %{bytes: shared, pairs: pairs},
      binary_unique_total: unique,
      binary_memory: capture.binary_memory,
      unreconciled_binary_difference: capture.binary_memory - unique,
      ets: ets,
      ets_by_class:
        ets |> Enum.group_by(& &1.class, & &1.bytes) |> Map.new(fn {c, b} -> {c, Enum.sum(b)} end)
    }
  end

  defp safe_ets(table, item) do
    :ets.info(table, item)
  rescue
    ArgumentError -> nil
  end
end
