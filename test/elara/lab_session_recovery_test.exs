defmodule Elara.Lab.SessionRecoveryTest do
  # Not async: the scenario swaps the sessions root and starts real sessions.
  use ExUnit.Case, async: false

  alias Elara.Lab.Scenarios.SessionRecovery
  alias Elara.Lab.Scenarios.SessionRecovery.{Coordinator, Deadline, Observer, StoreView}

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

    for operation <- [:probe, :start, :reopen, :stop, :status, :snapshot] do
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

  test "missing persisted state fails closed", %{dir: dir} do
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

    assert Elara.Lab.failed_checks(marker) == [:indeterminate_without_receipt],
           inspect(marker.checks, pretty: true)

    assert marker.cleanup_confirmed
    assert marker.complete
    assert marker.checks.marker_hook_blocked_until_down
    assert marker.checks.no_input_while_paused
    assert is_integer(marker.recovery_ms)
    assert is_integer(marker.backlog_ms)

    # Ordinary direct-marker reopen is predicted to insert interrupted rather
    # than leave the started mutation indeterminate. That is a finding.
    assert marker.checks.indeterminate_without_receipt == false
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
      death: %{matched: true, reason: "killed", target: "target"},
      ordering: %{
        arrived_at: 1,
        monitor_installed_at: 1,
        backlog_observed_at: 2,
        released_at: 3,
        injected_at: 4,
        target_down_at: 5,
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
