defmodule Elara.Lab.Histogram do
  @moduledoc """
  Shared 1 ms-bucket histogram with underflow and overflow. A snapshot is final
  only after every writer has stopped.
  """

  defstruct [:min, :max, :ref]

  @type t :: %__MODULE__{min: integer(), max: integer(), ref: :counters.counters_ref()}
  @type snapshot :: %{
          counts: %{integer() => pos_integer()},
          underflow: non_neg_integer(),
          overflow: non_neg_integer()
        }

  @spec new(integer(), integer()) :: t()
  def new(min, max) when is_integer(min) and is_integer(max) and max >= min,
    do: %__MODULE__{min: min, max: max, ref: :counters.new(max - min + 3, [:write_concurrency])}

  @spec record(t(), integer()) :: :ok
  def record(%__MODULE__{ref: ref} = histogram, value) when is_integer(value),
    do: :counters.add(ref, index(histogram, value), 1)

  defp index(%__MODULE__{min: min}, value) when value < min, do: 1
  defp index(%__MODULE__{min: min, max: max}, value) when value > max, do: max - min + 3
  defp index(%__MODULE__{min: min}, value), do: value - min + 2

  @spec snapshot(t()) :: snapshot()
  def snapshot(%__MODULE__{min: min, max: max, ref: ref}) do
    counts =
      for value <- min..max,
          count = :counters.get(ref, value - min + 2),
          count > 0,
          into: %{},
          do: {value, count}

    %{
      counts: counts,
      underflow: :counters.get(ref, 1),
      overflow: :counters.get(ref, max - min + 3)
    }
  end

  @doc """
  Nearest-rank p50/p95/p99 and max. Underflow ranks lowest as `:neg_infinity`;
  overflow and `extra_infinite` (for example, never-received observations)
  rank highest as `:infinity`. Nil when there are no observations.
  """
  @spec percentiles(snapshot(), non_neg_integer()) :: map() | nil
  def percentiles(snapshot, extra_infinite \\ 0) do
    infinite = snapshot.overflow + extra_infinite
    count = snapshot.underflow + Enum.sum(Map.values(snapshot.counts)) + infinite

    if count == 0 do
      nil
    else
      ranked =
        [{:neg_infinity, snapshot.underflow}] ++
          Enum.sort(snapshot.counts) ++ [{:infinity, infinite}]

      rank = fn p -> at_rank(ranked, max(ceil(p * count), 1)) end

      %{
        count: count,
        p50: rank.(0.5),
        p95: rank.(0.95),
        p99: rank.(0.99),
        max: at_rank(ranked, count)
      }
    end
  end

  defp at_rank([{value, n} | _rest], rank) when rank <= n, do: value
  defp at_rank([{_value, n} | rest], rank), do: at_rank(rest, rank - n)

  @doc "Observations at or above `threshold`, overflow included."
  @spec at_least(snapshot(), integer()) :: non_neg_integer()
  def at_least(snapshot, threshold),
    do:
      snapshot.overflow +
        Enum.sum(for {value, n} <- snapshot.counts, value >= threshold, do: n)
end
