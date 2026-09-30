defmodule Elara.Lab.Profile do
  @moduledoc """
  Own-time profile of classified processes over a bounded window (note 003's
  attribution). `call_time` is scheduled elapsed time, blocking in dirty or
  native code included, so it is not CPU time. Classes follow this code base's
  audited spawn paths, not a general classifier; it judges no bottleneck.

  The audit: the one `Elara.TaskSup` spawn that is a server connection is the
  closure-based `Task.Supervisor.start_child` in `Elara.Server`, and every other
  `Elara.TaskSup` user is `async` or `async_nolink`. So a spawn on the
  `Task.Supervised` reply path is a task. A test pins that audit.
  """

  @ranked [:exec, :session, :connection, :task]
  @named [Elara.Exec, Elara.Threads, Elara.Threads.Communication]
  @limit_ms 5_000
  @outer_ms 30_000
  @barrier_ms 30_000
  # Every call that discards code (and with it, its counters) in the window.
  @code_changes [
    {:erlang, :delete_module, 1},
    {:erts_code_purger, :purge, 1},
    {:erts_code_purger, :soft_purge, 1}
  ]

  @doc "The ranked classes; `client`, `threads`, `transport` and `other` are descriptive."
  def ranked, do: @ranked

  @doc """
  Activate the profile, in the registered order: spawn observation on
  `Elara.SessionSup` and `Elara.TaskSup`; `call_time` patterns on every function
  and on modules loaded later; call tracing for future processes; a census of
  the current class members, each traced by pid; verification.

  `opts`: `:t0` (monotonic ms), `:window` (`{from, to}` ms after t0), `:clients`
  and `:connections` (functions returning pids; `:clients` must return every
  client of the run, exited ones included), and the test seams `:hook`
  (called with the point and both sessions at `:classification_started`,
  `:patterns_set`, `:future_enabled` and `:census_done`), `:hold` (the
  classifier holds events until `release/1`), `:deliver` (replaces
  `:trace.delivered/2`) and `:barrier_ms` (each acknowledgement's deadline).
  On any failure it disposes what it created and re-raises.
  """
  @spec activate(keyword()) :: map()
  def activate(opts) do
    # Every required option is read before any resource exists.
    t0 = Keyword.fetch!(opts, :t0)
    window = Keyword.fetch!(opts, :window)
    clients = Keyword.fetch!(opts, :clients)
    connections = Keyword.fetch!(opts, :connections)
    deliver = Keyword.get(opts, :deliver, &:trace.delivered/2)
    hook = Keyword.get(opts, :hook, fn _point, _sessions -> :ok end)
    a1 = System.monotonic_time(:millisecond)
    old_code = old_code()
    named = named()
    sups = [Process.whereis(Elara.SessionSup), Process.whereis(Elara.TaskSup)]

    {classifier, class_session, profile_session} =
      start_classifier(Keyword.get(opts, :hold, false))

    sessions = %{class_session: class_session, profile_session: profile_session}

    handle = %{
      t0: t0,
      window: window,
      clients: clients,
      connections: connections,
      deliver: deliver,
      barrier_ms: Keyword.get(opts, :barrier_ms, @barrier_ms),
      classifier: classifier,
      class_session: class_session,
      profile_session: profile_session,
      supervisors: sups,
      named: named,
      a1: a1,
      old_code: old_code,
      failures: [],
      frozen: false
    }

    try do
      installed =
        Enum.all?(
          sups,
          &(:trace.process(class_session, &1, true, [:procs, :monotonic_timestamp]) == 1)
        )

      handle = if installed, do: handle, else: fail(handle, :classification_install)
      hook.(:classification_started, sessions)

      # Code discarded in the window is counted, whichever process does it.
      for mfa <- @code_changes, do: :trace.function(class_session, mfa, true, [:call_count])

      # Modules loaded later first, so none loads between the two untraced.
      :trace.function(profile_session, :on_load, true, [:call_time])
      :trace.function(profile_session, {:_, :_, :_}, true, [:call_time])
      hook.(:patterns_set, sessions)

      :trace.process(profile_session, :new_processes, true, [:call])
      handle = if future?(handle), do: handle, else: fail(handle, :future_processes_install)
      # Trace timestamps are monotonic nanoseconds.
      n_native = System.monotonic_time(:nanosecond)
      n = System.monotonic_time(:millisecond)
      hook.(:future_enabled, sessions)

      census = census(clients: handle.clients, connections: handle.connections)
      for {pid, _class} <- census, do: trace_pid(profile_session, pid)
      send(classifier, {:census, census})
      hook.(:census_done, sessions)

      unverified =
        for {pid, class} <- census,
            class in @ranked,
            flags = :trace.info(profile_session, pid, :flags),
            flags != :undefined,
            not flag?(flags, :call),
            do: pid

      handle = if unverified == [], do: handle, else: fail(handle, :census_unverified)
      handle = if classifying?(handle), do: handle, else: fail(handle, :classification_lost)

      Map.merge(handle, %{
        n: n,
        n_native: n_native,
        census: MapSet.new(census, &elem(&1, 0)),
        a2: System.monotonic_time(:millisecond)
      })
    catch
      kind, reason ->
        dispose(handle)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc """
  The current members of the named classes, as `{pid, class}`, each pid once.
  An `Elara.TaskSup` child is a connection if it owns a server socket or its
  initial call names `Elara.Server`, a task if it names another module, and
  unclassified if nothing names its origin.
  """
  @spec census(keyword()) :: [{pid(), atom()}]
  def census(opts) do
    connections = MapSet.new(Keyword.fetch!(opts, :connections).() || [])

    tasks =
      for pid <- Task.Supervisor.children(Elara.TaskSup) do
        class =
          cond do
            pid in connections -> :connection
            true -> initial_class(:proc_lib.translate_initial_call(pid))
          end

        {pid, class}
      end

    sessions =
      for {_id, pid, _type, _mods} <- DynamicSupervisor.which_children(Elara.SessionSup),
          is_pid(pid),
          do: {pid, :session}

    named = fn name, class ->
      case Process.whereis(name) do
        pid when is_pid(pid) -> [{pid, class}]
        nil -> []
      end
    end

    (named.(Elara.Exec, :exec) ++
       sessions ++
       tasks ++
       Enum.map(Keyword.fetch!(opts, :clients).(), &{&1, :client}) ++
       named.(Elara.Threads, :threads) ++ named.(Elara.Threads.Communication, :transport))
    |> Enum.uniq_by(&elem(&1, 0))
  end

  @doc """
  Freeze at the window's end: read back the future-process setting and spawn
  observation, then stop counting in modules loaded later and pause every
  `call_time` counter (a pause, not a clear). Idempotent.
  """
  @spec freeze(map()) :: map()
  def freeze(%{frozen: true} = handle), do: handle

  def freeze(handle) do
    f1 = System.monotonic_time(:millisecond)
    # The code whose counters collection must read, taken while every loaded
    # module is still traced; one purged or reloaded later loses its counters.
    code = code()
    handle = if code_kept?(handle), do: handle, else: fail(handle, :code_changed)
    handle = if future?(handle), do: handle, else: fail(handle, :future_processes_lost)
    handle = if classifying?(handle), do: handle, else: fail(handle, :classification_lost)

    handle =
      try do
        :trace.function(handle.profile_session, :on_load, false, [:call_time])
        :trace.function(handle.profile_session, {:_, :_, :_}, :pause, [:call_time])
        handle
      rescue
        ArgumentError -> fail(handle, :freeze_failed)
      end

    Map.merge(handle, %{
      frozen: true,
      f1: f1,
      f2: System.monotonic_time(:millisecond),
      code: code
    })
  end

  @doc "Whether `pid` is traced in the profile session now: proven membership."
  @spec traced?(map(), pid()) :: boolean()
  def traced?(handle, pid), do: flag?(safe_info(handle.profile_session, pid), :call)

  @doc "Let a held classifier process its events (test seam)."
  def release(handle), do: send(handle.classifier, :release)

  @doc """
  Collect the frozen counters by class, then dispose. A trace-delivery barrier
  on both sessions (each observed supervisor, and every tracee of the profile
  session) and the classifier's completion reply come first, so every delivered
  spawn is classified. A named actor replaced since activation (its successor
  has no record) invalidates the profile. A traced pid with no record is
  recorded as `other` only while classification coverage held and no named
  actor was replaced; otherwise it is unclassified. `traced` names further proven-traced pids (a memory capture's
  members), which get records the same way. Counters that cannot be read, or
  whose code was purged or reloaded after the freeze, invalidate the profile.
  """
  @spec collect(map(), [pid()]) :: map()
  def collect(handle, traced \\ []) do
    try do
      handle = handle |> freeze() |> named_kept()
      delivered? = barrier(handle)
      handle = if delivered?, do: handle, else: fail(handle, :delivery_unconfirmed)

      {handle, records, receipt} =
        case call(handle.classifier, :complete) do
          {:ok, %{records: records, receipt: receipt}} -> {handle, records, receipt}
          :down -> {fail(handle, :classifier_down), %{}, %{}}
        end

      {counters, lost} = counters(handle)
      handle = Enum.reduce(lost, handle, &fail(&2, &1))
      clients = MapSet.new(handle.clients.())

      healthy? =
        Enum.all?(
          [
            :classification_install,
            :classification_lost,
            :delivery_unconfirmed,
            :classifier_down,
            :named_actor_replaced
          ],
          &(&1 not in handle.failures)
        )

      records =
        counters
        |> Enum.map(&elem(&1, 0))
        |> Enum.concat(traced)
        |> Enum.uniq()
        |> Enum.reduce(records, fn pid, records ->
          cond do
            Map.has_key?(records, pid) -> records
            pid in clients -> Map.put(records, pid, {:client, nil})
            healthy? -> Map.put(records, pid, {:other, nil})
            true -> Map.put(records, pid, {:unclassified, nil})
          end
        end)

      summarize(handle, counters, records, receipt)
    after
      dispose(handle)
    end
  end

  @doc "Destroy both trace sessions and stop the classifier. Idempotent."
  @spec dispose(map()) :: :ok
  def dispose(handle) do
    if Process.alive?(handle.classifier), do: call(handle.classifier, :stop)

    for session <- [handle.class_session, handle.profile_session] do
      try do
        :trace.session_destroy(session)
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  @doc """
  Judge a profile window by the registered rule. Every invalidation comes first:
  a coverage failure, unclassified share over 1%, an interior covering under 90%
  of `[from, to)`, or any lateness over 30 s. Then it is valid when every
  lateness is at most 5 s, and otherwise qualified.
  """
  @spec validity(map()) :: %{status: :valid | :qualified | :invalid, reasons: [atom()]}
  def validity(%{window: w, from: from, to: to, failures: failures, unclassified_share: share}) do
    late = [w.a1 - from, w.a2 - w.a1, w.f1 - to, w.f2 - w.f1]
    overlap = max(0, min(w.f1, to) - max(w.a2, from))

    invalid =
      failures ++
        if(share > 0.01, do: [:unclassified_share], else: []) ++
        if(overlap * 10 < (to - from) * 9, do: [:interior_overlap], else: []) ++
        if(Enum.any?(late, &(&1 > @outer_ms)), do: [:lateness_over_30s], else: [])

    cond do
      invalid != [] -> %{status: :invalid, reasons: Enum.uniq(invalid)}
      Enum.all?(late, &(&1 <= @limit_ms)) -> %{status: :valid, reasons: []}
      true -> %{status: :qualified, reasons: [:lateness_over_5s]}
    end
  end

  # ── Activation ──────────────────────────────────────────────────────────

  defp start_classifier(hold) do
    owner = self()
    tag = System.unique_integer([:positive])
    ref = make_ref()

    pid =
      spawn(fn ->
        monitor = Process.monitor(owner)
        cs = :trace.session_create(:"elara_lab_profile_classes_#{tag}", self(), [])
        ps = :trace.session_create(:"elara_lab_profile_#{tag}", self(), [])
        send(owner, {ref, cs, ps})

        classify(%{
          owner: monitor,
          sessions: [cs, ps],
          profile_session: ps,
          sups: %{
            Process.whereis(Elara.SessionSup) => :session,
            Process.whereis(Elara.TaskSup) => :task
          },
          hold: hold,
          records: %{},
          receipt: %{present: 0, absent: 0, dead: 0}
        })
      end)

    receive do
      {^ref, cs, ps} -> {pid, cs, ps}
    after
      5_000 -> exit(:profile_classifier_timeout)
    end
  end

  defp trace_pid(session, pid) do
    :trace.process(session, pid, true, [:call])
  rescue
    ArgumentError -> 0
  end

  defp future?(handle) do
    flag?(safe_info(handle.profile_session, :new_processes), :call)
  end

  # Spawn observation still set, on the same supervisors that were observed at a1.
  defp classifying?(handle) do
    handle.supervisors == [Process.whereis(Elara.SessionSup), Process.whereis(Elara.TaskSup)] and
      Enum.all?(
        handle.supervisors,
        &flag?(safe_info(handle.class_session, &1), :procs)
      )
  end

  defp named, do: Map.new(@named, &{&1, Process.whereis(&1)})

  # A replaced actor's successor was never classified, so the profile is invalid.
  defp named_kept(handle) do
    if named() == handle.named, do: handle, else: fail(handle, :named_actor_replaced)
  end

  defp flag?({:flags, flags}, flag) when is_list(flags), do: flag in flags
  defp flag?(_info, _flag), do: false

  defp safe_info(session, item) do
    :trace.info(session, item, :flags)
  rescue
    ArgumentError -> :undefined
  end

  defp fail(handle, reason), do: %{handle | failures: Enum.uniq(handle.failures ++ [reason])}

  defp initial_class({Elara.Server, _f, _a}), do: :connection
  defp initial_class({:proc_lib, :init_p, 5}), do: :unclassified
  defp initial_class({m, _f, _a}) when is_atom(m), do: :task
  defp initial_class(_other), do: :unclassified

  # ── Classifier ──────────────────────────────────────────────────────────

  defp classify(%{hold: true} = state) do
    receive do
      :release -> classify(%{state | hold: false})
      {:DOWN, ref, :process, _, _} when ref == state.owner -> shutdown(state)
      {:stop, from, ref} -> stop(state, from, ref)
    end
  end

  defp classify(state) do
    receive do
      {:trace_ts, sup, :spawn, pid, mfa, ts} when is_map_key(state.sups, sup) ->
        class = spawn_class(Map.fetch!(state.sups, sup), mfa)

        classify(%{
          state
          | records: put_record(state.records, pid, class, ts),
            receipt: receipt(state, pid)
        })

      {:trace_ts, _sup, _event, _pid, _info, _ts} ->
        classify(state)

      {:census, census} ->
        records =
          Enum.reduce(census, state.records, fn {pid, class}, acc ->
            put_record(acc, pid, class, nil)
          end)

        classify(%{state | records: records})

      :release ->
        classify(state)

      {:complete, from, ref} ->
        send(from, {ref, {:ok, %{records: state.records, receipt: state.receipt}}})
        classify(state)

      {:DOWN, ref, :process, _, _} when ref == state.owner ->
        shutdown(state)

      {:stop, from, ref} ->
        stop(state, from, ref)

      _other ->
        classify(state)
    end
  end

  defp stop(state, from, ref) do
    destroy(state.sessions)
    send(from, {ref, :ok})
  end

  defp shutdown(state), do: destroy(state.sessions)

  defp destroy(sessions) do
    for session <- sessions do
      try do
        :trace.session_destroy(session)
      rescue
        ArgumentError -> :ok
      end
    end
  end

  defp receipt(state, pid) do
    key =
      case safe_info(state.profile_session, pid) do
        :undefined -> :dead
        {:flags, flags} when is_list(flags) -> if :call in flags, do: :present, else: :absent
        _other -> :dead
      end

    Map.update!(state.receipt, key, &(&1 + 1))
  end

  # Census and spawn records merge by pid; a disagreement is unclassified.
  defp put_record(records, pid, class, ts) do
    case Map.fetch(records, pid) do
      :error -> Map.put(records, pid, {class, ts})
      {:ok, {^class, old}} -> Map.put(records, pid, {class, old || ts})
      {:ok, {_other, old}} -> Map.put(records, pid, {:unclassified, old || ts})
    end
  end

  defp spawn_class(:session, _mfa), do: :session

  defp spawn_class(:task, {Task.Supervised, :noreply, [_owner, _callers, _ancestors, mfa]}) do
    case mfa do
      {:erlang, :apply, [fun, _args]} when is_function(fun) ->
        if :erlang.fun_info(fun, :module) == {:module, Elara.Server}, do: :connection, else: :task

      {Elara.Server, _f, _a} ->
        :connection

      {m, _f, _a} when is_atom(m) ->
        :task

      _other ->
        :unclassified
    end
  end

  defp spawn_class(:task, {Task.Supervised, :reply, _args}), do: :task
  defp spawn_class(:task, _mfa), do: :unclassified

  # ── Collection ──────────────────────────────────────────────────────────

  defp barrier(handle) do
    targets =
      Enum.map(handle.supervisors, &{handle.class_session, &1}) ++
        [{handle.profile_session, :all}]

    Enum.all?(targets, fn {session, tracee} ->
      try do
        ref = handle.deliver.(session, tracee)

        receive do
          {:trace_delivered, ^tracee, ^ref} -> true
        after
          handle.barrier_ms -> false
        end
      rescue
        ArgumentError -> false
      end
    end)
  end

  defp call(pid, message) do
    ref = Process.monitor(pid)
    send(pid, if(message == :complete, do: {:complete, self(), ref}, else: {:stop, self(), ref}))

    receive do
      {^ref, reply} ->
        Process.demonitor(ref, [:flush])
        reply

      {:DOWN, ^ref, :process, _pid, _reason} ->
        :down
    end
  end

  defp old_code,
    do:
      for({m, _file} <- :code.all_loaded(), :erlang.check_old_code(m), into: MapSet.new(), do: m)

  # No code was deleted or purged since activation, and no module gained old
  # code (a reload, byte-identical or not, that discarded its counters).
  defp code_kept?(handle) do
    Enum.all?(@code_changes, fn mfa ->
      match?({:call_count, 0}, safe_count(handle.class_session, mfa))
    end) and MapSet.subset?(old_code(), handle.old_code)
  end

  defp safe_count(session, mfa) do
    :trace.info(session, mfa, :call_count)
  rescue
    ArgumentError -> nil
  end

  # Loaded modules with their code identity and functions.
  defp code do
    for {m, _file} <- :code.all_loaded(),
        info = code_info(m),
        info != nil,
        into: %{},
        do: {m, info}
  end

  defp code_info(m) do
    {m.module_info(:md5), m.module_info(:functions)}
  rescue
    _ -> nil
  end

  # Every nonzero {pid, mfa, calls, µs} row of the paused counters, over the
  # code loaded at the freeze, and the reasons any of them were lost.
  defp counters(handle) do
    Enum.reduce(handle.code, {[], []}, fn {m, {md5, functions}}, {rows, lost} ->
      case code_info(m) do
        {^md5, _functions} ->
          read =
            Enum.map(functions, fn {f, a} ->
              {{m, f, a}, safe_call_time(handle.profile_session, {m, f, a})}
            end)

          if Enum.all?(read, &match?({_mfa, {:call_time, list}} when is_list(list), &1)) do
            new =
              for {mfa, {:call_time, list}} <- read,
                  {pid, calls, s, us} <- list,
                  calls > 0 or s > 0 or us > 0,
                  do: {pid, mfa, calls, s * 1_000_000 + us}

            {new ++ rows, lost}
          else
            {rows, [:counters_unreadable | lost]}
          end

        _changed ->
          {rows, [:code_lost | lost]}
      end
    end)
    |> then(fn {rows, lost} -> {rows, Enum.uniq(lost)} end)
  end

  defp safe_call_time(session, mfa) do
    :trace.info(session, mfa, :call_time)
  rescue
    ArgumentError -> nil
  end

  defp summarize(handle, counters, records, receipt) do
    class_of = fn pid ->
      case Map.fetch(records, pid) do
        {:ok, {class, _ts}} -> class
        :error -> :unclassified
      end
    end

    rows =
      counters
      |> Enum.group_by(fn {pid, mfa, _calls, _us} -> {class_of.(pid), mfa} end)
      |> Enum.map(fn {{class, {m, f, a}}, group} ->
        %{
          class: class,
          module: m,
          function: f,
          arity: a,
          calls: group |> Enum.map(&elem(&1, 2)) |> Enum.sum(),
          us: group |> Enum.map(&elem(&1, 3)) |> Enum.sum(),
          native: native?(m, f, a)
        }
      end)
      |> Enum.sort_by(&{-&1.us, &1.class, &1.module, &1.function, &1.arity})

    # Pid counts are every recorded member, with or without counter rows;
    # collection gives every pid with counters a record.
    own =
      Enum.group_by(counters, fn {pid, _mfa, _calls, _us} -> class_of.(pid) end)

    classes =
      records
      |> Enum.group_by(fn {_pid, {class, _ts}} -> class end)
      |> Map.new(fn {class, members} ->
        group = Map.get(own, class, [])

        {class,
         %{
           pids: length(members),
           calls: group |> Enum.map(&elem(&1, 2)) |> Enum.sum(),
           own_us: group |> Enum.map(&elem(&1, 3)) |> Enum.sum()
         }}
      end)

    total = classes |> Map.values() |> Enum.map(& &1.own_us) |> Enum.sum()
    unclassified = get_in(classes, [:unclassified, :own_us]) || 0
    share = if total > 0, do: unclassified / total, else: 0.0
    {from, to} = handle.window

    window = %{
      a1: handle.a1 - handle.t0,
      n: handle.n - handle.t0,
      a2: handle.a2 - handle.t0,
      f1: handle.f1 - handle.t0,
      f2: handle.f2 - handle.t0
    }

    %{
      window:
        Map.merge(window, %{
          from: from,
          to: to,
          envelope_ms: window.f2 - window.a1,
          interior_ms: window.f1 - window.a2
        }),
      validity:
        validity(%{
          window: window,
          from: from,
          to: to,
          failures: handle.failures,
          unclassified_share: share
        }),
      coverage: %{failures: handle.failures, births: births(handle, records), receipt: receipt},
      classes: classes,
      functions: rows,
      total_us: total,
      unclassified_us: unclassified,
      unclassified_share: share,
      records: Map.new(records, fn {pid, {class, _ts}} -> {pid, class} end)
    }
  end

  defp births(handle, records) do
    Enum.reduce(records, %{before_n_census: 0, before_n_dead: 0, after_n: 0}, fn
      {_pid, {_class, nil}}, acc ->
        acc

      {pid, {_class, ts}}, acc ->
        key =
          cond do
            ts >= handle.n_native -> :after_n
            pid in handle.census -> :before_n_census
            true -> :before_n_dead
          end

        Map.update!(acc, key, &(&1 + 1))
    end)
  end

  defp native?(m, f, a) do
    :erlang.is_builtin(m, f, a) or {f, a} in nifs(m)
  end

  defp nifs(m) do
    m.module_info(:nifs)
  rescue
    _ -> []
  end
end
