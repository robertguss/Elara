defmodule Elara.Lab.ProfileTest do
  use ExUnit.Case, async: false

  alias Elara.Lab.Profile

  defmodule Work do
    def spin(0), do: :ok
    def spin(n), do: spin(n - 1)

    def park, do: receive(do: (:go -> :ok))
  end

  defp activate(opts \\ []) do
    t0 = System.monotonic_time(:millisecond)

    defaults = [
      t0: t0,
      window: {0, 600_000},
      clients: fn -> [] end,
      connections: fn -> [] end
    ]

    handle = Profile.activate(Keyword.merge(defaults, opts))
    on_exit(fn -> Profile.dispose(handle) end)
    handle
  end

  defp task(fun) do
    Task.Supervisor.async_nolink(Elara.TaskSup, fun) |> Task.await()
  end

  defp calls(result, class, {m, f, a}) do
    result.functions
    |> Enum.filter(&(&1.class == class and &1.module == m and &1.function == f and &1.arity == a))
    |> Enum.map(& &1.calls)
    |> Enum.sum()
  end

  defp our_sessions(entity) do
    for {name, _id} <- :trace.session_info(entity),
        String.starts_with?(Atom.to_string(name), "elara_lab_profile"),
        do: name
  end

  defp gone?(handle) do
    not Process.alive?(handle.classifier) and our_sessions(:new_processes) == [] and
      our_sessions(Process.whereis(Elara.TaskSup)) == []
  end

  # Live classifier processes, found waiting in their receive loop.
  defp classifiers do
    for pid <- Process.list(),
        {:current_function, {Profile, :classify, 1}} <- [Process.info(pid, :current_function)],
        do: pid
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  defp start_session do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    dir = Path.join(System.tmp_dir!(), "elara-profile-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    before = Enum.map(DynamicSupervisor.which_children(Elara.SessionSup), &elem(&1, 1))

    {:ok, id} =
      Elara.start_session(provider: {Elara.Provider.Scripted, agent}, cwd: dir, persist: false)

    [pid] = Enum.map(DynamicSupervisor.which_children(Elara.SessionSup), &elem(&1, 1)) -- before
    on_exit(fn -> DynamicSupervisor.terminate_child(Elara.SessionSup, pid) end)
    {:ok, ^pid} = Elara.session_pid(id)
    pid
  end

  defp connect(server) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, Elara.Server.port(server), [:binary, active: false])

    on_exit(fn -> :gen_tcp.close(socket) end)
    socket
  end

  defp server_connections(server) do
    listen = :sys.get_state(server).listen
    Elara.Lab.Sampler.connections(listen, Elara.Server.port(server))
  end

  defp start_server do
    {:ok, server} = Elara.Server.start(port: 0)
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    server
  end

  describe "classes" do
    test "a task started in the window is a task, and its own time and calls are counted" do
      handle = activate()
      task(fn -> Work.spin(1_000) end)
      # Alive at collection, so its spawn receipt finds the flag, not a dead pid.
      {:ok, parked} = Task.Supervisor.start_child(Elara.TaskSup, &Work.park/0)
      on_exit(fn -> Process.exit(parked, :kill) end)
      result = handle |> Profile.freeze() |> Profile.collect()

      assert calls(result, :task, {Work, :spin, 1}) == 1_001
      assert result.classes.task.own_us >= 0
      assert result.classes.task.pids >= 1
      assert result.coverage.receipt.present >= 1
      assert result.coverage.failures == []
    end

    test "a pid whose census and spawn records disagree is unclassified" do
      parent = self()

      hook = fn
        :classification_started, _sessions ->
          {:ok, pid} = Task.Supervisor.start_child(Elara.TaskSup, &Work.park/0)
          send(parent, {:spawned, pid})

        _point, _sessions ->
          :ok
      end

      # The census names it a connection; the spawn path names it a task.
      connections = fn ->
        receive do
          {:spawned, pid} -> send(self(), {:spawned, pid}) && [pid]
        after
          0 -> []
        end
      end

      handle = activate(hook: hook, connections: connections)
      assert_received {:spawned, pid}
      on_exit(fn -> Process.exit(pid, :kill) end)
      result = handle |> Profile.freeze() |> Profile.collect()

      assert result.records[pid] == :unclassified
    end

    test "sessions, connections and Elara.Exec are classified from the census and from spawns" do
      server = start_server()
      existing_session = start_session()
      connect(server)

      existing_connection =
        Enum.find_value(1..100, fn _ ->
          Process.sleep(10)
          List.first(server_connections(server) || [])
        end)

      handle = activate(connections: fn -> server_connections(server) || [] end)
      new_session = start_session()
      before = server_connections(server)
      connect(server)
      assert wait_until(fn -> length(server_connections(server)) == length(before) + 1 end)
      [new_connection] = server_connections(server) -- before
      result = handle |> Profile.freeze() |> Profile.collect()

      assert result.records[existing_session] == :session
      assert result.records[new_session] == :session
      assert result.records[existing_connection] == :connection
      assert result.records[new_connection] == :connection
      assert result.records[Process.whereis(Elara.Exec)] == :exec
    end

    test "a census connection is found by its initial call when socket discovery finds none" do
      server = start_server()
      connect(server)
      assert wait_until(fn -> length(server_connections(server)) == 1 end)
      [connection] = server_connections(server)

      result = activate(connections: fn -> [] end) |> Profile.freeze() |> Profile.collect()
      assert result.records[connection] == :connection
    end

    test "start_child with a closure is classified by the closure's origin; the MFA form is a task" do
      handle = activate()
      {:ok, closure} = Task.Supervisor.start_child(Elara.TaskSup, fn -> Work.spin(10) end)
      {:ok, mfa} = Task.Supervisor.start_child(Elara.TaskSup, Work, :spin, [10])
      result = handle |> Profile.freeze() |> Profile.collect()

      assert result.records[closure] == :task
      assert result.records[mfa] == :task
    end

    test "a short-lived async_nolink task keeps its class after it exits" do
      handle = activate()
      t = Task.Supervisor.async_nolink(Elara.TaskSup, fn -> Work.spin(10) end)
      Task.await(t)
      refute Process.alive?(t.pid)
      result = handle |> Profile.freeze() |> Profile.collect()

      assert result.records[t.pid] == :task
    end

    test "a census TaskSup child with an undeterminable initial call stays unclassified" do
      # A child started by the supervisor's own start_child, then with its
      # dictionary's initial call removed, so nothing names its origin.
      {:ok, pid} =
        Task.Supervisor.start_child(Elara.TaskSup, fn ->
          Process.delete(:"$initial_call")
          Work.park()
        end)

      on_exit(fn -> Process.exit(pid, :kill) end)

      assert wait_until(fn ->
               :proc_lib.translate_initial_call(pid) == {:proc_lib, :init_p, 5}
             end)

      result = activate() |> Profile.freeze() |> Profile.collect()
      assert result.records[pid] == :unclassified

      # Socket discovery names it a connection even when nothing else does.
      result = activate(connections: fn -> [pid] end) |> Profile.freeze() |> Profile.collect()
      assert result.records[pid] == :connection
    end

    test "clients, Threads and the transport are descriptive classes" do
      client = spawn(&Work.park/0)
      on_exit(fn -> Process.exit(client, :kill) end)
      result = activate(clients: fn -> [client] end) |> Profile.freeze() |> Profile.collect()

      assert result.records[client] == :client
      assert result.records[Process.whereis(Elara.Threads)] == :threads
      assert result.records[Process.whereis(Elara.Threads.Communication)] == :transport
    end

    test "a plain process spawned in the window is recorded as other, not unclassified" do
      handle = activate()
      {pid, ref} = spawn_monitor(fn -> Work.spin(100) end)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      result = handle |> Profile.freeze() |> Profile.collect()

      assert result.records[pid] == :other
      assert calls(result, :other, {Work, :spin, 1}) == 101
    end

    test "rows flag builtins and NIFs as native" do
      handle = activate()
      task(fn -> for _ <- 1..10, do: :erlang.phash2({:a, self()}) end)
      result = handle |> Profile.freeze() |> Profile.collect()

      assert Enum.any?(result.functions, & &1.native)

      for row <- result.functions do
        assert row.native ==
                 (:erlang.is_builtin(row.module, row.function, row.arity) or
                    {row.function, row.arity} in row.module.module_info(:nifs)),
               inspect(row)
      end
    end
  end

  defp advance_past(target, spins \\ 10_000_000) do
    now = System.monotonic_time(:millisecond)

    cond do
      now >= target -> now
      spins == 0 -> flunk("the monotonic clock did not advance")
      true -> advance_past(target, spins - 1)
    end
  end

  describe "the timed first census" do
    test "it returns the plain census with seven ordered marks and both supervisors' readings" do
      client = spawn(fn -> Work.park() end)
      on_exit(fn -> Process.exit(client, :kill) end)
      opts = [clients: fn -> [client] end, connections: fn -> [] end]

      {census, setup} = Profile.timed_census(opts)

      assert census == Profile.census(opts)
      assert {client, :client} in census
      assert Map.keys(setup.marks) |> Enum.sort() == Enum.sort(Profile.census_marks())
      marks = Enum.map(Profile.census_marks(), &setup.marks[&1])
      assert marks == Enum.sort(marks)

      for key <- [:task_sup, :session_sup] do
        reading = setup.supervisors[key]
        assert is_integer(reading.queue_before) and is_integer(reading.queue_after)
        assert is_integer(reading.children)
      end
    end

    test "a held phase's time lands between its own marks" do
      test = self()
      gate = make_ref()

      connections = fn ->
        send(test, {:held, self()})
        receive do: ({:release, ^gate} -> [])
      end

      task =
        Task.async(fn ->
          Profile.timed_census(clients: fn -> [] end, connections: connections)
        end)

      on_exit(fn -> Process.exit(task.pid, :kill) end)

      assert_receive {:held, holder}, 5_000
      held_at = System.monotonic_time(:millisecond)
      # Hold the gate across a strictly positive interval: a bounded spin on
      # the monotonic clock, not a sleep.
      released_at = advance_past(held_at + 2)
      send(holder, {:release, gate})
      {_census, setup} = Task.await(task, 5_000)

      assert setup.marks.census_start <= held_at
      assert released_at <= setup.marks.connections_done
      assert setup.marks.connections_done - setup.marks.census_start >= 2

      for phase <- Profile.census_marks() -- [:census_start, :connections_done] do
        assert setup.marks[phase] >= setup.marks.connections_done
      end
    end
  end

  describe "the window" do
    test "the freeze stops counting, also in modules loaded later; modules loaded in the window count" do
      handle = activate()
      [{during, _}] = Code.compile_string("defmodule ProfileLoadedDuring do def f, do: :ok end")
      task(fn -> during.f() end)
      task(fn -> Work.spin(100) end)
      handle = Profile.freeze(handle)
      task(fn -> Work.spin(100) end)

      [{after_freeze, _}] =
        Code.compile_string("defmodule ProfileLoadedAfter do def f, do: :ok end")

      # The freeze stopped patterns on later loads, not only their collection.
      assert :trace.info(handle.profile_session, {after_freeze, :f, 0}, :call_time) ==
               {:call_time, false}

      task(fn -> after_freeze.f() end)
      result = Profile.collect(handle)

      on_exit(fn ->
        for m <- [during, after_freeze], do: :code.purge(m) && :code.delete(m)
      end)

      assert calls(result, :task, {Work, :spin, 1}) == 101
      assert calls(result, :task, {during, :f, 0}) == 1
      assert calls(result, :task, {after_freeze, :f, 0}) == 0
    end

    test "the four timestamps are ordered and relative to t0" do
      t0 = System.monotonic_time(:millisecond) - 1_000
      result = activate(t0: t0) |> Profile.freeze() |> Profile.collect()
      w = result.window

      assert w.a1 >= 1_000
      assert w.a1 <= w.n and w.n <= w.a2 and w.a2 <= w.f1 and w.f1 <= w.f2
      assert w.envelope_ms == w.f2 - w.a1
      assert w.interior_ms == w.f1 - w.a2
    end

    test "freeze is idempotent" do
      handle = activate() |> Profile.freeze()
      assert Profile.freeze(handle) == handle
    end
  end

  describe "coverage" do
    test "births before the future-process setting are counted by whether the census saw them" do
      parent = self()

      hook = fn
        :classification_started, _sessions ->
          for _ <- 1..3, do: task(fn -> Work.spin(1) end)
          {:ok, alive} = Task.Supervisor.start_child(Elara.TaskSup, &Work.park/0)
          send(parent, {:alive, alive})

        _point, _sessions ->
          :ok
      end

      handle = activate(hook: hook)
      assert_received {:alive, alive}
      task(fn -> Work.spin(1) end)
      send(alive, :go)
      result = handle |> Profile.freeze() |> Profile.collect()

      assert result.coverage.births.before_n_dead >= 3
      assert result.coverage.births.before_n_census >= 1
      assert result.coverage.births.after_n >= 1
      assert result.coverage.receipt.absent + result.coverage.receipt.dead >= 1
      assert result.coverage.failures == []
    end

    test "a process born and exited around the census is still traced" do
      hook = fn
        :census_done, _sessions -> task(fn -> Work.spin(10) end)
        _point, _sessions -> :ok
      end

      result = activate(hook: hook) |> Profile.freeze() |> Profile.collect()
      assert calls(result, :task, {Work, :spin, 1}) == 11
    end

    test "a census member left untraced fails census verification" do
      hook = fn
        :census_done, sessions ->
          :trace.process(sessions.profile_session, Process.whereis(Elara.Exec), false, [:call])

        _point, _sessions ->
          :ok
      end

      result = activate(hook: hook) |> Profile.freeze() |> Profile.collect()
      assert :census_unverified in result.coverage.failures
      assert result.validity.status == :invalid
    end

    test "counters that cannot be read invalidate the profile" do
      handle = activate()
      task(fn -> Work.spin(10) end)
      handle = Profile.freeze(handle)
      :trace.session_destroy(handle.profile_session)
      result = Profile.collect(handle)

      assert :counters_unreadable in result.coverage.failures
      assert result.validity.status == :invalid
    end

    test "a failed freeze invalidates the profile" do
      handle = activate()
      :trace.session_destroy(handle.profile_session)
      result = handle |> Profile.freeze() |> Profile.collect()

      assert :freeze_failed in result.coverage.failures
      assert result.validity.status == :invalid
    end

    test "a module purged after the freeze loses its counters and invalidates the profile" do
      handle = activate()
      [{mod, _}] = Code.compile_string("defmodule ProfilePurged do def f, do: :ok end")
      task(fn -> mod.f() end)
      handle = Profile.freeze(handle)
      :code.delete(mod)
      :code.purge(mod)
      result = Profile.collect(handle)

      assert :code_lost in result.coverage.failures
      assert result.validity.status == :invalid
    end

    test "a module reloaded after the freeze invalidates the profile" do
      [{mod, beam}] = Code.compile_string("defmodule ProfileReloadedAfter do def f, do: :ok end")

      on_exit(fn ->
        :code.purge(mod)
        :code.delete(mod)
        :code.purge(mod)
      end)

      handle = activate()
      task(fn -> mod.f() end)
      handle = Profile.freeze(handle)
      {:module, ^mod} = :code.load_binary(mod, ~c"nofile", beam)
      result = Profile.collect(handle)

      assert Enum.any?([:code_lost, :counters_unreadable], &(&1 in result.coverage.failures))
      assert result.validity.status == :invalid
    end

    test "code purged in the window invalidates the profile" do
      handle = activate()
      [{mod, _}] = Code.compile_string("defmodule ProfilePurgedInWindow do def f, do: :ok end")
      task(fn -> mod.f() end)
      :code.delete(mod)
      :code.purge(mod)
      result = handle |> Profile.freeze() |> Profile.collect()

      assert :code_changed in result.coverage.failures
      assert result.validity.status == :invalid
    end

    test "a byte-identical reload in the window invalidates the profile" do
      [{mod, beam}] = Code.compile_string("defmodule ProfileReloaded do def f, do: :ok end")

      on_exit(fn ->
        :code.purge(mod)
        :code.delete(mod)
        :code.purge(mod)
      end)

      handle = activate()
      task(fn -> mod.f() end)
      {:module, ^mod} = :code.load_binary(mod, ~c"nofile", beam)
      task(fn -> mod.f() end)
      result = handle |> Profile.freeze() |> Profile.collect()

      assert :code_changed in result.coverage.failures
      assert result.validity.status == :invalid
    end

    test "proven-traced pids passed to collect are recorded, even without counters" do
      handle = activate() |> Profile.freeze()
      pid = spawn(&Work.park/0)
      on_exit(fn -> Process.exit(pid, :kill) end)
      assert Profile.traced?(handle, pid)
      refute Profile.traced?(handle, self())
      result = Profile.collect(handle, [pid])

      assert result.records[pid] == :other
      assert result.classes.other.pids == 1
    end

    test "a traced member with no counter rows counts toward its class's pids" do
      client = spawn(&Work.park/0)
      on_exit(fn -> Process.exit(client, :kill) end)
      result = activate(clients: fn -> [client] end) |> Profile.freeze() |> Profile.collect()

      refute Enum.any?(result.functions, &(&1.class == :client))
      assert result.classes.client == %{pids: 1, calls: 0, own_us: 0}
    end

    test "collect waits for every trace-delivery acknowledgement, on both sessions" do
      test = self()

      deliver = fn session, tracee ->
        ref = make_ref()
        send(test, {:deliver, self(), session, tracee, ref})
        ref
      end

      handle = activate(deliver: deliver) |> Profile.freeze()
      collecting = Task.async(fn -> Profile.collect(handle) end)

      acked =
        for _ <- 1..3 do
          assert_receive {:deliver, collector, session, tracee, ref}
          assert Task.yield(collecting, 200) == nil
          send(collector, {:trace_delivered, tracee, ref})
          {session, tracee}
        end

      assert Enum.sort(acked) ==
               Enum.sort([
                 {handle.class_session, Process.whereis(Elara.SessionSup)},
                 {handle.class_session, Process.whereis(Elara.TaskSup)},
                 {handle.profile_session, :all}
               ])

      result = Task.await(collecting)
      refute :delivery_unconfirmed in result.coverage.failures
    end

    test "an unacknowledged profile-session barrier invalidates the profile" do
      deliver = fn
        session, tracee ->
          ref = make_ref()
          unless tracee == :all, do: send(self(), {:trace_delivered, tracee, ref})
          _ = session
          ref
      end

      handle = activate(deliver: deliver, barrier_ms: 50)
      result = handle |> Profile.freeze() |> Profile.collect()

      assert :delivery_unconfirmed in result.coverage.failures
      assert result.validity.status == :invalid
    end

    test "losing the future-process setting before the freeze invalidates the profile" do
      handle = activate()
      :trace.process(handle.profile_session, :new_processes, false, [:call])
      result = handle |> Profile.freeze() |> Profile.collect()

      assert :future_processes_lost in result.coverage.failures
      assert result.validity.status == :invalid
    end

    test "losing spawn observation invalidates the profile and disables other by elimination" do
      handle = activate()
      :trace.process(handle.class_session, Process.whereis(Elara.TaskSup), false, [:procs])
      t = Task.Supervisor.async_nolink(Elara.TaskSup, fn -> Work.spin(10) end)
      Task.await(t)
      result = handle |> Profile.freeze() |> Profile.collect()

      assert :classification_lost in result.coverage.failures
      assert result.validity.status == :invalid
      assert result.records[t.pid] == :unclassified
    end

    test "collect waits for the classifier to process every delivered spawn" do
      handle = activate(hold: true)
      t = Task.Supervisor.async_nolink(Elara.TaskSup, fn -> Work.spin(10) end)
      Task.await(t)
      handle = Profile.freeze(handle)
      collecting = Task.async(fn -> Profile.collect(handle) end)

      assert Task.yield(collecting, 200) == nil
      Profile.release(handle)
      result = Task.await(collecting)
      assert result.records[t.pid] == :task
    end

    defp restart_exec do
      old = Process.whereis(Elara.Exec)
      Process.exit(old, :kill)
      assert wait_until(fn -> Process.whereis(Elara.Exec) not in [nil, old] end, 500)
      Process.whereis(Elara.Exec)
    end

    test "a named actor replaced in the window invalidates the profile; its successor is not other" do
      handle = activate()
      successor = restart_exec()
      result = handle |> Profile.freeze() |> Profile.collect([successor])

      assert :named_actor_replaced in result.coverage.failures
      assert result.validity.status == :invalid
      refute result.records[successor] == :other
    end

    test "a named actor replaced after the freeze, before collection, invalidates the profile" do
      handle = activate() |> Profile.freeze()
      restart_exec()
      result = Profile.collect(handle)

      assert :named_actor_replaced in result.coverage.failures
      assert result.validity.status == :invalid
    end

    test "a dead classifier invalidates the profile and records nothing as other" do
      handle = activate()
      {pid, ref} = spawn_monitor(fn -> Work.spin(10) end)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      Process.exit(handle.classifier, :kill)
      result = handle |> Profile.freeze() |> Profile.collect()

      assert :classifier_down in result.coverage.failures
      assert result.validity.status == :invalid
      refute result.records[pid] == :other
      assert gone?(handle)
    end
  end

  describe "cleanup" do
    test "collect destroys both sessions and stops the classifier" do
      handle = activate()
      Profile.collect(Profile.freeze(handle))
      assert gone?(handle)
      assert Profile.dispose(handle) == :ok
    end

    test "a raise inside collect still disposes" do
      calls = :counters.new(1, [])

      clients = fn ->
        :counters.add(calls, 1, 1)
        if :counters.get(calls, 1) > 1, do: raise("boom in clients"), else: []
      end

      handle = activate(clients: clients)
      handle = Profile.freeze(handle)
      assert_raise RuntimeError, fn -> Profile.collect(handle) end
      assert gone?(handle)
    end

    test "an unresponsive classifier is killed within the stop bound, and disposal completes" do
      handle = activate(stop_ms: 100)
      :erlang.suspend_process(handle.classifier)
      {elapsed_us, :ok} = :timer.tc(fn -> Profile.dispose(handle) end)

      assert elapsed_us < 2_000_000
      assert gone?(handle)
    end

    test "a failure between activation and collection is disposed" do
      handle = activate()
      assert Profile.dispose(handle) == :ok
      assert Profile.dispose(handle) == :ok
      assert gone?(handle)
    end

    for point <- [:classification_started, :patterns_set, :future_enabled, :census_done] do
      test "a raise at #{point} disposes what activation created" do
        point = unquote(point)

        hook = fn
          ^point, _sessions -> raise "boom at #{point}"
          _, _ -> :ok
        end

        assert_raise RuntimeError, fn -> activate(hook: hook) end
        assert our_sessions(:new_processes) == []
        assert our_sessions(Process.whereis(Elara.TaskSup)) == []
      end
    end

    test "a missing required option raises before any resource exists" do
      assert classifiers() == []

      assert_raise KeyError, fn ->
        Profile.activate(t0: 0, clients: fn -> [] end, connections: fn -> [] end)
      end

      assert our_sessions(:new_processes) == []
      assert our_sessions(Process.whereis(Elara.TaskSup)) == []
      assert classifiers() == []
    end

    test "an exit from a callback during activation propagates and disposes" do
      clients = fn -> GenServer.call(:elara_profile_no_such_server, :ping) end
      assert catch_exit(activate(clients: clients))
      assert our_sessions(:new_processes) == []
      assert our_sessions(Process.whereis(Elara.TaskSup)) == []
    end

    test "the owner's death destroys both sessions and stops the classifier" do
      parent = self()

      owner =
        spawn(fn ->
          handle =
            Profile.activate(
              t0: System.monotonic_time(:millisecond),
              window: {0, 600_000},
              clients: fn -> [] end,
              connections: fn -> [] end
            )

          send(parent, {:handle, handle})
          Work.park()
        end)

      assert_receive {:handle, handle}, 5_000
      Process.exit(owner, :kill)
      assert wait_until(fn -> gone?(handle) end)
    end
  end

  describe "validity/1" do
    defp window(a1, a2, f1, f2), do: %{a1: a1, a2: a2, f1: f1, f2: f2}

    defp judge(window, opts \\ []) do
      Profile.validity(%{
        window: window,
        from: 480_000,
        to: 600_000,
        failures: Keyword.get(opts, :failures, []),
        unclassified_share: Keyword.get(opts, :unclassified, 0.0)
      })
    end

    test "every lateness at 5 s is valid; one past it is qualified" do
      assert judge(window(485_000, 490_000, 605_000, 610_000)).status == :valid

      for w <- [
            window(485_001, 490_001, 600_000, 600_000),
            window(480_000, 485_001, 600_000, 600_000),
            window(480_000, 480_000, 605_001, 605_001),
            window(480_000, 480_000, 600_000, 605_001)
          ] do
        assert judge(w).status == :qualified, inspect(w)
      end
    end

    test "every lateness at 30 s is qualified; one past it is invalid" do
      assert judge(window(480_000, 480_000, 600_000, 630_000)).status == :qualified
      assert judge(window(480_000, 480_000, 630_000, 630_000)).status == :qualified

      for w <- [
            window(510_001, 510_001, 600_000, 600_000),
            window(480_000, 510_001, 600_000, 600_000),
            window(480_000, 480_000, 630_001, 630_001),
            window(480_000, 480_000, 600_000, 630_001)
          ] do
        assert judge(w).status == :invalid, inspect(w)
      end
    end

    test "overlap of the interior with the interval must reach 90%, before any valid verdict" do
      assert judge(window(480_000, 492_000, 600_000, 600_000)).status == :qualified
      assert judge(window(480_000, 492_001, 600_000, 600_000)).status == :invalid
      assert judge(window(480_000, 480_001, 580_000, 580_001)).status == :invalid
    end

    test "unclassified share up to 1% keeps validity; above invalidates" do
      w = window(480_000, 480_000, 600_000, 600_000)
      assert judge(w, unclassified: 0.01).status == :valid
      assert judge(w, unclassified: 0.010001).status == :invalid
    end

    test "any coverage failure invalidates" do
      w = window(480_000, 480_000, 600_000, 600_000)
      verdict = judge(w, failures: [:census_unverified])
      assert verdict.status == :invalid
      assert :census_unverified in verdict.reasons
    end
  end

  test "the audited spawn paths hold: the only TaskSup start_child is the server's closure" do
    sites =
      for path <- Path.wildcard("lib/**/*.ex"),
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          line =~ ~r/Task\.Supervisor\.start_child\(/,
          do: {path, n, line}

    assert [{"lib/elara/server.ex", _n, line}] = sites,
           "Elara.Lab.Profile classifies TaskSup spawns on the reply path as tasks; " <>
             "a new start_child site breaks that audit: #{inspect(sites)}"

    assert line =~ ~r/Task\.Supervisor\.start_child\(Elara\.TaskSup, fn ->/,
           "the server connection must stay closure-based for Elara.Lab.Profile: #{line}"
  end
end
