defmodule Elara.Lab.SessionRecoveryTest do
  # Not async: the scenario swaps the sessions root and starts real sessions.
  use ExUnit.Case, async: false

  alias Elara.Lab.Scenarios.SessionRecovery
  alias Elara.Lab.Scenarios.SessionRecovery.{Coordinator, Deadline, Observer, StoreView}
  alias Elara.Message.{Assistant, ToolCall, ToolResult, User}
  alias Elara.Session.Store
  alias Elara.Session.Store.Entry

  @moduletag timeout: 60_000

  @inputs ["A", "B", "C"]

  setup do
    dir = Path.join(System.tmp_dir!(), "lab-recovery-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "registration names the ordinary direct-marker path and the 30-run schedule" do
    note = File.read!("docs/lab/005-shell-chaos.md")

    assert note =~ "effect_executor: nil"
    assert note =~ "provider_started,provider_streaming,tool_running"
    assert note =~ "--n 10 --seed 42"
    assert note =~ "MIX_ENV=dev"
    assert note =~ "interrupted"
    assert Elara.Lab.scenario_module("session_recovery") == {:ok, SessionRecovery}
  end

  test "the observer rejects missing fault, death, markers, ids, stale completion and a dead probe" do
    good = witness(:provider_started)

    assert Observer.judge(good).checks == expected_checks(:provider)

    for deficient <- deficient_witnesses() do
      judged = Observer.judge(deficient.witness)
      refute judged.checks[deficient.check], deficient.name
    end
  end

  test "a consumed-only receipt is not terminal, and marker bytes are not completion" do
    consumed =
      witness(:provider_started, fn witness ->
        put_in(witness.inputs["A"].receipt, %{state: :consumed, error: nil})
      end)

    bytes =
      witness(:tool_running, fn witness ->
        witness
        |> put_in([:inputs, "A", :receipt], nil)
        |> put_in([:inputs, "A", :active_cleared], false)
        |> Map.put(:marker_bytes, ["A"])
      end)

    refute Observer.judge(consumed).checks.settled_receipts
    refute Observer.judge(bytes).checks.indeterminate_without_receipt
    refute Observer.judge(bytes).checks.settled_receipts
  end

  test "the observer rejects every demonstrated raw-evidence false positive" do
    good = witness(:provider_started)

    mutations = [
      {"missing physical markers", :physical_marker_counts, &Map.put(&1, :marker_bytes, [])},
      {"duplicate physical markers", :physical_marker_counts,
       &Map.put(&1, :marker_bytes, ["B", "B", "C"])},
      {"unexpected physical marker", :physical_marker_counts,
       &Map.put(&1, :marker_bytes, ["B", "C", "Z"])},
      {"missing terminal answer", :history_identity,
       &update_in(&1.history, fn history -> Enum.drop(history, -1) end)},
      {"interrupted terminal answer", :history_identity,
       &update_last_terminal(&1, "C", fn answer -> Map.put(answer, "interrupted", true) end)},
      {"extra user", :history_identity,
       &update_in(&1.history, fn history ->
         history ++ [%{"id" => "user-Z", "kind" => "user", "text" => "input Z"}]
       end)},
      {"duplicate user", :history_identity,
       &update_in(&1.history, fn [user | _] = history -> [user | history] end)},
      {"reordered user", :history_identity,
       &update_in(&1.history, fn [a, b, c | rest] -> [c, b, a | rest] end)},
      {"duplicate call", :history_identity,
       fn witness ->
         duplicate_kind(witness, "B", "assistant", fn entry -> entry["tool_calls"] != [] end)
       end},
      {"misplaced call", :history_identity, &move_kind_before_user(&1, "B", "assistant")},
      {"wrong call id", :history_identity,
       &update_call(&1, "B", fn call -> Map.put(call, "id", "wrong") end)},
      {"wrong call name", :history_identity,
       &update_call(&1, "B", fn call -> Map.put(call, "name", "wrong") end)},
      {"duplicate result", :history_identity,
       fn witness -> duplicate_kind(witness, "B", "tool_result", fn _ -> true end) end},
      {"reordered result", :history_identity, &move_kind_before_user(&1, "B", "tool_result")},
      {"wrong result id", :history_identity,
       &update_result(&1, "B", fn result -> Map.put(result, "call_id", "wrong") end)},
      {"wrong result name", :history_identity,
       &update_result(&1, "B", fn result -> Map.put(result, "name", "wrong") end)},
      {"forged accepted mapping", :exact_identities,
       &put_in(&1.inputs["B"].persisted_user_id, &1.inputs["B"].accepted_id)},
      {"stale persisted identity", :exact_identities,
       &put_in(&1.inputs["B"].persisted_user_id, "stale")},
      {"active persisted input", :active_input_cleared, &Map.put(&1, :active_input_id, "in-B")},
      {"missing persisted state", :persisted_state_read, &Map.put(&1, :store_read, false)}
    ]

    assert Observer.judge(good).checks.physical_marker_counts
    assert Observer.judge(good).checks.persisted_state_read

    for {name, check, mutate} <- mutations do
      refute Observer.judge(mutate.(good)).checks[check], name
    end
  end

  test "typed tool outcomes, not receipt prose, determine marker uncertainty" do
    negated =
      witness(:tool_running, fn witness ->
        witness
        |> put_in([:inputs, "A", :receipt], %{state: :failed, error: "indeterminate"})
        |> update_result("A", fn result ->
          put_in(result["outcome"], %{
            "kind" => "error",
            "text" => "not indeterminate: definitely failed"
          })
        end)
      end)

    typed =
      update_result(negated, "A", fn result ->
        put_in(result["outcome"], %{"kind" => "indeterminate", "text" => "unknown"})
      end)

    refute Observer.judge(negated).checks.indeterminate_without_receipt
    assert Observer.judge(typed).checks.indeterminate_without_receipt
  end

  test "the coordinator holds the selected caller through a witnessed barrier and injects once" do
    {:ok, coordinator} =
      Coordinator.start_link(
        fault: :provider_started,
        point: :provider_started,
        key: "recovery:1"
      )

    on_exit(fn -> Coordinator.stop(coordinator) end)

    caller =
      spawn(fn -> Coordinator.hook(coordinator, :provider_started, "recovery:1", :task) end)

    assert {:ok, arrival} = Coordinator.await_arrival(coordinator, 500)
    assert arrival.target == caller
    assert arrival.monitor_installed_at <= arrival.arrived_at
    assert Process.alive?(caller)
    refute Coordinator.snapshot(coordinator).released
    assert {:error, :barrier_incomplete} = Coordinator.release(coordinator)

    assert :ok = Coordinator.witness_backlog(coordinator, ["in-B", "in-C"])
    assert :ok = Coordinator.release(coordinator)
    assert {:ok, death} = Coordinator.await_down(coordinator, 500)
    assert death.target == caller
    assert death.reason == :killed
    assert Coordinator.snapshot(coordinator).injections == 1

    repeated =
      Task.async(fn -> Coordinator.hook(coordinator, :provider_started, "recovery:1", :task) end)

    assert {:ok, :skip} = Task.yield(repeated, 100)
    assert Coordinator.snapshot(coordinator).injections == 1
  end

  test "the coordinator rejects missing and unrelated death and preserves early return" do
    {:ok, coordinator} =
      Coordinator.start_link(fault: :tool_running, point: :tool_running, key: "label:A")

    on_exit(fn -> Coordinator.stop(coordinator) end)
    unrelated = spawn(fn -> :ok end)
    ref = Process.monitor(unrelated)
    assert_receive {:DOWN, ^ref, :process, ^unrelated, _}
    send(coordinator, {:DOWN, make_ref(), :process, unrelated, :normal})
    assert {:error, :timeout} = Coordinator.await_down(coordinator, 20)

    target = spawn(fn -> receive do: (:stop -> :ok) end)
    assert :ok = Coordinator.observe_target(coordinator, target)
    assert :ok = Coordinator.record_hook_return(coordinator)
    Process.exit(target, :kill)
    assert {:ok, %{target: ^target}} = Coordinator.await_down(coordinator, 500)
    assert :ok = Coordinator.record_hook_return(coordinator)
    assert Coordinator.snapshot(coordinator).hook_returned_before_down
  end

  test "reporting cannot claim completeness when owned-resource cleanup is unconfirmed" do
    cleanup = %{
      confirmed: false,
      choices: %{},
      sessions: [false],
      helpers_settled: false,
      collector_settled: true,
      coordinator_settled: true,
      unresolved: [:start]
    }

    report = Observer.report(witness(:provider_started), cleanup)
    refute report.complete
    refute report.cleanup_confirmed
    assert report.bounds == %{"recovery" => "undetermined", "backlog" => "undetermined"}
  end

  test "absolute deadlines settle blocked helpers and report structured failures" do
    {:ok, coordinator} = Coordinator.start_link(fault: :provider_started)
    on_exit(fn -> Coordinator.stop(coordinator) end)

    for operation <- [
          :probe,
          :start,
          :reopen,
          :stop,
          :status,
          :snapshot,
          :submit,
          :resume,
          :choices,
          :find_path,
          :store_read,
          :marker_read
        ] do
      started = System.monotonic_time(:millisecond)

      assert {:error, {:timeout, ^operation}} =
               Deadline.call(coordinator, operation, started + 30, fn ->
                 Process.sleep(:infinity)
               end)

      assert System.monotonic_time(:millisecond) - started < 250
      assert Coordinator.snapshot(coordinator).helpers == []
    end

    assert :start in Coordinator.snapshot(coordinator).unresolved
    assert :reopen in Coordinator.snapshot(coordinator).unresolved
  end

  test "expired and delayed deadline registration cannot execute work" do
    {:ok, coordinator} = Coordinator.start_link(fault: :provider_started)
    on_exit(fn -> Coordinator.stop(coordinator) end)
    owner = self()

    assert {:error, {:timeout, :start}} =
             Deadline.call(coordinator, :start, System.monotonic_time(:millisecond) - 1, fn ->
               send(owner, :expired_work_ran)
               :started
             end)

    refute_receive :expired_work_ran, 20

    :sys.suspend(coordinator)

    resumer =
      spawn(fn ->
        Process.sleep(100)
        :sys.resume(coordinator)
      end)

    started = System.monotonic_time(:millisecond)

    assert {:error, {:timeout, :probe}} =
             Deadline.call(coordinator, :probe, started + 20, fn ->
               send(owner, :delayed_work_ran)
               :completed
             end)

    assert System.monotonic_time(:millisecond) - started < 80
    refute_receive :delayed_work_ran, 120
    refute Process.alive?(resumer)
    assert Coordinator.snapshot(coordinator).helpers == []
  end

  test "a success completed after the absolute deadline is rejected" do
    {:ok, coordinator} = Coordinator.start_link(fault: :provider_started)
    on_exit(fn -> Coordinator.stop(coordinator) end)
    owner = self()
    deadline = System.monotonic_time(:millisecond) + 40

    caller =
      Task.async(fn ->
        Deadline.call(coordinator, :probe, deadline, fn ->
          send(owner, {:deadline_helper, self()})

          receive do
            :finish -> :late_success
          end
        end)
      end)

    assert_receive {:deadline_helper, helper}, 100
    true = :erlang.suspend_process(caller.pid)
    Process.sleep(50)
    send(helper, :finish)
    Process.sleep(10)
    true = :erlang.resume_process(caller.pid)

    assert {:error, {:timeout, :probe}} = Task.await(caller, 500)
    assert Coordinator.snapshot(coordinator).helpers == []
  end

  test "coordinator polling obeys its deadline while the coordinator is suspended" do
    {:ok, coordinator} = Coordinator.start_link(fault: :provider_started)
    on_exit(fn -> Coordinator.stop(coordinator) end)
    :sys.suspend(coordinator)

    resumer =
      spawn(fn ->
        Process.sleep(100)
        :sys.resume(coordinator)
      end)

    started = System.monotonic_time(:millisecond)
    assert {:error, :timeout} = Coordinator.await_arrival(coordinator, 20)
    assert System.monotonic_time(:millisecond) - started < 80
    Process.sleep(100)
    refute Process.alive?(resumer)
  end

  test "a blocked persisted-store read obeys its absolute deadline", %{dir: dir} do
    {:ok, coordinator} = Coordinator.start_link(fault: :provider_started)
    on_exit(fn -> Coordinator.stop(coordinator) end)
    store = persisted_store(dir)
    fifo = Path.join(dir, "blocked-store")
    {_, 0} = System.cmd("mkfifo", [fifo])

    writer =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :exit_status,
        args: ["-c", "sleep 0.15; cat \"$1\" > \"$2\"", "writer", store.path, fifo]
      ])

    started = System.monotonic_time(:millisecond)

    assert {:error, :store_deadline} =
             StoreView.await_failed(
               fifo,
               dir,
               "accepted-A",
               coordinator,
               started + 20
             )

    assert System.monotonic_time(:millisecond) - started < 100
    assert Coordinator.snapshot(coordinator).helpers == []
    Port.close(writer)
  end

  test "a blocked physical-marker read obeys its absolute deadline", %{dir: dir} do
    {:ok, coordinator} = Coordinator.start_link(fault: :provider_started)
    on_exit(fn -> Coordinator.stop(coordinator) end)
    marker_path = Path.join(dir, "marks.txt")
    {_, 0} = System.cmd("mkfifo", [marker_path])

    writer =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :exit_status,
        args: ["-c", "sleep 0.15; printf 'B\\nC\\n' > \"$1\"", "writer", marker_path]
      ])

    started = System.monotonic_time(:millisecond)

    assert {:error, :marker_deadline} =
             StoreView.read_markers(dir, coordinator, started + 20)

    assert System.monotonic_time(:millisecond) - started < 140
    assert_receive {^writer, {:exit_status, 0}}, 500
    Process.sleep(10)
    assert Coordinator.snapshot(coordinator).helpers == []
  end

  test "late successful start and reopen stay unresolved through actual cleanup", %{dir: dir} do
    for operation <- [:start, :reopen] do
      {:ok, coordinator} = Coordinator.start_link(fault: :provider_started)
      {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
      log = Elara.Lab.choice_log()
      assert :ok = Coordinator.track(coordinator, :collector, log)
      owner = self()
      deadline = System.monotonic_time(:millisecond) + 40
      :sys.suspend(supervisor)

      caller =
        Task.async(fn ->
          Deadline.call(coordinator, operation, deadline, fn ->
            send(owner, {:operation_launched, operation, self()})

            Elara.start_session_under(supervisor,
              cwd: dir,
              home: dir,
              skill_paths: [],
              plugins: [],
              tools: [],
              persist: true,
              provider: Elara.Provider.Simulated.new(seed: 42, id: "late-#{operation}")
            )
          end)
        end)

      assert_receive {:operation_launched, ^operation, helper}, 200
      assert helper in Coordinator.snapshot(coordinator).helpers
      true = :erlang.suspend_process(caller.pid)
      wait_until(deadline)
      :sys.resume(supervisor)
      assert_eventually(fn -> DynamicSupervisor.count_children(supervisor).active == 1 end)
      true = :erlang.resume_process(caller.pid)

      assert {:error, {:timeout, ^operation}} = Task.await(caller, 500)
      assert operation in Coordinator.snapshot(coordinator).unresolved

      cleanup = SessionRecovery.cleanup(coordinator, dir, log, false)
      report = Observer.report(witness(:provider_started), cleanup)

      refute cleanup.confirmed
      refute report.cleanup_confirmed
      refute report.complete
      assert report.bounds == %{"recovery" => "undetermined", "backlog" => "undetermined"}
      DynamicSupervisor.stop(supervisor)
    end
  end

  test "launched start and reopen failures remain unresolved" do
    for operation <- [:start, :reopen], failure <- [:invocation_error, :helper_down] do
      {:ok, coordinator} = Coordinator.start_link(fault: :provider_started)
      on_exit(fn -> Coordinator.stop(coordinator) end)
      owner = self()

      result =
        case failure do
          :invocation_error ->
            Deadline.call(coordinator, operation, System.monotonic_time(:millisecond) + 500, fn ->
              raise "#{operation} failed"
            end)

          :helper_down ->
            caller =
              Task.async(fn ->
                Deadline.call(
                  coordinator,
                  operation,
                  System.monotonic_time(:millisecond) + 500,
                  fn ->
                    send(owner, {:kill_start_helper, self()})
                    Process.sleep(:infinity)
                  end
                )
              end)

            assert_receive {:kill_start_helper, helper}, 200
            Process.exit(helper, :kill)
            Task.await(caller, 500)
        end

      assert match?({:error, _}, result)
      assert operation in Coordinator.snapshot(coordinator).unresolved
    end
  end

  test "aborted workload uses actual cleanup and cannot report completion", %{dir: dir} do
    {:ok, coordinator} = Coordinator.start_link(fault: :provider_started)
    log = Elara.Lab.choice_log()
    assert :ok = Coordinator.track(coordinator, :collector, log)

    cleanup = SessionRecovery.cleanup(coordinator, dir, log, false)
    report = Observer.report(witness(:provider_started), cleanup)

    refute cleanup.confirmed
    refute report.cleanup_confirmed
    refute report.complete
    assert report.bounds == %{"recovery" => "undetermined", "backlog" => "undetermined"}
  end

  test "bounded fallback discovery failure keeps cleanup unconfirmed", %{dir: dir} do
    {:ok, coordinator} = Coordinator.start_link(fault: :provider_started)
    log = Elara.Lab.choice_log()
    assert :ok = Coordinator.track(coordinator, :collector, log)
    store = Store.new(dir)
    File.mkdir_p!(Path.dirname(store.path))
    {_, 0} = System.cmd("mkfifo", [store.path])
    on_exit(fn -> File.rm(store.path) end)

    writer =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :exit_status,
        args: [
          "-c",
          "exec 3>\"$1\"; sleep 0.2; printf invalid >&3 || true",
          "writer",
          store.path
        ]
      ])

    started = System.monotonic_time(:millisecond)
    cleanup = SessionRecovery.cleanup(coordinator, dir, log, true)

    assert System.monotonic_time(:millisecond) - started < 180
    refute cleanup.confirmed
    refute cleanup.discovery_confirmed
    assert_receive {^writer, {:exit_status, 0}}, 500
    File.rm!(store.path)
  end

  test "saved and reopened persisted mutations fail settlement and reporting", %{dir: dir} do
    mutations = [
      {"reused B/C call IDs", &reuse_call_ids/1},
      {"wrong B inbox user", &wrong_inbox_user/1},
      {"wrong B inbox sender",
       &update_receipt(&1, "accepted-B", fn receipt -> %{receipt | sender_id: "wrong"} end)},
      {"wrong B inbox kind",
       &update_receipt(&1, "accepted-B", fn receipt -> %{receipt | kind: :steer} end)},
      {"misordered inbox receipts", &%{&1 | inbox: Enum.reverse(&1.inbox)}},
      {"extra interrupted C assistant", &extra_interrupted_c/1},
      {"multiple C terminal assistants", &duplicate_c_terminal/1},
      {"stale off-branch entry", &stale_off_branch/1},
      {"selected leaf before C completion", &leaf_before_c/1},
      {"leading terminal assistant", &prepend_history(&1, %Assistant{text: "unrelated"})},
      {"leading interrupted assistant",
       &prepend_history(&1, %Assistant{text: "partial", interrupted: true})},
      {"leading tool-call assistant",
       &prepend_history(
         &1,
         %Assistant{
           tool_calls: [
             %ToolCall{id: "orphan-call", name: "lab_marker", args: {:ok, %{"label" => "A"}}}
           ]
         }
       )},
      {"leading orphan tool result",
       &prepend_history(
         &1,
         %ToolResult{call_id: "orphan", name: "lab_marker", outcome: {:ok, "unexpected"}}
       )}
    ]

    for {name, mutate} <- mutations do
      store = dir |> persisted_store() |> mutate.() |> save_and_reopen(dir)
      refute StoreView.settled?(store, accepted_inputs()), name

      report =
        store
        |> StoreView.witness(witness_attrs(dir))
        |> Map.merge(protocol_evidence())
        |> Observer.report(confirmed_cleanup())

      refute report.complete, name
      assert report.bounds == %{"recovery" => "undetermined", "backlog" => "undetermined"}, name
      refute report.checks.history_identity and report.checks.exact_identities, name

      decoded = report |> JSON.encode!() |> JSON.decode!()
      assert decoded["complete"] == false
      assert decoded["bounds"] == %{"recovery" => "undetermined", "backlog" => "undetermined"}
      assert decoded["completed_turns"] <= 2
    end
  end

  test "store decoding rejects invalid receipt session and duplicate receipt IDs", %{dir: dir} do
    mutations = [
      &update_receipt(&1, "accepted-B", fn receipt -> %{receipt | session_id: "wrong"} end),
      &%{&1 | inbox: &1.inbox ++ [hd(&1.inbox)]}
    ]

    for mutate <- mutations do
      store = dir |> persisted_store() |> mutate.()
      {:ok, store} = Store.save(store)
      assert {:error, _reason} = Store.open(store.path, dir)
    end
  end

  test "coherent timing evidence reports threshold failures independently" do
    cleanup = confirmed_cleanup()

    recovery_failure =
      witness(:provider_started)
      |> put_timing(5_001, 5_002)
      |> Observer.report(cleanup)

    assert recovery_failure.complete
    assert recovery_failure.bounds == %{"recovery" => "fails", "backlog" => "holds"}
    assert recovery_failure.incomplete == nil

    backlog_failure =
      witness(:provider_started)
      |> put_timing(5_000, 7_001)
      |> Observer.report(cleanup)

    assert backlog_failure.complete
    assert backlog_failure.bounds == %{"recovery" => "holds", "backlog" => "fails"}

    inconsistent =
      witness(:provider_started)
      |> put_timing(10, 20)
      |> put_in([:clocks, :recovery, :ms], 9)
      |> Observer.report(cleanup)

    refute inconsistent.complete
    assert inconsistent.bounds == %{"recovery" => "undetermined", "backlog" => "undetermined"}
  end

  test "causal IDs, event timestamps, and clock summaries must agree" do
    mutations = [
      &put_in(&1.ordering.backlog_ids, ["wrong-B", "wrong-C"]),
      &put_in(&1.ordering.injected_at, nil),
      &put_in(&1.death.target, "other-target"),
      &put_in(&1.clocks.recovery.origin, "wrong-origin"),
      &shift_clock(&1, :recovery, -100),
      &shift_clock(&1, :recovery, 4),
      &shift_clock(&1, :recovery, 6),
      &shift_clock(&1, :backlog, 4),
      fn witness ->
        witness
        |> Map.put(:recovery_ms, 10)
        |> put_in([:clocks, :recovery, :endpoint_at], 1_000_004)
        |> put_in([:clocks, :recovery, :ms], 999_999)
      end
    ]

    for mutate <- mutations do
      report = witness(:provider_started) |> mutate.() |> Observer.report(confirmed_cleanup())
      refute report.complete
      assert report.bounds == %{"recovery" => "undetermined", "backlog" => "undetermined"}
    end
  end

  test "missing persisted state fails closed", %{dir: dir} do
    {:ok, coordinator} = Coordinator.start_link(fault: :provider_started)
    on_exit(fn -> Coordinator.stop(coordinator) end)

    accepted = %{
      "A" => %{id: "in-A"},
      "B" => %{id: "in-B"},
      "C" => %{id: "in-C"}
    }

    assert {:error, :store_deadline} =
             StoreView.await_pending(
               Path.join(dir, "missing.jsonl"),
               dir,
               accepted,
               coordinator,
               System.monotonic_time(:millisecond)
             )
  end

  test "the complete witness survives JSON round-trip without losing evidence" do
    witness = witness(:tool_running)
    encoded = JSON.encode!(witness)
    assert {:ok, decoded} = JSON.decode(encoded)

    assert decoded["inputs"]["A"]["accepted_id"] == "in-A"
    assert decoded["inputs"]["A"]["persisted_user_id"] == "user-A"
    assert Enum.any?(decoded["history"], &(&1["interrupted"] == true))
    assert decoded["inputs"]["A"]["tool_outcome"]["kind"] == "error"
    assert decoded["marker_bytes"] == ["A", "B", "C"]
    assert decoded["death"]["matched"] == true
    assert decoded["ordering"]["released_at"] < decoded["ordering"]["target_down_at"]
    assert decoded["clocks"]["backlog"]["origin"] == "explicit_resume"
    assert decoded["cleanup"]["confirmed"] == true
  end

  test "every fault's real result survives write_results with rule choices and host provenance" do
    root =
      Path.join(System.tmp_dir!(), "lab-recovery-lines-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)

    for fault <- ~w(provider_started provider_streaming tool_running) do
      {:ok, [result]} = Elara.Lab.run(SessionRecovery, seed: 42, params: %{"fault" => fault})
      kept = result[:evidence_dir] || result[:retained_dir]
      if kept, do: on_exit(fn -> File.rm_rf!(kept) end)

      path = Elara.Lab.write_results(Path.join(root, fault), [result])
      assert [line] = path |> File.read!() |> String.split("\n", trim: true)
      decoded = JSON.decode!(line)
      same = fn term -> term |> JSON.encode!() |> JSON.decode!() end

      assert decoded["fault"] == fault
      assert decoded["checks"] == same.(result.checks)
      assert decoded["incomplete"] == result.incomplete
      assert decoded["choices_digest"] == result.choices_digest

      choices = decoded["cleanup"]["choices"] |> Map.values() |> Enum.concat()
      assert Enum.any?(choices, &match?(["rule", index] when is_integer(index), &1))

      assert %{"commit" => _, "dirty" => _} = decoded["host"]
      assert decoded["recovery"]["receipts"]["A"] == same.(result.recovery.receipts["A"])

      assert decoded["recovery"]["tool_outcomes"]["A"] ==
               same.(result.recovery.tool_outcomes["A"])

      assert decoded["death"]["reason"] == "killed"
    end
  end

  test "finalize adds host provenance and makes nested terms JSON-safe" do
    pid = self()
    ref = make_ref()
    fun = fn -> :ok end

    result =
      SessionRecovery.finalize(%{
        choices: %{"sim" => [{:rule, 0}, {:tool, "lab_marker"}, :answer, {:error, :timeout}]},
        nested: %{1 => {:a, [{:b, pid}]}, "s" => ref, k: fun},
        plain: [true, nil, 1.5, "text", <<255>>]
      })

    assert result.choices == %{
             "sim" => [[:rule, 0], [:tool, "lab_marker"], :answer, [:error, :timeout]]
           }

    assert result.nested == %{
             "1" => [:a, [[:b, inspect(pid)]]],
             "s" => inspect(ref),
             k: inspect(fun)
           }

    assert result.plain == [true, nil, 1.5, "text", inspect(<<255>>)]
    assert %{commit: _, dirty: _} = result.host
    assert {:ok, decoded} = result |> JSON.encode!() |> JSON.decode()

    assert decoded["choices"]["sim"] == [
             ["rule", 0],
             ["tool", "lab_marker"],
             "answer",
             ["error", "timeout"]
           ]
  end

  test "the choices digest covers raw choices and survives finalize and write_results" do
    root =
      Path.join(System.tmp_dir!(), "lab-recovery-digest-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)

    raw = %{"recovery" => [{:rule, 0}, {:rule, 1}], "recovery-reopen" => [{:rule, 0}]}
    witness = witness(:provider_started)
    expected = Elara.Lab.digest({witness.fault, raw})

    result =
      witness
      |> Observer.report(%{confirmed: true, choices: raw})
      |> SessionRecovery.finalize()
      |> Map.merge(%{scenario: "session_recovery", seed: 42})

    decoded =
      Elara.Lab.write_results(root, [result]) |> File.read!() |> String.trim() |> JSON.decode!()

    assert decoded["choices_digest"] == expected

    assert decoded["cleanup"]["choices"] == %{
             "recovery" => [["rule", 0], ["rule", 1]],
             "recovery-reopen" => [["rule", 0]]
           }

    different_choices = Map.put(raw, "recovery", [{:rule, 1}, {:rule, 0}])

    refute Observer.report(witness, %{confirmed: true, choices: different_choices}).choices_digest ==
             expected

    refute Observer.report(witness(:provider_streaming), %{confirmed: true, choices: raw}).choices_digest ==
             expected
  end

  test "same-seed real recovery runs reproduce choices digests across fresh persisted identities" do
    for fault <- [:provider_started, :provider_streaming, :tool_running] do
      first = SessionRecovery.run(context(fault))
      second = SessionRecovery.run(context(fault))

      assert first.complete and second.complete
      assert first.cleanup.choices == second.cleanup.choices
      refute first.recovery.receipts["A"].session_id == second.recovery.receipts["A"].session_id
      assert first.choices_digest == second.choices_digest
    end
  end

  test "provider faults settle A failed and complete B and C; the marker path stays strict" do
    for fault <- [:provider_started, :provider_streaming] do
      result = SessionRecovery.run(context(fault))

      assert Elara.Lab.failed_checks(result) == [], inspect({fault, result.checks}, pretty: true)
      assert result.cleanup_confirmed
      assert result.cleanup.sessions != [] and Enum.all?(result.cleanup.sessions)
      assert result.cleanup.helpers_settled
      assert result.cleanup.collector_settled
      assert result.cleanup.coordinator_settled
      assert result.cleanup.unresolved == []
      assert result.recovery.accepted_ids == ["recovery-A", "recovery-B", "recovery-C"]
      assert Map.keys(result.recovery.receipts) == ["A", "B", "C"]
    end

    marker = SessionRecovery.run(context(:tool_running))

    assert Elara.Lab.failed_checks(marker) == [], inspect(marker.checks, pretty: true)

    assert marker.cleanup_confirmed
    assert marker.complete
    assert marker.checks.marker_hook_blocked_until_down
    assert marker.checks.no_input_while_paused
    assert is_integer(marker.recovery_ms)
    assert is_integer(marker.backlog_ms)

    # ROB-1235: the started marker call stays indeterminate on an ordinary
    # direct reopen; the input receipt still records the restart.
    assert marker.checks.indeterminate_without_receipt
    assert marker.recovery.receipts["A"].error == "session restarted"
  end

  test "an unknown fault is a structured failure and still confirms cleanup", %{dir: dir} do
    result =
      SessionRecovery.run(%{
        seed: 1,
        dir: dir,
        params: %{"fault" => "nope"},
        provider: :simulated
      })

    assert result.checks.known_fault == false
    assert result.incomplete == "unknown_fault"
    assert result.cleanup_confirmed
    assert result.bounds["recovery"] == "undetermined"
  end

  test "real mode is refused before any provider request", %{dir: dir} do
    assert_raise RuntimeError, ~r/simulated provider only/, fn ->
      SessionRecovery.run(%{seed: 1, dir: dir, params: %{}, provider: :real})
    end
  end

  defp context(fault) do
    dir = Path.join(System.tmp_dir!(), "lab-recovery-run-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)

    %{seed: 42, dir: dir, params: %{"fault" => Atom.to_string(fault)}, provider: :simulated}
  end

  defp persisted_store(dir) do
    store = Store.new(dir)

    store =
      Enum.reduce(@inputs, store, fn label, store ->
        {:ok, store} = Store.append(store, %User{text: "input #{label}"})

        if label == "A" do
          {:ok, store} = Store.append(store, %Assistant{text: "partial", interrupted: true})
          store
        else
          call = %ToolCall{
            id: "call-#{label}",
            name: "lab_marker",
            args: {:ok, %{"label" => label}}
          }

          {:ok, store} = Store.append(store, %Assistant{tool_calls: [call]})

          {:ok, store} =
            Store.append(store, %ToolResult{
              call_id: call.id,
              name: call.name,
              outcome: {:ok, "marked #{label}"}
            })

          {:ok, store} = Store.append(store, %Assistant{text: "done #{label}"})
          store
        end
      end)

    inbox =
      Enum.map(@inputs, fn label ->
        %{
          id: "accepted-#{label}",
          session_id: store.id,
          sender_id: "lab",
          kind: :normal,
          state: if(label == "A", do: :failed, else: :consumed),
          error: if(label == "A", do: "provider died", else: nil),
          user: %User{text: "input #{label}"},
          created_at: label_index(label)
        }
      end)

    {:ok, store} = Store.put_inbox(store, inbox, false)
    File.write!(Path.join(dir, "marks.txt"), "B\nC\n")
    save_and_reopen(store, dir)
  end

  defp accepted_inputs do
    Map.new(@inputs, fn label ->
      {label, %{id: "accepted-#{label}", text: "input #{label}"}}
    end)
  end

  defp witness_attrs(dir) do
    %{
      accepted: accepted_inputs(),
      cwd: dir,
      fault: :provider_started,
      probe: :ok,
      paused_inputs: nil,
      recovery_ms: 10,
      backlog_ms: 20,
      backlog_count: 2,
      backlog_settled: true,
      clocks: %{
        recovery: %{origin: "target_down", origin_at: 5, endpoint_at: 15, ms: 10},
        backlog: %{origin: "target_down", origin_at: 5, endpoint_at: 25, ms: 20}
      },
      marker_bytes: ["B", "C"]
    }
  end

  defp protocol_evidence do
    %{
      fault_seen: true,
      target_down: true,
      one_shot: true,
      hook_returned_before_down: false,
      death: %{matched: true, target: "target", reason: :killed, at: 5},
      ordering: %{
        monitor_installed_at: 1,
        arrived_at: 1,
        backlog_observed_at: 2,
        released_at: 3,
        injected_at: 4,
        target_down_at: 5,
        target: "target",
        backlog_ids: ["accepted-B", "accepted-C"]
      }
    }
  end

  defp confirmed_cleanup, do: %{confirmed: true, choices: %{}}

  defp save_and_reopen(store, dir) do
    {:ok, store} = Store.save(store)
    {:ok, store} = Store.open(store.path, dir)
    store
  end

  defp reuse_call_ids(store) do
    %{store | entries: Enum.map(store.entries, &rewrite_call_id(&1, "shared"))}
  end

  defp rewrite_call_id(%Entry{message: %Assistant{tool_calls: [_]} = message} = entry, id) do
    %{entry | message: %{message | tool_calls: Enum.map(message.tool_calls, &%{&1 | id: id})}}
  end

  defp rewrite_call_id(%Entry{message: %ToolResult{} = message} = entry, id),
    do: %{entry | message: %{message | call_id: id}}

  defp rewrite_call_id(entry, _id), do: entry

  defp wrong_inbox_user(store) do
    %{
      store
      | inbox:
          Enum.map(
            store.inbox,
            &if(&1.id == "accepted-B", do: %{&1 | user: %User{text: "WRONG"}}, else: &1)
          )
    }
  end

  defp update_receipt(store, id, fun) do
    %{store | inbox: Enum.map(store.inbox, &if(&1.id == id, do: fun.(&1), else: &1))}
  end

  defp extra_interrupted_c(store) do
    terminal_index =
      Enum.find_index(store.entries, &match?(%Entry{message: %Assistant{text: "done C"}}, &1))

    terminal = Enum.at(store.entries, terminal_index)

    extra = %Entry{
      id: "extra-interrupted-C",
      parent_id: terminal.parent_id,
      timestamp: terminal.timestamp,
      message: %Assistant{text: "stale", interrupted: true}
    }

    terminal = %{terminal | parent_id: extra.id}

    %{
      store
      | entries:
          store.entries
          |> List.replace_at(terminal_index, terminal)
          |> List.insert_at(terminal_index, extra)
    }
  end

  defp duplicate_c_terminal(store) do
    terminal =
      Enum.find(store.entries, &match?(%Entry{message: %Assistant{text: "done C"}}, &1))

    duplicate = %{
      terminal
      | id: "duplicate-terminal-C",
        parent_id: terminal.id,
        timestamp: terminal.timestamp + 1
    }

    %{store | entries: store.entries ++ [duplicate], leaf: duplicate.id}
  end

  defp stale_off_branch(store) do
    branch = %Entry{
      id: "stale-off-branch",
      parent_id: hd(store.entries).id,
      timestamp: List.last(store.entries).timestamp + 1,
      message: %Assistant{text: "stale", interrupted: true}
    }

    %{store | entries: store.entries ++ [branch]}
  end

  defp prepend_history(store, message) do
    [first | rest] = store.entries

    preamble = %Entry{
      id: "preamble",
      parent_id: nil,
      timestamp: first.timestamp - 1,
      message: message
    }

    %{store | entries: [preamble, %{first | parent_id: preamble.id} | rest]}
  end

  defp leaf_before_c(store) do
    leaf =
      store.entries
      |> Enum.find(&match?(%Entry{message: %Assistant{text: "done B"}}, &1))
      |> Map.fetch!(:id)

    %{store | leaf: leaf}
  end

  defp put_timing(witness, recovery_ms, backlog_ms) do
    witness
    |> Map.put(:recovery_ms, recovery_ms)
    |> Map.put(:backlog_ms, backlog_ms)
    |> put_in([:clocks, :recovery, :endpoint_at], 5 + recovery_ms)
    |> put_in([:clocks, :recovery, :ms], recovery_ms)
    |> put_in([:clocks, :backlog, :endpoint_at], 5 + backlog_ms)
    |> put_in([:clocks, :backlog, :ms], backlog_ms)
  end

  defp shift_clock(witness, name, origin_at) do
    ms = witness.clocks[name].ms

    witness
    |> put_in([:clocks, name, :origin_at], origin_at)
    |> put_in([:clocks, name, :endpoint_at], origin_at + ms)
  end

  defp label_index(label), do: Enum.find_index(@inputs, &(&1 == label))

  defp wait_until(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining > 0, do: Process.sleep(remaining + 1)
  end

  defp assert_eventually(predicate, attempts \\ 100)

  defp assert_eventually(predicate, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(predicate, attempts - 1)
    end
  end

  defp assert_eventually(_predicate, 0), do: flunk("condition did not become true")

  defp expected_checks(:provider) do
    %{
      known_fault: true,
      fault_witnessed: true,
      target_down_witnessed: true,
      unique_accepted_inputs: true,
      backlog_witnessed_before_release: true,
      one_shot_gate: true,
      stable_labels: true,
      exact_identities: true,
      persisted_state_read: true,
      settled_receipts: true,
      active_input_cleared: true,
      history_identity: true,
      physical_marker_counts: true,
      no_unexpected_labels: true,
      backlog_completed: true,
      responsive_probe: true,
      timing_bounded: true,
      indeterminate_without_receipt: true,
      no_input_while_paused: true,
      marker_hook_blocked_until_down: true
    }
  end

  defp deficient_witnesses do
    [
      %{
        name: "missing fault",
        check: :fault_witnessed,
        witness: witness(:provider_started, &Map.put(&1, :fault_seen, false))
      },
      %{
        name: "missing death",
        check: :target_down_witnessed,
        witness: witness(:provider_started, &Map.put(&1, :target_down, false))
      },
      %{
        name: "duplicate marker",
        check: :no_unexpected_labels,
        witness: witness(:provider_started, &Map.put(&1, :marker_labels, ["B", "B", "C"]))
      },
      %{
        name: "missing marker",
        check: :stable_labels,
        witness: witness(:provider_started, &Map.put(&1, :marker_labels, ["B"]))
      },
      %{
        name: "unexpected marker",
        check: :no_unexpected_labels,
        witness: witness(:provider_started, &Map.put(&1, :marker_labels, ["B", "C", "Z"]))
      },
      %{
        name: "wrong accepted id",
        check: :exact_identities,
        witness: witness(:provider_started, &put_in(&1.inputs["B"].accepted_id, "other"))
      },
      %{
        name: "wrong call result",
        check: :history_identity,
        witness:
          witness(:provider_started, fn witness ->
            update_in(witness.history, fn history ->
              Enum.map(history, fn
                %{"kind" => "tool_result"} = result ->
                  put_in(result["outcome"]["text"], "marked Z")

                other ->
                  other
              end)
            end)
          end)
      },
      %{
        name: "stale completion",
        check: :exact_identities,
        witness: witness(:provider_started, &put_in(&1.inputs["C"].persisted_user_id, "stale"))
      },
      %{
        name: "consumed-only receipt",
        check: :settled_receipts,
        witness:
          witness(
            :provider_started,
            &put_in(&1.inputs["B"].receipt, %{state: :consumed})
          )
      },
      %{
        name: "unresponsive probe",
        check: :responsive_probe,
        witness: witness(:provider_started, &Map.put(&1, :probe, :timeout))
      }
    ]
  end

  defp witness(fault, mutate \\ & &1) do
    ids = %{"A" => "in-A", "B" => "in-B", "C" => "in-C"}

    inputs =
      Map.new(@inputs, fn label ->
        {label,
         %{
           accepted_id: ids[label],
           persisted_user_id: "user-#{label}",
           call_id: "call-#{label}",
           label: label,
           receipt: receipt(fault, label),
           tool_outcome: tool_outcome(fault, label),
           active_cleared: true
         }}
      end)

    history =
      Enum.flat_map(@inputs, fn label ->
        call = %{"id" => "call-#{label}", "name" => "lab_marker", "args" => %{"label" => label}}

        result = result_entries(fault, label)

        prefix = [%{"id" => "user-#{label}", "kind" => "user", "text" => "input #{label}"}]

        if fault in [:provider_started, :provider_streaming] and label == "A" do
          prefix ++
            [
              %{
                "id" => "interrupted-A",
                "kind" => "assistant",
                "text" => "partial",
                "tool_calls" => [],
                "interrupted" => true
              }
            ]
        else
          prefix ++
            [
              %{
                "id" => "call-entry-#{label}",
                "kind" => "assistant",
                "text" => nil,
                "tool_calls" => [call],
                "interrupted" => fault == :tool_running and label == "A"
              }
              | result
            ]
        end
      end)

    mutate.(%{
      fault: fault,
      fault_seen: true,
      target_down: true,
      accepted_ids: Map.values(ids),
      accepted_order: ["in-A", "in-B", "in-C"],
      inputs: inputs,
      history: history,
      marker_labels: marker_labels(fault),
      marker_bytes: marker_labels(fault),
      store_read: true,
      probe: :ok,
      recovery_ms: 10,
      backlog_ms: 20,
      backlog_count: 2,
      paused_inputs: if(fault == :tool_running, do: 0, else: nil),
      hook_returned_before_down: false,
      active_input_id: nil,
      cleanup_confirmed: true,
      backlog_settled: true,
      one_shot: true,
      death: %{matched: true, reason: "killed", target: "target", at: 5},
      ordering: %{
        arrived_at: 1,
        monitor_installed_at: 1,
        backlog_observed_at: 2,
        released_at: 3,
        injected_at: 4,
        target_down_at: 5,
        target: "target",
        backlog_ids: ["in-B", "in-C"]
      },
      clocks: %{
        recovery: %{origin: "target_down", origin_at: 5, endpoint_at: 15, ms: 10},
        backlog: %{
          origin: if(fault == :tool_running, do: "explicit_resume", else: "target_down"),
          origin_at: 5,
          endpoint_at: 25,
          ms: 20
        }
      },
      cleanup: %{confirmed: true, resources: []}
    })
  end

  defp receipt(:tool_running, "A"), do: %{state: :failed, error: "session restarted"}
  defp receipt(_fault, "A"), do: %{state: :failed, error: "{:provider_error, crash}"}
  defp receipt(_fault, _label), do: %{state: :consumed, error: nil}

  defp tool_outcome(:tool_running, "A"), do: %{"kind" => "error", "text" => "interrupted"}
  defp tool_outcome(_fault, "A"), do: nil
  defp tool_outcome(_fault, label), do: %{"kind" => "ok", "text" => "marked #{label}"}

  defp result_entries(:tool_running, "A") do
    [
      %{
        "id" => "result-entry-A",
        "kind" => "tool_result",
        "call_id" => "call-A",
        "name" => "lab_marker",
        "outcome" => %{"kind" => "error", "text" => "interrupted"}
      }
    ]
  end

  defp result_entries(_fault, "A"), do: []

  defp result_entries(_fault, label) do
    [
      %{
        "id" => "result-entry-#{label}",
        "kind" => "tool_result",
        "call_id" => "call-#{label}",
        "name" => "lab_marker",
        "outcome" => %{"kind" => "ok", "text" => "marked #{label}"}
      },
      %{
        "id" => "terminal-entry-#{label}",
        "kind" => "assistant",
        "text" => "done #{label}",
        "tool_calls" => [],
        "interrupted" => false
      }
    ]
  end

  defp marker_labels(:tool_running), do: ["A", "B", "C"]
  defp marker_labels(_fault), do: ["B", "C"]

  defp update_last_terminal(witness, label, fun) do
    update_in(witness.history, fn history ->
      index =
        history
        |> Enum.with_index()
        |> Enum.filter(fn {entry, _} ->
          entry["kind"] == "assistant" and entry["tool_calls"] == [] and
            entry["text"] == "done #{label}"
        end)
        |> List.last()
        |> elem(1)

      List.update_at(history, index, fun)
    end)
  end

  defp update_call(witness, label, fun) do
    update_in(witness.history, fn history ->
      Enum.map(history, fn
        %{"kind" => "assistant", "tool_calls" => [call]} = entry ->
          if call["args"]["label"] == label,
            do: %{entry | "tool_calls" => [fun.(call)]},
            else: entry

        entry ->
          entry
      end)
    end)
  end

  defp update_result(witness, label, fun) do
    update_in(witness.history, fn history ->
      Enum.map(history, fn
        %{"kind" => "tool_result", "call_id" => "call-" <> ^label} = result -> fun.(result)
        result -> result
      end)
    end)
  end

  defp duplicate_kind(witness, label, kind, predicate) do
    update_in(witness.history, fn history ->
      entry =
        Enum.find(history, fn entry ->
          entry["kind"] == kind and predicate.(entry) and
            (entry["call_id"] == "call-#{label}" or
               get_in(entry, ["tool_calls", Access.at(0), "args", "label"]) == label)
        end)

      List.insert_at(history, Enum.find_index(history, &(&1 == entry)), entry)
    end)
  end

  defp move_kind_before_user(witness, label, kind) do
    update_in(witness.history, fn history ->
      index =
        Enum.find_index(history, fn entry ->
          entry["kind"] == kind and
            (entry["call_id"] == "call-#{label}" or
               get_in(entry, ["tool_calls", Access.at(0), "args", "label"]) == label)
        end)

      {entry, history} = List.pop_at(history, index)
      user_index = Enum.find_index(history, &(&1["id"] == "user-#{label}"))
      List.insert_at(history, user_index, entry)
    end)
  end
end
