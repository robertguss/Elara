defmodule Elara.Lab.Client.Accounting do
  @moduledoc """
  Pure expected -> emitted -> received accounting for one session's deltas.
  Received means unique indices; it never infers an index it did not see.
  """

  defstruct [
    :sim_id,
    :ttft_ms,
    :interval_ms,
    :answer_deltas,
    :window,
    bound_ms: 50,
    requests: %{},
    unattributed: 0,
    post_cutoff: 0,
    out_of_order: 0,
    duplicates: 0,
    invalid: 0
  ]

  @type t :: %__MODULE__{}
  @type row :: {{String.t(), pos_integer()}, integer(), term(), non_neg_integer(), atom()}

  @spec new(keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc "Merge ledger rows for this session; emitted counts and states only move forward."
  @spec ingest(t(), [row()]) :: t()
  def ingest(%__MODULE__{} = acc, rows) do
    Enum.reduce(rows, acc, fn {{_id, request}, started, choice, emitted, state}, acc ->
      update_in(acc.requests, fn requests ->
        Map.update(
          requests,
          request,
          %{
            started: started,
            choice: choice,
            emitted: emitted,
            state: state,
            bits: 0,
            next: 0,
            received: 0
          },
          &%{&1 | emitted: max(&1.emitted, emitted), state: merge_state(&1.state, state)}
        )
      end)
    end)
  end

  defp merge_state(:completed, _state), do: :completed
  defp merge_state(_state, state), do: state

  @doc """
  Account one delta arrival at `now`. `lookup` returns this session's ledger
  rows and is called only when the stamp names a request not yet ingested.
  Returns `{:observed, latency_ms, in_cohort?, in_window?}`, `:post_cutoff` for
  an arrival after `cutoff`, `:duplicate` for an index already received,
  `:invalid` for an index outside the answer, or `:unattributed`.
  """
  @spec arrival(t(), binary(), integer(), integer() | nil, (-> [row()])) :: {t(), term()}
  def arrival(%__MODULE__{} = acc, text, now, cutoff, lookup) do
    with {:ok, request, index} <- parse(text),
         {:ok, acc, entry} <- entry(acc, request, lookup) do
      observe(acc, request, entry, index, now, cutoff)
    else
      {:error, acc} -> {%{acc | unattributed: acc.unattributed + 1}, :unattributed}
      :error -> {%{acc | unattributed: acc.unattributed + 1}, :unattributed}
    end
  end

  defp parse(text) do
    with [request, index] <- text |> String.trim_trailing(".") |> String.split(":"),
         {request, ""} <- Integer.parse(request),
         {index, ""} <- Integer.parse(index) do
      {:ok, request, index}
    else
      _ -> :error
    end
  end

  defp entry(acc, request, lookup) do
    acc = if Map.has_key?(acc.requests, request), do: acc, else: ingest(acc, lookup.())

    case Map.fetch(acc.requests, request) do
      {:ok, %{choice: :answer} = entry} -> {:ok, acc, entry}
      _ -> {:error, acc}
    end
  end

  defp observe(acc, _request, _entry, _index, now, cutoff)
       when is_integer(cutoff) and now > cutoff,
       do: {%{acc | post_cutoff: acc.post_cutoff + 1}, :post_cutoff}

  defp observe(acc, _request, _entry, index, _now, _cutoff)
       when index < 0 or index >= acc.answer_deltas,
       do: {%{acc | invalid: acc.invalid + 1}, :invalid}

  defp observe(acc, request, entry, index, now, _cutoff) do
    if received?(entry, index) do
      {%{acc | duplicates: acc.duplicates + 1}, :duplicate}
    else
      intended = intended(acc, entry, index)
      out_of_order = if index == entry.next, do: 0, else: 1
      bits = Bitwise.bor(entry.bits, Bitwise.bsl(1, index))
      entry = %{entry | bits: bits, received: entry.received + 1}
      entry = %{entry | next: first_missing(entry, entry.next, acc.answer_deltas)}

      acc = %{
        acc
        | requests: Map.put(acc.requests, request, entry),
          out_of_order: acc.out_of_order + out_of_order
      }

      {acc, {:observed, now - intended, in_window?(acc, intended), in_window?(acc, now)}}
    end
  end

  defp received?(entry, index), do: Bitwise.band(Bitwise.bsr(entry.bits, index), 1) == 1

  # The lowest index not yet received, scanning up from the previous lowest.
  defp first_missing(entry, from, limit) do
    if from < limit and received?(entry, from),
      do: first_missing(entry, from + 1, limit),
      else: from
  end

  defp intended(acc, entry, index),
    do: entry.started + acc.ttft_ms + round(index * acc.interval_ms)

  defp in_window?(%__MODULE__{window: {from, to}}, time), do: time >= from and time < to

  @doc "Intended time of the oldest expected delta not yet received, or nil."
  @spec oldest_pending(t()) :: integer() | nil
  def oldest_pending(%__MODULE__{} = acc) do
    acc.requests
    |> Map.values()
    |> Enum.filter(&(&1.choice == :answer and &1.next < acc.answer_deltas))
    |> Enum.map(&intended(acc, &1, &1.next))
    |> Enum.min(fn -> nil end)
  end

  @doc """
  Final counts after merging the final ledger `rows`. `stop_ms` is the cutoff
  (or the end of observation): an unreceived cohort delta is a proven failure
  when `stop_ms - intended >= bound_ms`.
  """
  @spec finalize(t(), [row()], integer()) :: map()
  def finalize(%__MODULE__{} = acc, rows, stop_ms) do
    acc = ingest(acc, rows)
    entries = Map.values(acc.requests)
    answers = Enum.filter(entries, &(&1.choice == :answer))
    completed = Enum.filter(answers, &(&1.state == :completed))

    cohort =
      for entry <- answers, index <- 0..(acc.answer_deltas - 1)//1 do
        intended = intended(acc, entry, index)

        {in_window?(acc, intended), not received?(entry, index),
         stop_ms - intended >= acc.bound_ms}
      end

    in_cohort = Enum.filter(cohort, &elem(&1, 0))
    unreceived = Enum.filter(in_cohort, &elem(&1, 1))

    %{
      answers: length(answers),
      completed_answers: length(completed),
      expected: length(answers) * acc.answer_deltas,
      emitted: sum(answers, :emitted),
      received: sum(answers, :received),
      expected_unemitted: Enum.sum(Enum.map(answers, &max(acc.answer_deltas - &1.emitted, 0))),
      emitted_unreceived: Enum.sum(Enum.map(answers, &max(&1.emitted - &1.received, 0))),
      expected_in_cohort: length(in_cohort),
      received_in_cohort: length(in_cohort) - length(unreceived),
      unreceived_in_cohort: length(unreceived),
      proven_late_unreceived: Enum.count(unreceived, &elem(&1, 2)),
      non_compliant_answers: Enum.count(completed, &(&1.emitted != acc.answer_deltas)),
      fully_received_answers: Enum.count(completed, &(&1.received == acc.answer_deltas)),
      interrupted: Enum.count(entries, &(&1.state != :completed)),
      unattributed: acc.unattributed,
      post_cutoff: acc.post_cutoff,
      out_of_order: acc.out_of_order,
      duplicates: acc.duplicates,
      invalid: acc.invalid
    }
  end

  defp sum(entries, key), do: entries |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum()
end
