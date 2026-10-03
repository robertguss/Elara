defmodule Elara.Lab.Sampler do
  @moduledoc """
  Periodic runtime samples for a lab run, phased by the run's window. A reading
  it cannot take is recorded as unavailable, never as zero; sampling itself
  costs the measured VM scheduler time.
  """

  @doc """
  Start an unlinked sampler. `opts`: `:owner` (receives guard reports),
  `:sample_ms`, `:listen` and `:server_port`, `:clients` (ETS of client pids),
  `:stub_os_pid`, `:guard_memory_bytes`, `:guard_mailbox`. With `probe: true`
  each tick also takes an `Elara.Lab.SupProbe` reading of `:probe_target`
  (default `Elara.SessionSup`) and a running trace of it is kept
  (`Elara.Lab.RunningTrace`); `start/1` then returns once the trace is
  installed or known unavailable.
  """
  @spec start(keyword()) :: pid()
  def start(opts) do
    opts = Map.new(opts)
    parent = self()
    ref = make_ref()
    pid = spawn(fn -> init(opts, {parent, ref}) end)

    if Map.get(opts, :probe, false) do
      monitor = Process.monitor(pid)

      receive do
        {^ref, :ready} -> Process.demonitor(monitor, [:flush])
        {:DOWN, ^monitor, :process, _, _} -> :ok
      after
        10_000 -> :ok
      end
    end

    pid
  end

  @doc """
  Start phasing samples: before `t0` is `:baseline`, then `:warmup` until
  `window_from`, `:window` until `load_end` or the shared cutoff (whichever is
  earlier), then `:after`. Samples before this call are `:baseline`.
  """
  def load(sampler, t0, window_from, load_end, shared),
    do: send(sampler, {:load, %{t0: t0, from: window_from, load_end: load_end, shared: shared}})

  @doc """
  Stop and return `%{samples, mailboxes}`; mailbox histograms are kept per phase.
  A probing sampler adds `probe` (readings in time order, each with its tick's
  `t` and `phase`) and `running` (the trace's buckets, or `:unavailable`).
  """
  @spec stop(pid(), timeout()) :: map()
  def stop(sampler, timeout \\ 10_000) do
    ref = Process.monitor(sampler)
    send(sampler, {:stop, self(), ref})

    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, _pid, reason} ->
        exit({:sampler_down, reason})
    after
      timeout -> exit(:sampler_timeout)
    end
  end

  @doc """
  Owners of the server's accepted TCP sockets: port-backed sockets whose local
  port is `server_port`, excluding the listener. Nil when the listener is not a
  port (another socket backend), so discovery is unavailable rather than empty.
  """
  @spec connections(term(), :inet.port_number() | nil) :: [pid()] | nil
  def connections(listen, server_port) when is_port(listen) and is_integer(server_port) do
    for socket <- Port.list(),
        socket != listen,
        Port.info(socket, :name) == {:name, ~c"tcp_inet"},
        match?({:ok, {_ip, ^server_port}}, safe_sockname(socket)),
        {:connected, owner} <- [Port.info(socket, :connected)],
        do: owner
  end

  def connections(_listen, _server_port), do: nil

  defp safe_sockname(socket) do
    :inet.sockname(socket)
  rescue
    ArgumentError -> {:error, :closed}
  end

  @doc "Resident set size of an OS process in bytes, or nil when unreadable."
  @spec stub_rss(integer() | nil) :: pos_integer() | nil
  def stub_rss(nil), do: nil

  def stub_rss(os_pid) do
    case System.cmd("ps", ["-o", "rss=", "-p", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {out, 0} ->
        case Integer.parse(String.trim(out)) do
          {kb, ""} when kb > 0 -> kb * 1024
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp init(opts, {parent, ref}) do
    stub_port =
      opts.stub_os_pid &&
        Enum.find(Port.list(), &(Port.info(&1, :os_pid) == {:os_pid, opts.stub_os_pid}))

    state =
      Map.merge(opts, %{
        stub_port: stub_port,
        samples: [],
        phases: nil,
        mailboxes: %{},
        tripped: MapSet.new(),
        probes: [],
        tracer: nil
      })

    state = start_probe(state)
    if probing?(state), do: send(parent, {ref, :ready})
    send(self(), :sample)
    loop(state)
  end

  defp loop(state) do
    receive do
      :sample ->
        Process.send_after(self(), :sample, state.sample_ms)
        loop(sample(state))

      {:load, phases} ->
        loop(%{state | phases: phases})

      {:stop, from, ref} ->
        result = %{samples: Enum.reverse(state.samples), mailboxes: state.mailboxes}
        send(from, {ref, probe_result(state, result)})
    end
  end

  # Strictly inside `stop/2`'s wait; the scenario gives a probing sampler more.
  @trace_stop_ms 5_000

  defp probing?(state), do: Map.get(state, :probe, false)

  defp probe_target(state), do: Map.get(state, :probe_target, Elara.SessionSup)

  # A target that is not running, or a trace that does not install, is recorded
  # as unavailable and never fails the run.
  defp start_probe(state) do
    if probing?(state) do
      target = resolve(probe_target(state))

      tracer =
        with pid when is_pid(pid) <- target,
             {:ok, tracer} <- Elara.Lab.RunningTrace.start(self(), pid, state.sample_ms) do
          tracer
        else
          _ -> :unavailable
        end

      %{state | tracer: tracer}
    else
      state
    end
  end

  defp resolve(name) when is_atom(name), do: Process.whereis(name)
  defp resolve(target), do: target

  defp probe_result(state, result) do
    if probing?(state) do
      running =
        case state.tracer do
          tracer when is_pid(tracer) -> Elara.Lab.RunningTrace.stop(tracer, @trace_stop_ms)
          _ -> :unavailable
        end

      Map.merge(result, %{probe: Enum.reverse(state.probes), running: running})
    else
      result
    end
  end

  defp probe(state, t, phase) do
    if probing?(state) do
      reading = Map.merge(Elara.Lab.SupProbe.read(probe_target(state)), %{t: t, phase: phase})
      %{state | probes: [reading | state.probes]}
    else
      state
    end
  end

  defp sample(state) do
    t = System.monotonic_time(:millisecond)
    phase = phase(state.phases, t)
    total = :erlang.memory(:total)
    sessions = Registry.select(Elara.Sessions, [{{:_, :"$1", :_}, [], [:"$1"]}])
    session_lengths = Enum.map(sessions, &queue_length/1)
    connections = connections(state.listen, state.server_port)

    clients_memory =
      state.clients
      |> :ets.tab2list()
      |> Enum.map(fn {pid, _sim} -> memory(pid) end)
      |> Enum.sum()

    sample = %{
      t: t,
      phase: phase,
      total: total,
      stub_rss: stub_rss(state.stub_os_pid),
      clients: clients_memory,
      stub_queue_bytes: port_queue(state.stub_port)
    }

    coordinator_length = queue_length(state.owner)

    state =
      state
      |> record(phase, :session, session_lengths)
      |> record(phase, :connection, connections && Enum.map(connections, &queue_length/1))
      |> record(phase, :coordinator, [coordinator_length])
      |> record(phase, :exec, [queue_length(Process.whereis(Elara.Exec))])
      |> record(phase, :threads, [queue_length(Process.whereis(Elara.Threads))])
      |> record(phase, :transport, [
        queue_length(Process.whereis(Elara.Threads.Communication))
      ])
      |> guard(:memory, total > state.guard_memory_bytes, t, total)
      |> guard(
        :mailbox,
        Enum.any?(session_lengths, &(is_integer(&1) and &1 > state.guard_mailbox)),
        t,
        Enum.max(Enum.filter(session_lengths, &is_integer/1), fn -> 0 end)
      )

    state = %{state | samples: [sample | state.samples]}
    probe(state, t, phase)
  end

  defp phase(nil, _t), do: :baseline

  defp phase(phases, t) do
    window_end = min(phases.load_end, Elara.Lab.Client.cutoff(phases.shared) || phases.load_end)

    cond do
      t < phases.t0 -> :baseline
      t < phases.from -> :warmup
      t < window_end -> :window
      true -> :after
    end
  end

  defp record(state, phase, class, lengths) do
    by_class = Map.get(state.mailboxes, phase, %{})
    histogram = Map.get(by_class, class, %{counts: %{}, unavailable: 0})

    histogram =
      case lengths do
        nil ->
          %{histogram | unavailable: histogram.unavailable + 1}

        lengths ->
          Enum.reduce(lengths, histogram, fn
            nil, h -> %{h | unavailable: h.unavailable + 1}
            n, h -> %{h | counts: Map.update(h.counts, n, 1, &(&1 + 1))}
          end)
      end

    %{state | mailboxes: Map.put(state.mailboxes, phase, Map.put(by_class, class, histogram))}
  end

  defp guard(state, kind, true, t, value) do
    if MapSet.member?(state.tripped, kind) do
      state
    else
      send(state.owner, {:guard, kind, t, value})
      %{state | tripped: MapSet.put(state.tripped, kind)}
    end
  end

  defp guard(state, _kind, false, _t, _value), do: state

  defp queue_length(nil), do: nil

  defp queue_length(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, n} -> n
      nil -> nil
    end
  end

  defp memory(pid) do
    case Process.info(pid, :memory) do
      {:memory, bytes} -> bytes
      nil -> 0
    end
  end

  defp port_queue(nil), do: nil

  defp port_queue(port) do
    case :erlang.port_info(port, :queue_size) do
      {:queue_size, bytes} -> bytes
      :undefined -> nil
    end
  end
end
