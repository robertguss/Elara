defmodule Elara.Lab.Client do
  @moduledoc """
  In-VM protocol-v2 observer that accounts one lab session's stamped deltas.
  Delivery is final only at `tcp_closed`; it shares the measured VM's schedulers
  and does not stand in for the TUI.
  """

  alias Elara.Lab.Client.Accounting
  alias Elara.Lab.Histogram

  @extensions [
    "provider_visibility_v1",
    "input_attachments_v1",
    "input_queue_v1",
    "thread_communication_v1",
    "plugin_reload_v1"
  ]
  @delta_text ~s("op":"append_content_delta","text":")
  @active 100

  @doc "The five extensions every client negotiates (frozen in note 003)."
  def extensions, do: @extensions

  @doc """
  Start an unlinked client. `opts`: `:owner` (receives guard reports and the
  final summary), `:sim_id`, `:ledger`, `:accounting` (keyword for
  `Accounting.new/1`), `:shared` (see `shared/1`), `:port`, `:sample_ms`,
  `:guard_lag_ms`, `:bash_ms`, `:close_ms`, `:hold` (read nothing after attach
  until `finish/1`, for tests).
  """
  @spec start(keyword()) :: pid()
  def start(opts), do: spawn(fn -> init(Map.new(opts)) end)

  @doc """
  Shared run state: latency and bash-excess histograms, an arrivals-in-window
  counter, a monotonic progress cell and a write-once cutoff cell.
  """
  @spec shared(integer()) :: map()
  def shared(started_ms) do
    progress = :atomics.new(1, signed: true)
    :atomics.put(progress, 1, started_ms)

    %{
      latency: Histogram.new(0, 9_999),
      bash: Histogram.new(-1_000, 9_999),
      arrivals: :counters.new(1, [:write_concurrency]),
      progress: progress,
      cutoff: :atomics.new(2, signed: true)
    }
  end

  @doc "Advance the progress cell to `now` if later; concurrent writers never move it back."
  def advance(%{progress: progress} = shared, now) do
    current = :atomics.get(progress, 1)

    if now > current and :atomics.compare_exchange(progress, 1, current, now) != :ok,
      do: advance(shared, now),
      else: :ok
  end

  def progress(%{progress: progress}), do: :atomics.get(progress, 1)

  @doc "Set the cutoff once; returns the cutoff in force."
  # Cell 1 is 0 (unset), 1 (the winner is writing) or 2 (published); only the
  # caller that moves it from 0 to 1 writes the value in cell 2.
  def cut(%{cutoff: cell} = shared, at) do
    case :atomics.compare_exchange(cell, 1, 0, 1) do
      :ok ->
        :atomics.put(cell, 2, at)
        :atomics.put(cell, 1, 2)
        at

      _taken ->
        cutoff(shared)
    end
  end

  def cutoff(%{cutoff: cell} = shared) do
    case :atomics.get(cell, 1) do
      0 -> nil
      2 -> :atomics.get(cell, 2)
      1 -> :erlang.yield() && cutoff(shared)
    end
  end

  @doc "Attach to `session_id` and wait for the server's `attached` line."
  @spec attach(pid(), String.t(), timeout()) :: :ok | {:error, term()}
  def attach(client, session_id, timeout) do
    ref = Process.monitor(client)
    send(client, {:attach, self(), ref, session_id})

    receive do
      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        reply

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:error, {:client_down, reason}}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        {:error, :attach_timeout}
    end
  end

  @doc """
  Retire after the session has stopped: drain to `tcp_closed`, then report to
  the owner. With `final: false` (a ledger writer may still be running) the
  summary is provisional and the ledger rows are left in place.
  """
  def finish(client, final \\ true), do: send(client, {:finish, final})

  defp init(opts) do
    state =
      Map.merge(opts, %{
        acc: Accounting.new(opts.accounting),
        socket: nil,
        attached: false,
        waiter: nil,
        closed: false,
        finishing: false,
        lag_reported: false,
        bash_started: %{}
      })

    Process.send_after(self(), :tick, state.sample_ms)
    loop(state)
  end

  defp loop(state) do
    receive do
      {:attach, from, ref, session_id} -> loop(connect(state, from, ref, session_id))
      {:tcp, _socket, line} -> loop(line(state, line))
      {:tcp_passive, socket} -> loop(rearm(state, socket))
      {:tcp_closed, _socket} -> closed(%{state | closed: true})
      {:tcp_error, _socket, _reason} -> closed(%{state | closed: true})
      :tick -> loop(tick(state))
      {:finish, final} -> finishing(Map.put(state, :final, final))
      :close_timeout -> report(state, :close_timeout)
    end
  end

  defp connect(state, from, ref, session_id) do
    opts = [:binary, packet: :line, packet_size: Elara.Protocol.max_line_bytes(), active: false]

    with {:ok, socket} <- :gen_tcp.connect({127, 0, 0, 1}, state.port, opts),
         request = %{
           "version" => 2,
           "token" => System.get_env("ELARA_SERVER_TOKEN"),
           "command" => "attach",
           "session_id" => session_id,
           "mode" => "observe",
           "extensions" => @extensions
         },
         :ok <- :gen_tcp.send(socket, [JSON.encode!(request), "\n"]),
         :ok <- :inet.setopts(socket, active: :once) do
      %{state | socket: socket, waiter: {from, ref}}
    else
      {:error, reason} ->
        send(from, {ref, {:error, reason}})
        state
    end
  end

  defp rearm(%{hold: true, finishing: false} = state, _socket), do: state

  defp rearm(state, socket) do
    :inet.setopts(socket, active: @active)
    state
  end

  defp line(%{attached: false} = state, line) do
    {from, ref} = state.waiter

    case JSON.decode(line) do
      {:ok, %{"type" => "attached"}} ->
        send(from, {ref, :ok})
        state = %{state | attached: true, waiter: nil}
        if state.hold, do: state, else: rearm(state, state.socket)

      other ->
        send(from, {ref, {:error, {:attach_failed, other}}})
        state
    end
  end

  defp line(state, line) do
    now = System.monotonic_time(:millisecond)

    cond do
      String.contains?(line, "append_content_delta") -> delta(state, line, now)
      String.contains?(line, "set_tool_status") -> tool_status(state, line, now)
      true -> state
    end
  end

  defp delta(state, line, now) do
    cutoff = cutoff(state.shared)
    lookup = fn -> rows(state) end
    {acc, result} = Accounting.arrival(state.acc, delta_text(line), now, cutoff, lookup)
    state = %{state | acc: acc}

    case result do
      {:observed, latency, in_cohort?, in_window?} ->
        if in_cohort?, do: Histogram.record(state.shared.latency, latency)
        if in_window?, do: :counters.add(state.shared.arrivals, 1, 1)
        advance(state.shared, now)
        if latency >= state.guard_lag_ms, do: lag(state, now), else: state

      _other ->
        state
    end
  end

  defp delta_text(line) do
    case :binary.match(line, @delta_text) do
      {at, length} ->
        rest = binary_part(line, at + length, byte_size(line) - at - length)
        rest |> :binary.split("\"") |> hd()

      :nomatch ->
        ""
    end
  end

  # Bash excess is observed start-to-finish at this client, minus the command's
  # own duration; it is end-to-end, not Exec queueing.
  defp tool_status(state, line, now) do
    ops =
      case JSON.decode(line) do
        {:ok, %{"ops" => ops}} when is_list(ops) -> ops
        _ -> []
      end

    Enum.reduce(ops, state, fn
      %{
        "op" => "set_tool_status",
        "id" => id,
        "status" => "running",
        "call" => %{"name" => "bash"}
      },
      state ->
        put_in(state.bash_started[id], now)

      %{"op" => "set_tool_status", "id" => id, "status" => status}, state
      when status in ["succeeded", "failed", "indeterminate"] ->
        {started, bash_started} = Map.pop(state.bash_started, id)
        cutoff = cutoff(state.shared)
        {from, to} = state.acc.window

        if started && started >= from && started < to && (cutoff == nil or now <= cutoff),
          do: Histogram.record(state.shared.bash, now - started - state.bash_ms)

        %{state | bash_started: bash_started}

      _op, state ->
        state
    end)
  end

  defp tick(%{finishing: true} = state), do: state

  defp tick(state) do
    Process.send_after(self(), :tick, state.sample_ms)
    state = %{state | acc: Accounting.ingest(state.acc, rows(state))}
    now = System.monotonic_time(:millisecond)

    case Accounting.oldest_pending(state.acc) do
      oldest when is_integer(oldest) and now - oldest >= state.guard_lag_ms -> lag(state, now)
      _ -> state
    end
  end

  defp lag(%{lag_reported: true} = state, _now), do: state

  defp lag(state, now) do
    send(state.owner, {:guard, :lag, now, state.sim_id})
    %{state | lag_reported: true}
  end

  defp rows(state),
    do: :ets.select(state.ledger, [{{{state.sim_id, :_}, :_, :_, :_, :_}, [], [:"$_"]}])

  defp finishing(state) do
    state = %{state | finishing: true}
    # The peer may already have closed; its tcp_closed is then on its way.
    if state.socket && not state.closed, do: :inet.setopts(state.socket, active: @active)
    if state.closed or state.socket == nil, do: report(state, :closed)
    Process.send_after(self(), :close_timeout, state.close_ms)
    loop(state)
  end

  defp closed(%{finishing: true} = state), do: report(state, :closed)
  defp closed(state), do: loop(state)

  # Reports once and exits. Only a final report deletes this session's ledger
  # rows: its session stopped normally, or the owner confirmed its writers ended.
  defp report(state, close) do
    stop_ms = cutoff(state.shared) || System.monotonic_time(:millisecond)
    summary = Accounting.finalize(state.acc, rows(state), stop_ms)

    if state.final,
      do: :ets.select_delete(state.ledger, [{{{state.sim_id, :_}, :_, :_, :_, :_}, [], [true]}])

    if state.socket, do: :gen_tcp.close(state.socket)

    send(
      state.owner,
      {:client_summary, self(), state.sim_id,
       Map.merge(summary, %{close: close, attached: state.attached, ledger_final: state.final})}
    )

    exit(:normal)
  end
end
