defmodule Elara.Benchmark.RunnerTest do
  use ExUnit.Case, async: true

  alias Elara.Benchmark.{Fixture, Manifest, Runner}

  @manifest_path Path.expand("../../fixtures/benchmark/exp003/manifest.json", __DIR__)
  @v6_manifest_path Path.expand("../../fixtures/benchmark/exp003-v6/manifest.json", __DIR__)

  defmodule GoodFaultAdapter do
    @behaviour Elara.Benchmark.Adapter

    @impl true
    def execute(task, cwd, %{kind: :fault, row: row, condition: condition, fault_hook: hook}) do
      assert_injection!(hook.(row["barrier_id"], %{"durable_fact" => "synthetic"}), row)
      {:ok, _digest} = Fixture.reset(task, cwd, :expected_no_fault)

      expected_terminal = expected_terminal(row, condition)

      {:ok,
       %{
         "controller_facts" => %{"synthetic" => true},
         "executor_facts" => %{"synthetic" => true},
         "workspace_observations" => row["expected_workspace_observation"],
         "last_durable_fact" => row["last_durable_fact"][condition],
         "causal_terminal_evidence_observed" => expected_terminal,
         "historical_execution_knowledge" => row["historical_execution_knowledge"],
         "session_classification" => "synthetic",
         "safe_next_action_expected" => row["expected_safe_action"][condition],
         "safe_next_action_observed" => row["expected_safe_action"][condition],
         "knowledge_convergence_ms" => 10,
         "terminal_convergence_ms" => if(expected_terminal, do: 10, else: nil),
         "admission_count" => 1,
         "callback_attempt_count" => 1,
         "external_mutation_count" => 1,
         "session_result_count" => 1,
         "unplanned_intervention_count" => 0,
         "primary_recovery_class" => row["expected_primary_recovery_class"][condition],
         "safety_disqualifiers" => [],
         "harness_errors" => [],
         "model_call_count" => 0,
         "tool_call_count" => 1
       }}
    end

    defp assert_injection!({:inject, owner}, %{"crash_target" => owner}), do: :ok

    defp expected_terminal(row, condition) do
      case row["causal_terminal_evidence_expected_to_survive"] do
        expectations when is_map(expectations) -> Map.fetch!(expectations, condition)
        expectation -> expectation
      end
    end
  end

  defmodule MissingHookAdapter do
    @behaviour Elara.Benchmark.Adapter

    @impl true
    def execute(_task, _cwd, %{kind: :fault}), do: {:ok, %{}}
  end

  defmodule InvalidEvidenceAdapter do
    @behaviour Elara.Benchmark.Adapter

    @impl true
    def execute(_task, _cwd, %{kind: :fault, row: row, fault_hook: hook}) do
      {:inject, _owner} = hook.(row["barrier_id"], %{})
      {:ok, %{}}
    end
  end

  setup do
    {:ok, manifest} = Manifest.load(@manifest_path)

    root =
      Path.join(System.tmp_dir!(), "elara-runner-test-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    %{manifest: manifest, root: root}
  end

  test "materializes the exact frozen fault and no-fault schedules", %{manifest: manifest} do
    fault = Runner.fault_schedule(manifest)
    no_fault = Runner.no_fault_schedule(manifest)

    assert length(fault) == 120
    assert length(no_fault) == 288

    assert Enum.take(fault, 6) == [
             %{
               "row_id" => "S03-F3",
               "condition" => "baseline",
               "run_index" => 1,
               "order_index" => 1
             },
             %{
               "row_id" => "S03-F3",
               "condition" => "receipts",
               "run_index" => 1,
               "order_index" => 2
             },
             %{
               "row_id" => "S03-F3",
               "condition" => "receipts",
               "run_index" => 2,
               "order_index" => 3
             },
             %{
               "row_id" => "S03-F3",
               "condition" => "baseline",
               "run_index" => 2,
               "order_index" => 4
             },
             %{
               "row_id" => "S03-F3",
               "condition" => "baseline",
               "run_index" => 3,
               "order_index" => 5
             },
             %{
               "row_id" => "S03-F3",
               "condition" => "receipts",
               "run_index" => 3,
               "order_index" => 6
             }
           ]

    assert Enum.frequencies_by(no_fault, &{&1["phase"], &1["condition"]}) == %{
             {"warmup", "baseline"} => 24,
             {"warmup", "receipts"} => 24,
             {"measured", "baseline"} => 120,
             {"measured", "receipts"} => 120
           }
  end

  test "runs through the neutral adapter and captures immutable metadata", %{
    manifest: manifest,
    root: root
  } do
    run = hd(Runner.fault_schedule(manifest))

    assert {:ok, record} =
             Runner.run_fault(manifest, run,
               adapter: GoodFaultAdapter,
               root: root,
               target_commit: "synthetic-target",
               adapter_digest: "synthetic-adapter"
             )

    assert record["schema"] == "elara.exp003.fault-evidence.v1"
    assert record["row_id"] == "S03-F3"
    assert record["condition"] == "baseline"
    assert record["target_commit"] == "synthetic-target"
    assert record["initial_reset_verified"]
    assert record["final_workspace_digest"] == record["expected_workspace_digest"]
    assert record["fault_hook_facts"] == %{"durable_fact" => "synthetic"}
  end

  test "emits the condition-specific V6 causal-terminal expectation", %{root: root} do
    assert {:ok, source} = Manifest.load(@v6_manifest_path)
    assert {:ok, manifest} = Elara.Benchmark.Qualification.manifest(source)

    for {condition, expected} <- [{"baseline", false}, {"receipts", true}] do
      run = %{
        "row_id" => "QUAL-W01-F4",
        "condition" => condition,
        "run_index" => 1,
        "order_index" => if(condition == "baseline", do: 1, else: 2)
      }

      assert {:ok, record} =
               Runner.run_fault(manifest, run,
                 adapter: GoodFaultAdapter,
                 root: root,
                 target_commit: "synthetic-target",
                 adapter_digest: "synthetic-adapter"
               )

      assert record["causal_terminal_evidence_expected"] == expected
    end
  end

  test "a missing fault barrier is a harness failure", %{manifest: manifest, root: root} do
    run = hd(Runner.fault_schedule(manifest))

    assert {:error, {:harness_failure, {:fault_hook, :not_reached}}} =
             Runner.run_fault(manifest, run,
               adapter: MissingHookAdapter,
               root: root,
               target_commit: "synthetic-target",
               adapter_digest: "synthetic-adapter"
             )
  end

  test "incomplete adapter evidence is rejected as a harness failure", %{
    manifest: manifest,
    root: root
  } do
    run = hd(Runner.fault_schedule(manifest))

    assert {:error, {:harness_failure, {:invalid_fault_evidence, errors}}} =
             Runner.run_fault(manifest, run,
               adapter: InvalidEvidenceAdapter,
               root: root,
               target_commit: "synthetic-target",
               adapter_digest: "synthetic-adapter"
             )

    assert {:missing_field, "controller_facts"} in errors
    assert {:missing_field, "primary_recovery_class"} in errors
  end
end
