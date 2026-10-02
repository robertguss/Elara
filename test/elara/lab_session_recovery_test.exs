defmodule Elara.Lab.SessionRecoveryTest do
  # Not async: the scenario swaps the sessions root and starts real sessions.
  use ExUnit.Case, async: false

  alias Elara.Lab.Scenarios.SessionRecovery
  alias Elara.Lab.Scenarios.SessionRecovery.Observer

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

  test "provider faults settle A failed and complete B and C; the marker path stays strict" do
    for fault <- [:provider_started, :provider_streaming] do
      result = SessionRecovery.run(context(fault))

      assert Elara.Lab.failed_checks(result) == [], inspect({fault, result.checks}, pretty: true)
      assert result.cleanup_confirmed
      assert result.recovery.accepted_ids == ["recovery-A", "recovery-B", "recovery-C"]
      assert Map.keys(result.recovery.receipts) == ["A", "B", "C"]
    end

    marker = SessionRecovery.run(context(:tool_running))

    assert Elara.Lab.failed_checks(marker) == [:indeterminate_without_receipt],
           inspect(marker.checks, pretty: true)

    assert marker.cleanup_confirmed
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
      settled_receipts: true,
      active_input_cleared: true,
      history_identity: true,
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
        witness: witness(:provider_started, &put_in(&1.inputs["C"].user_message_id, "stale"))
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
           user_message_id: ids[label],
           call_id: "call-#{label}",
           label: label,
           receipt: receipt(fault, label),
           active_cleared: true
         }}
      end)

    history =
      Enum.flat_map(@inputs, fn label ->
        call = %{"id" => "call-#{label}", "name" => "lab_marker", "args" => %{"label" => label}}

        result =
          case receipt(fault, label) do
            %{state: :failed} ->
              []

            %{state: :consumed} ->
              [
                %{
                  "kind" => "tool_result",
                  "call_id" => "call-#{label}",
                  "name" => "lab_marker",
                  "outcome" => %{"kind" => "ok", "text" => "marked #{label}"}
                },
                %{"kind" => "assistant", "text" => "done #{label}", "tool_calls" => []}
              ]
          end

        [
          %{"kind" => "user", "text" => "input #{label}"},
          %{"kind" => "assistant", "text" => nil, "tool_calls" => [call]} | result
        ]
      end)

    mutate.(%{
      fault: fault,
      fault_seen: true,
      target_down: true,
      accepted_ids: Map.values(ids),
      inputs: inputs,
      history: history,
      marker_labels: marker_labels(fault),
      marker_bytes: marker_labels(fault),
      probe: :ok,
      recovery_ms: 10,
      backlog_ms: 20,
      backlog_count: 2,
      paused_inputs: if(fault == :tool_running, do: 0, else: nil),
      hook_returned_before_down: false,
      active_input_id: nil,
      cleanup_confirmed: true,
      backlog_settled: true,
      one_shot: true
    })
  end

  defp receipt(:tool_running, "A"), do: %{state: :failed, error: "session restarted"}
  defp receipt(_fault, "A"), do: %{state: :failed, error: "{:provider_error, crash}"}
  defp receipt(_fault, _label), do: %{state: :consumed, error: nil}

  defp marker_labels(:tool_running), do: ["A", "B", "C"]
  defp marker_labels(_fault), do: ["B", "C"]
end
