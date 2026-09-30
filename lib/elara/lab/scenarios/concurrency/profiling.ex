defmodule Elara.Lab.Scenarios.Concurrency.Profiling do
  @moduledoc """
  A concurrency run's attribution profile (note 003): a memory census, then
  activation; after the freeze, a second census, then collection in a collector
  linked to its owner, whose outcome waits in a holder that no receive loop
  reads. It ranks nothing and judges no bound.
  """

  alias Elara.Lab.{MemoryCensus, Profile}

  @poll_ms 50

  @doc """
  Census the named classes' memory, then activate the profile with `opts`
  (`Profile.activate/1`'s). Nothing outside the named classes is measured by
  this first census.
  """
  @spec start(keyword()) :: map()
  def start(opts) do
    census =
      Profile.census(
        clients: Keyword.fetch!(opts, :clients),
        connections: Keyword.fetch!(opts, :connections)
      )

    classes = Map.new(census)
    capture = MemoryCensus.capture(Map.keys(classes), fn _pid -> true end)

    %{
      before: MemoryCensus.summarize(capture, &Map.get(classes, &1)),
      handle: Profile.activate(opts),
      capture: nil,
      holder: nil,
      collector: nil,
      started: nil,
      deadline: nil
    }
  end

  @doc "Freeze the profile's counters (`Profile.freeze/1`)."
  @spec freeze(map()) :: map()
  def freeze(state), do: %{state | handle: Profile.freeze(state.handle)}

  @doc """
  After the freeze: census what the profile traces, then start collecting in a
  collector linked to the caller, due within `limit_ms`. `hook` is a test seam,
  called in the collector with `:profile_collect` and `:profile_collected`.
  """
  @spec collect(map(), pos_integer(), (atom() -> any())) :: map()
  def collect(state, limit_ms, hook) do
    handle = Profile.freeze(state.handle)
    capture = MemoryCensus.capture(Process.list(), &Profile.traced?(handle, &1))
    holder = :ets.new(:lab_profile_outcome, [:set, :public])
    started = now()
    collector = spawn_link(fn -> collector(handle, capture, holder, hook) end)

    %{
      state
      | handle: handle,
        capture: capture,
        holder: holder,
        collector: collector,
        started: started,
        deadline: started + limit_ms
    }
  end

  # Exits normally on every path, so its link only carries its owner's death.
  defp collector(handle, capture, holder, hook) do
    hook.(:profile_collect)
    result = Profile.collect(handle, Enum.map(capture.processes, &elem(&1, 0)))
    memory = MemoryCensus.summarize(capture, &Map.get(result.records, &1))
    publish(holder, {:done, Map.put(result, :after_freeze, memory), now()})
    hook.(:profile_collected)
  catch
    kind, reason -> publish(holder, {:failed, kind, Exception.format_banner(kind, reason), now()})
  end

  # The first outcome stands.
  defp publish(holder, outcome) do
    :ets.insert_new(holder, {:outcome, outcome})
  rescue
    ArgumentError -> false
  end

  @doc "The published outcome, or nil."
  def read(holder) do
    case :ets.lookup(holder, :outcome) do
      [{:outcome, outcome}] -> outcome
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Wait for the collector's outcome until its deadline. An outcome is timely only
  if it was published by the deadline, whenever it is read. An empty holder is
  read again after the collector is seen dead, and after a live one past its
  deadline is cancelled. `:read` replaces `read/1` for the first reads (test seam).
  """
  @spec await(map(), keyword()) :: map()
  def await(state, opts \\ []), do: poll(state, Keyword.get(opts, :read, &read/1))

  defp poll(state, read) do
    case read.(state.holder) do
      nil ->
        cond do
          not Process.alive?(state.collector) ->
            judge(state, read(state.holder), :collection_failed)

          now() >= state.deadline ->
            cancel(state.collector)
            judge(state, read(state.holder), :collection_timeout)

          true ->
            Process.sleep(@poll_ms)
            poll(state, read)
        end

      outcome ->
        judge(state, outcome, nil)
    end
  end

  defp judge(_state, nil, missing),
    do: %{status: missing, result: nil, reason: nil, collection_ms: nil}

  defp judge(state, {:done, result, at}, _missing) do
    status = if at <= state.deadline, do: :ok, else: :collection_timeout
    %{status: status, result: result, reason: nil, collection_ms: at - state.started}
  end

  defp judge(state, {:failed, _kind, reason, at}, _missing) do
    status = if at <= state.deadline, do: :collection_failed, else: :collection_timeout
    %{status: status, result: nil, reason: reason, collection_ms: at - state.started}
  end

  @doc "Cancel the collector if it still runs, then remove the holder. Idempotent."
  @spec join(map() | nil) :: :ok
  def join(%{collector: collector, holder: holder}) when collector != nil do
    cancel(collector)

    try do
      :ets.delete(holder)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  def join(_state), do: :ok

  # Unlinked first, so the kill cannot reach the owner; its exit is confirmed.
  defp cancel(pid) do
    Process.unlink(pid)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    receive do: ({:DOWN, ^ref, :process, _pid, _reason} -> :ok)
  end

  @doc """
  The serializable profile for a run's result. It is ranked only when the
  window is valid or qualified, collection was timely, every run check passed
  and the run is complete; otherwise it is invalid, with every reason kept.
  Without a collection it keeps what the freeze knew: the window, its failures
  and the second census, its measured holders in one `unavailable` class;
  counters are unavailable.
  `facts` are the run's `checks`, `complete` and `incomplete`.
  """
  @spec report(map() | nil, map() | nil, map()) :: map()
  def report(nil, _outcome, facts),
    do: %{
      validity: invalid(%{status: :invalid, reasons: []}, [:not_activated | run_reasons(facts)])
    }

  def report(state, outcome, facts) do
    collection = if outcome.status == :ok, do: [], else: [outcome.status]

    base = %{
      memory: %{before_activation: state.before, after_freeze: nil},
      clients_started: length(state.handle.clients.()),
      t0_ms: state.handle.t0,
      collection_ms: outcome.collection_ms,
      collection_failure: outcome.reason
    }

    case outcome.result do
      nil ->
        handle = state.handle
        window = Profile.window(handle)

        known =
          Profile.validity(%{
            window: window,
            from: window.from,
            to: window.to,
            failures: handle.failures,
            unclassified_share: 0.0
          })

        # Captured pids were proven traced: measured, with classes unknown.
        captured = MapSet.new(state.capture.processes, &elem(&1, 0))

        after_freeze =
          state.capture
          |> MemoryCensus.summarize(&if(MapSet.member?(captured, &1), do: :unavailable))
          |> Map.put(:classification, :unavailable)

        base
        |> Map.merge(%{
          window: window,
          coverage: %{failures: handle.failures},
          counters: :unavailable
        })
        |> put_in([:memory, :after_freeze], after_freeze)
        |> Map.put(:validity, invalid(known, collection ++ run_reasons(facts)))

      result ->
        {after_freeze, result} = Map.pop(result, :after_freeze)

        result
        |> Map.delete(:records)
        |> Map.merge(base)
        |> put_in([:memory, :after_freeze], after_freeze)
        |> Map.put(:validity, invalid(result.validity, collection ++ run_reasons(facts)))
    end
  end

  defp invalid(validity, []), do: validity

  defp invalid(validity, reasons),
    do: %{status: :invalid, reasons: Enum.uniq(validity.reasons ++ reasons)}

  defp run_reasons(facts) do
    checks =
      if Enum.all?(Map.values(facts.checks), &(&1 == true)), do: [], else: [:run_checks_failed]

    complete =
      if facts.complete == true and facts.incomplete == nil, do: [], else: [:run_incomplete]

    checks ++ complete
  end

  defp now, do: System.monotonic_time(:millisecond)
end
