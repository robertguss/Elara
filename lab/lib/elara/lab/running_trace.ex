defmodule Elara.Lab.RunningTrace do
  @moduledoc """
  Fixed-bucket on-CPU and off-CPU time of one process, from its own `:trace`
  session's `:running` events. Diagnostic only: it sends the tracer a message
  per schedule event (a perturbation), cannot separate waiting from wake-up
  delay, waits a bounded time for trace delivery at stop (then drains what
  arrived), and drops an interval it did not see both ends of — the target's
  running time before its first out-event, and an interval still open at stop.
  """

  @top 4
  @delivery_ms 1_000

  @doc """
  Start a tracer that traces `target` in a session of its own, bucketing by
  `bucket_ms` of the monotonic clock. Returns `{:ok, tracer}` once installed, or
  `:unavailable`. The session is destroyed at `stop/1` or when `owner` dies.
  """
  @spec start(pid(), pid(), pos_integer()) :: {:ok, pid()} | :unavailable
  def start(owner, target, bucket_ms) do
    parent = self()
    ref = make_ref()
    tracer = spawn(fn -> init(parent, ref, owner, target, bucket_ms) end)
    monitor = Process.monitor(tracer)

    receive do
      {^ref, :ok} ->
        Process.demonitor(monitor, [:flush])
        {:ok, tracer}

      {^ref, :unavailable} ->
        Process.demonitor(monitor, [:flush])
        :unavailable

      {:DOWN, ^monitor, :process, _, _} ->
        :unavailable
    after
      5_000 ->
        Process.exit(tracer, :kill)
        :unavailable
    end
  end

  @doc """
  Destroy the session and return the buckets in time order, or `:unavailable`
  when the tracer died or did not answer within `timeout_ms` (it is then killed).
  An empty list means traced with no events.
  """
  @spec stop(pid(), timeout()) :: [map()] | :unavailable
  def stop(tracer, timeout_ms \\ 5_000) do
    ref = Process.monitor(tracer)
    send(tracer, {:stop, self(), ref})

    receive do
      {^ref, buckets} ->
        Process.demonitor(ref, [:flush])
        buckets

      {:DOWN, ^ref, :process, _, _} ->
        :unavailable
    after
      timeout_ms ->
        Process.demonitor(ref, [:flush])
        Process.exit(tracer, :kill)
        :unavailable
    end
  end

  defp init(parent, ref, owner, target, bucket_ms) do
    Process.monitor(owner)
    tag = System.unique_integer([:positive])

    installed =
      try do
        session = :trace.session_create(:"elara_lab_running_#{tag}", self(), [])

        if :trace.process(session, target, true, [:running, :monotonic_timestamp]) == 1,
          do: {:ok, session},
          else: :trace.session_destroy(session) && :error
      catch
        _kind, _reason -> :error
      end

    case installed do
      {:ok, session} ->
        send(parent, {ref, :ok})
        loop(%{session: session, target: target, bucket_us: bucket_ms * 1000}, nil, %{})

      :error ->
        send(parent, {ref, :unavailable})
    end
  end

  # `last` is the open edge: {:in, at_us} or {:out, at_us, mfa}, nil before the first event.
  defp loop(state, last, buckets) do
    receive do
      {:trace_ts, _pid, :in, _mfa, ts} ->
        at = us(ts)
        {last, buckets} = schedule_in(state, last, buckets, at)
        loop(state, last, buckets)

      {:trace_ts, _pid, :out, mfa, ts} ->
        at = us(ts)
        {last, buckets} = schedule_out(state, last, buckets, at, name(mfa))
        loop(state, last, buckets)

      {:trace_ts, _pid, _other_event, _mfa, _ts} ->
        loop(state, last, buckets)

      {:stop, from, ref} ->
        buckets = finish(state, last, buckets)
        send(from, {ref, report(buckets, div(state.bucket_us, 1000))})

      {:DOWN, _ref, :process, _owner, _reason} ->
        destroy(state)
    end
  end

  defp schedule_in(state, {:out, since, mfa}, buckets, at) do
    buckets = buckets |> span(state, since, at, {:off, mfa}) |> bump(state, at, :ins, 1)
    {{:in, at}, buckets}
  end

  defp schedule_in(state, _last, buckets, at),
    do: {{:in, at}, bump(buckets, state, at, :ins, 1)}

  defp schedule_out(state, {:in, since}, buckets, at, mfa) do
    buckets = buckets |> span(state, since, at, :running) |> bump(state, at, {:outs, mfa}, 1)
    {{:out, at, mfa}, buckets}
  end

  defp schedule_out(state, _last, buckets, at, mfa),
    do: {{:out, at, mfa}, bump(buckets, state, at, {:outs, mfa}, 1)}

  # Final events are drained after the session is destroyed; an interval still
  # open is dropped, not closed at the stop time.
  defp finish(state, last, buckets) do
    try do
      ref = :trace.delivered(state.session, state.target)

      receive do
        {:trace_delivered, _target, ^ref} -> :ok
      after
        @delivery_ms -> :ok
      end
    catch
      _kind, _reason -> :ok
    end

    destroy(state)
    drain(state, last, buckets)
  end

  defp drain(state, last, buckets) do
    receive do
      {:trace_ts, _pid, :in, _mfa, ts} ->
        {last, buckets} = schedule_in(state, last, buckets, us(ts))
        drain(state, last, buckets)

      {:trace_ts, _pid, :out, mfa, ts} ->
        {last, buckets} = schedule_out(state, last, buckets, us(ts), name(mfa))
        drain(state, last, buckets)

      {:trace_ts, _pid, _event, _mfa, _ts} ->
        drain(state, last, buckets)
    after
      0 -> buckets
    end
  end

  defp destroy(state) do
    :trace.session_destroy(state.session)
  catch
    _kind, _reason -> :ok
  end

  defp us(ts), do: :erlang.convert_time_unit(ts, :native, :microsecond)

  defp name({_module, _function, _arity} = mfa), do: Elara.Lab.SupProbe.mfa(mfa)
  defp name(_other), do: "unknown"

  # Floor division: the monotonic clock is negative, and `div/2` truncates toward zero.
  defp bucket(state, at), do: Integer.floor_div(at, state.bucket_us)

  defp bump(buckets, state, at, key, n) do
    update(buckets, bucket(state, at), fn b ->
      case key do
        :ins -> %{b | ins: b.ins + n}
        {:outs, mfa} -> %{b | outs: Map.update(b.outs, mfa, n, &(&1 + n))}
      end
    end)
  end

  # An interval is split at every bucket boundary it crosses.
  defp span(buckets, _state, from, to, _kind) when to <= from, do: buckets

  defp span(buckets, state, from, to, kind) do
    index = bucket(state, from)
    edge = min(to, (index + 1) * state.bucket_us)
    length = edge - from

    buckets =
      update(buckets, index, fn b ->
        case kind do
          :running -> %{b | running_us: b.running_us + length}
          {:off, mfa} -> %{b | off: Map.update(b.off, mfa, length, &(&1 + length))}
        end
      end)

    span(buckets, state, edge, to, kind)
  end

  defp update(buckets, index, fun) do
    Map.update(
      buckets,
      index,
      fun.(%{running_us: 0, ins: 0, outs: %{}, off: %{}}),
      fun
    )
  end

  defp report(buckets, bucket_ms) do
    for {index, b} <- Enum.sort(buckets) do
      %{
        start: index * bucket_ms,
        running_us: b.running_us,
        ins: b.ins,
        outs: top(b.outs),
        off_us: top(b.off)
      }
    end
  end

  # The top MFAs by value, then everything else as "other".
  defp top(by_mfa) do
    {kept, rest} =
      by_mfa |> Enum.sort_by(fn {mfa, value} -> {-value, mfa} end) |> Enum.split(@top)

    Map.put(Map.new(kept), "other", rest |> Enum.map(&elem(&1, 1)) |> Enum.sum())
  end
end
