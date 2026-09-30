defmodule Elara.Lab.Scenarios.Concurrency.ProfilingTest do
  use ExUnit.Case, async: false

  alias Elara.Lab.Scenarios.Concurrency.Profiling

  defp opts(extra \\ []) do
    Keyword.merge(
      [
        # A zero-length window at t0: activation and freeze are milliseconds late.
        t0: System.monotonic_time(:millisecond),
        window: {0, 0},
        clients: fn -> [] end,
        connections: fn -> [] end
      ],
      extra
    )
  end

  defp profile_sessions do
    for {name, _id} <- :trace.session_info(:new_processes),
        String.starts_with?(Atom.to_string(name), "elara_lab_profile"),
        do: name
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  # A collection state around a fake collector, for the outcome rules alone.
  defp fake(collector, deadline_in_ms) do
    started = System.monotonic_time(:millisecond)
    holder = :ets.new(:profiling_test, [:set, :public])
    on_exit(fn -> if :ets.info(holder) != :undefined, do: :ets.delete(holder) end)

    %{
      holder: holder,
      collector: collector,
      started: started,
      deadline: started + deadline_in_ms
    }
  end

  defp dead do
    {pid, ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    pid
  end

  defp publish(state, outcome), do: :ets.insert(state.holder, {:outcome, outcome})

  describe "the collector's lifetime" do
    test "killing the owner while the collector is gated ends the collector, classifier and sessions" do
      test = self()

      hook = fn
        :profile_collect ->
          send(test, {:gated, self()})
          receive do: (:never -> :ok)

        _point ->
          :ok
      end

      owner =
        spawn(fn ->
          state =
            opts() |> Profiling.start() |> Profiling.freeze() |> Profiling.collect(60_000, hook)

          send(test, {:state, state})
          receive do: (:never -> :ok)
        end)

      assert_receive {:state, state}, 10_000
      assert_receive {:gated, collector}, 10_000
      assert collector == state.collector

      Process.exit(owner, :kill)

      assert wait_until(fn -> not Process.alive?(collector) end)
      assert wait_until(fn -> not Process.alive?(state.handle.classifier) end)
      assert wait_until(fn -> profile_sessions() == [] end)
    end

    test "a live collector past its deadline is unlinked, killed and confirmed dead; its owner survives" do
      collector = spawn_link(fn -> receive do: (:never -> :ok) end)
      outcome = Profiling.await(fake(collector, 50))

      assert outcome.status == :collection_timeout
      assert outcome.result == nil
      refute Process.alive?(collector)
      assert Process.alive?(self())
    end

    test "join cancels a live collector and removes the holder; it is idempotent" do
      collector = spawn_link(fn -> receive do: (:never -> :ok) end)
      state = fake(collector, 60_000)

      assert Profiling.join(state) == :ok
      refute Process.alive?(collector)
      assert :ets.info(state.holder) == :undefined
      assert Profiling.join(state) == :ok
      assert Profiling.join(nil) == :ok
    end
  end

  describe "the outcome" do
    test "a timely outcome read after its deadline is kept" do
      state = fake(dead(), 100)
      publish(state, {:done, %{kept: true}, state.started + 10})
      Process.sleep(150)

      outcome = Profiling.await(state)
      assert outcome.status == :ok
      assert outcome.result == %{kept: true}
      assert outcome.collection_ms == 10
    end

    test "an outcome published after its deadline is a timeout, with its data kept" do
      state = fake(dead(), 100)
      publish(state, {:done, %{kept: true}, state.started + 101})

      outcome = Profiling.await(state)
      assert outcome.status == :collection_timeout
      assert outcome.result == %{kept: true}
    end

    test "an empty holder is read again once the collector is seen dead, before failing" do
      state = fake(dead(), 60_000)
      reads = :counters.new(1, [])

      # The collector published between the first read and the liveness check.
      read = fn holder ->
        :counters.add(reads, 1, 1)

        if :counters.get(reads, 1) == 1 do
          publish(state, {:done, %{late: true}, state.started + 5})
          nil
        else
          Profiling.read(holder)
        end
      end

      outcome = Profiling.await(state, read: read)
      assert outcome.status == :ok
      assert outcome.result == %{late: true}
    end

    test "a failure published after its deadline is a timeout, with its reason kept" do
      state = fake(dead(), 100)
      publish(state, {:failed, :error, "late boom", state.started + 101})

      outcome = Profiling.await(state)
      assert outcome.status == :collection_timeout
      assert outcome.reason == "late boom"
    end

    test "a dead collector with an empty holder is a collection failure" do
      outcome = Profiling.await(fake(dead(), 60_000))
      assert outcome.status == :collection_failed
      assert outcome.result == nil
    end

    test "a failure the collector recorded is a collection failure with its reason" do
      state = fake(dead(), 60_000)
      publish(state, {:failed, :error, "boom", state.started + 5})

      outcome = Profiling.await(state)
      assert outcome.status == :collection_failed
      assert outcome.reason == "boom"
    end
  end

  describe "a real collection" do
    test "a collector that raises records its failure, and the handle is still disposable" do
      hook = fn
        :profile_collect -> raise "boom in collect"
        _point -> :ok
      end

      state = opts() |> Profiling.start() |> Profiling.freeze() |> Profiling.collect(60_000, hook)
      outcome = Profiling.await(state)

      assert outcome.status == :collection_failed
      assert outcome.reason =~ "boom in collect"
      Profiling.join(state)
      Elara.Lab.Profile.dispose(state.handle)
      assert profile_sessions() == []
    end

    test "a completed collection reports both censuses without pid-keyed data, and encodes as JSON" do
      client = spawn(fn -> receive do: (:never -> :ok) end)
      on_exit(fn -> Process.exit(client, :kill) end)

      state =
        opts(clients: fn -> [client] end)
        |> Profiling.start()
        |> tap(fn _ ->
          Task.Supervisor.async_nolink(Elara.TaskSup, fn -> :ok end) |> Task.await()
        end)
        |> Profiling.freeze()
        |> Profiling.collect(60_000, fn _ -> :ok end)

      outcome = Profiling.await(state)
      Profiling.join(state)
      assert outcome.status == :ok
      # The first census ends before activation begins.
      assert state.before.ended_ms <= state.handle.a1

      profile =
        Profiling.report(state, outcome, %{checks: %{ok: true}, complete: true, incomplete: nil})

      refute Map.has_key?(profile, :records)
      assert profile.validity.status in [:valid, :qualified]
      assert profile.classes.client.pids == 1
      assert profile.clients_started == 1
      assert profile.memory.before_activation.classes.exec.pids == 1
      assert profile.memory.after_freeze.started_ms >= profile.memory.before_activation.ended_ms
      assert profile.collection_ms >= 0
      assert is_binary(JSON.encode!(profile))
      assert profile_sessions() == []
    end
  end

  test "a collector whose hook fails after publishing keeps its published outcome" do
    hook = fn
      :profile_collected -> raise "boom after publishing"
      _point -> :ok
    end

    state = opts() |> Profiling.start() |> Profiling.freeze() |> Profiling.collect(60_000, hook)
    outcome = Profiling.await(state)
    Profiling.join(state)

    assert outcome.status == :ok
    assert is_map(outcome.result)
  end

  describe "a failed collection keeps the evidence it has" do
    # Future tracing is lost before the freeze. One traced holder owns an ETS
    # table and an off-heap binary, so the second census has something to keep.
    defp without_future_tracing do
      state = Profiling.start(opts())
      test = self()

      holder =
        spawn(fn ->
          table = :ets.new(:profiling_holder, [:public])
          :ets.insert(table, {:k, :binary.copy("t", 4096)})
          send(test, {:table, table})
          blob = :binary.copy("b", 100_000)
          receive do: (:never -> blob)
        end)

      on_exit(fn -> Process.exit(holder, :kill) end)
      assert_receive {:table, table}
      :trace.process(state.handle.profile_session, holder, true, [:call])
      :trace.process(state.handle.profile_session, :new_processes, false, [:call])
      Process.put(:holder_table, table)
      Profiling.freeze(state)
    end

    defp facts, do: %{checks: %{a: true}, complete: true, incomplete: nil}

    defp assert_kept(profile, collection_reason) do
      assert profile.validity.status == :invalid
      assert :future_processes_lost in profile.validity.reasons
      assert collection_reason in profile.validity.reasons
      assert is_integer(profile.window.f1) and profile.window.a1 <= profile.window.f1
      census = profile.memory.after_freeze
      assert census.classification == :unavailable
      assert is_map(census.memory)
      assert profile.counters == :unavailable
      assert is_binary(JSON.encode!(profile))
    end

    # The captured holders' measurements survive, under an unavailable class.
    defp assert_census_kept(profile, state) do
      census = profile.memory.after_freeze
      captured = state.capture.processes
      assert captured != []
      assert census.classes.unavailable.pids == length(captured)

      assert census.classes.unavailable.process_bytes ==
               captured |> Enum.map(&elem(&1, 1)) |> Enum.sum()

      unique =
        captured
        |> Enum.flat_map(&elem(&1, 2))
        |> Enum.uniq_by(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))
        |> Enum.sum()

      assert unique >= 100_000
      assert census.binary_unique_total == unique

      table = inspect(Process.get(:holder_table))
      assert Enum.find(census.ets, &(&1.table == table)).class == :unavailable

      owners = MapSet.new(captured, &elem(&1, 0))

      for {t, owner, _bytes} <- state.capture.ets do
        row = Enum.find(census.ets, &(&1.table == inspect(t)))
        expected = if MapSet.member?(owners, owner), do: :unavailable, else: :unmeasured
        assert row.class == expected
      end
    end

    test "on a timeout" do
      hook = fn
        :profile_collect -> Process.sleep(2_000)
        _point -> :ok
      end

      state = without_future_tracing() |> Profiling.collect(50, hook)
      outcome = Profiling.await(state)
      Profiling.join(state)
      Elara.Lab.Profile.dispose(state.handle)

      assert outcome.status == :collection_timeout
      profile = Profiling.report(state, outcome, facts())
      assert_kept(profile, :collection_timeout)
      assert_census_kept(profile, state)
    end

    test "on a crash" do
      hook = fn
        :profile_collect -> raise "boom"
        _point -> :ok
      end

      state = without_future_tracing() |> Profiling.collect(60_000, hook)
      outcome = Profiling.await(state)
      Profiling.join(state)
      Elara.Lab.Profile.dispose(state.handle)

      assert outcome.status == :collection_failed
      profile = Profiling.report(state, outcome, facts())
      assert_kept(profile, :collection_failed)
      assert_census_kept(profile, state)
      assert profile.collection_failure =~ "boom"
    end
  end

  describe "eligibility" do
    defp collected do
      state =
        opts()
        |> Profiling.start()
        |> Profiling.freeze()
        |> Profiling.collect(60_000, fn _ -> :ok end)

      outcome = Profiling.await(state)
      Profiling.join(state)
      {state, outcome}
    end

    test "no activation is reported as invalid, not activated" do
      profile = Profiling.report(nil, nil, %{checks: %{}, complete: true, incomplete: nil})
      assert profile.validity == %{status: :invalid, reasons: [:not_activated]}
      assert is_binary(JSON.encode!(profile))
    end

    test "failed run checks and an incomplete run invalidate the profile" do
      {state, outcome} = collected()

      ok =
        Profiling.report(state, outcome, %{checks: %{a: true}, complete: true, incomplete: nil})

      assert ok.validity.status in [:valid, :qualified]

      failed =
        Profiling.report(state, outcome, %{checks: %{a: false}, complete: true, incomplete: nil})

      assert failed.validity.status == :invalid
      assert :run_checks_failed in failed.validity.reasons

      for facts <- [
            %{checks: %{a: true}, complete: false, incomplete: nil},
            %{checks: %{a: true}, complete: true, incomplete: :watchdog}
          ] do
        profile = Profiling.report(state, outcome, facts)
        assert profile.validity.status == :invalid
        assert :run_incomplete in profile.validity.reasons
      end
    end

    test "a collection timeout or failure invalidates the profile, keeping any data" do
      {state, outcome} = collected()

      late =
        Profiling.report(state, %{outcome | status: :collection_timeout}, %{
          checks: %{a: true},
          complete: true,
          incomplete: nil
        })

      assert late.validity.status == :invalid
      assert :collection_timeout in late.validity.reasons
      assert is_map(late.classes)

      failed =
        Profiling.report(
          state,
          %{outcome | status: :collection_failed, result: nil, reason: "x"},
          %{
            checks: %{a: true},
            complete: true,
            incomplete: nil
          }
        )

      assert failed.validity == %{status: :invalid, reasons: [:collection_failed]}
      assert failed.collection_failure == "x"
    end
  end
end
