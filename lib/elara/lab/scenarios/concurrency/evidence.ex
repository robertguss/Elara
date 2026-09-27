defmodule Elara.Lab.Scenarios.Concurrency.Evidence do
  @moduledoc """
  Pure reconciliation of a concurrency run's own reports against persisted
  sessions and settlement facts. It judges records, not causes.
  """

  @doc "Confirmed only when nothing the run started survives and execution settled in its epoch."
  @spec cleanup_confirmed?(map()) :: boolean()
  def cleanup_confirmed?(facts) do
    facts.leftover_users == 0 and facts.leftover_sessions == 0 and facts.leftover_tasks == 0 and
      facts.leftover_clients == 0 and facts.exec_jobs_pending == 0 and
      not facts.exec_epoch_changed
  end

  @doc """
  Reconcile `reported` session ids and `turns` (`{session_id, ok?}`, returned
  before any cutoff) with `persisted` records (`%{id, answers}`). Every reported
  session must be persisted exactly once, and its persisted answers must equal
  its completed turns. A `censored` run may also persist sessions or answers
  that completed after the cutoff, never fewer.
  """
  @spec reconcile([String.t()], [{String.t(), boolean()}], [map()], boolean()) :: map()
  def reconcile(reported, turns, persisted, censored) do
    reported = Enum.uniq(reported)
    records = Enum.frequencies(Enum.map(persisted, & &1.id))
    answers = Map.new(persisted, &{&1.id, &1.answers})
    completed = Enum.frequencies(for {id, true} <- turns, do: id)

    missing = Enum.reject(reported, &Map.has_key?(records, &1))
    duplicated = for {id, n} <- records, n > 1, do: id
    extra = Map.keys(records) -- reported

    short =
      for id <- reported,
          have = Map.get(answers, id, 0),
          want = Map.get(completed, id, 0),
          if(censored, do: have < want, else: have != want),
          do: id

    %{
      sessions_persisted: missing == [] and duplicated == [] and (censored or extra == []),
      answers_persisted: short == [],
      missing_sessions: length(missing),
      duplicated_sessions: length(duplicated),
      extra_sessions: length(extra),
      short_sessions: length(short)
    }
  end

  @doc "Failed tool results (`{monotonic_ms, ok?}`) persisted at or before `cutoff` (all when nil)."
  @spec tool_failures([{integer(), boolean()}], integer() | nil) :: non_neg_integer()
  def tool_failures(results, cutoff),
    do: Enum.count(results, fn {at, ok} -> not ok and (cutoff == nil or at <= cutoff) end)
end
