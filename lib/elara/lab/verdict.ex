defmodule Elara.Lab.Verdict do
  @moduledoc """
  Pure RQ-2 bound rules for one repetition, as pre-registered in note 003. Does
  not judge across repetitions.
  """

  @latency_bound_ms 50
  @memory_ceiling_bytes 5 * 1_048_576
  @throughput_floor 0.95

  @doc """
  `facts`: `compliant`, `complete`, `latency` (`p95`, `cohort`, `cohort_known`,
  `proven_failures`), `memory` (`samples` of `%{t, per_session}`, `from`, `to`,
  `sample_ms`, `baseline`) and `throughput` (`ratio`).
  """
  @spec bounds(map()) :: %{latency: String.t(), memory: String.t(), throughput: String.t()}
  def bounds(%{compliant: false}),
    do: %{latency: "undetermined", memory: "undetermined", throughput: "undetermined"}

  def bounds(%{complete: complete} = facts) do
    %{
      latency: latency(complete, facts.latency),
      memory: memory(complete, facts.memory),
      throughput: throughput(complete, facts.throughput)
    }
  end

  defp latency(complete, %{p95: p95, cohort: cohort} = latency) do
    cond do
      complete and cohort > 0 and is_integer(p95) and p95 < @latency_bound_ms -> "holds"
      complete and cohort > 0 and (p95 == :infinity or p95 >= @latency_bound_ms) -> "fails"
      latency.cohort_known and cohort > 0 and 20 * latency.proven_failures > cohort -> "fails"
      true -> "undetermined"
    end
  end

  defp memory(complete, memory) do
    eligible = Enum.filter(memory.samples, &(&1.t >= memory.from and &1.t < memory.to))

    cond do
      Enum.any?(
        eligible,
        &(is_integer(&1.per_session) and &1.per_session >= @memory_ceiling_bytes)
      ) ->
        "fails"

      complete and memory.baseline and covered?(eligible, memory) ->
        "holds"

      true ->
        "undetermined"
    end
  end

  # Full coverage: every eligible sample available, the first and last within
  # one interval of the edges, and no gap above two intervals.
  defp covered?([], _memory), do: false

  defp covered?(eligible, %{from: from, to: to, sample_ms: interval}) do
    times = Enum.map(eligible, & &1.t)
    gaps = Enum.zip_with(times, tl(times), &(&2 - &1))

    Enum.all?(eligible, &is_integer(&1.per_session)) and hd(times) - from <= interval and
      to - List.last(times) <= interval and Enum.all?(gaps, &(&1 <= 2 * interval))
  end

  defp throughput(true, %{ratio: ratio}) when is_number(ratio),
    do: if(ratio >= @throughput_floor, do: "holds", else: "fails")

  defp throughput(_complete, _throughput), do: "undetermined"

  @doc "The memory ceiling in bytes per session (5 MiB)."
  def memory_ceiling_bytes, do: @memory_ceiling_bytes

  @doc "The latency bound in milliseconds; an observation at or above it fails."
  def latency_bound_ms, do: @latency_bound_ms
end
