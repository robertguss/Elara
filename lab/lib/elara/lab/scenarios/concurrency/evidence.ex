defmodule Elara.Lab.Scenarios.Concurrency.Evidence do
  @moduledoc """
  Pure reconciliation of a concurrency run's own reports against persisted
  sessions and settlement facts. It judges records, not causes.
  """

  @doc """
  Confirmed only when nothing the run started survives, execution settled in its
  epoch, and (children topology) Threads and the report transport are quiescent,
  settled and held, unchanged since the run began.
  """
  @spec cleanup_confirmed?(map()) :: boolean()
  def cleanup_confirmed?(facts) do
    facts.leftover_users == 0 and facts.leftover_sessions == 0 and facts.leftover_tasks == 0 and
      facts.leftover_clients == 0 and facts.exec_jobs_pending == 0 and
      not facts.exec_epoch_changed and facts.leftover_watchers == 0 and
      facts.threads_quiescent and facts.transport_quiescent and facts.reports_settled and
      facts.children_stopped and facts.actors_held and facts.actors_unchanged
  end

  @doc """
  Completion reports from the transport's files: `completions` (each with its
  file `key` and `recipient`) and decoded `messages`. A staged completion is
  settled once its message exists, or once its recipient has 64 pending
  messages, where the transport stops accepting without writing. It counts
  files, not causes.
  """
  @spec reports([map()], [map()]) :: map()
  def reports(completions, messages) do
    keys = MapSet.new(messages, & &1["key"])

    pending =
      Enum.frequencies(for %{"delivery" => "pending", "recipient" => r} <- messages, do: r)

    reports = Enum.filter(messages, &(&1["kind"] == "report"))

    %{
      staged: length(completions),
      accepted: length(reports),
      delivered: Enum.count(reports, &(&1["delivery"] == "accepted")),
      pending: Enum.count(reports, &(&1["delivery"] == "pending")),
      settled:
        Enum.all?(
          completions,
          &(MapSet.member?(keys, &1["key"]) or Map.get(pending, &1["recipient"], 0) >= 64)
        )
    }
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

  @doc """
  Failed persisted tool results (`ok?` flags), in a stopped run too. Entry
  timestamps are wall-clock under a warping time offset, so they cannot place a
  result relative to the monotonic cutoff; counting every failure errs toward
  noncompliance.
  """
  @spec tool_failures([boolean()]) :: non_neg_integer()
  def tool_failures(results), do: Enum.count(results, &(not &1))
end
