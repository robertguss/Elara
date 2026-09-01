defmodule Elara.Benchmark.ScorerTest do
  use ExUnit.Case, async: true

  alias Elara.Benchmark.{Evidence, Manifest, Runner, Scorer}

  @manifest_path Path.expand("../../fixtures/benchmark/exp003/manifest.json", __DIR__)
  @v6_manifest_path Path.expand("../../fixtures/benchmark/exp003-v6/manifest.json", __DIR__)

  setup do
    {:ok, manifest} = Manifest.load(@manifest_path)

    %{
      manifest: manifest,
      fault_records: good_fault_records(manifest),
      no_fault_records: good_no_fault_records(manifest)
    }
  end

  test "applies the frozen B/T union, material threshold, convergence, and exact timing rules", %{
    manifest: manifest,
    fault_records: fault_records,
    no_fault_records: no_fault_records
  } do
    report = Scorer.score(manifest, fault_records, no_fault_records)

    assert report["valid"]
    assert report["status"] == "Pass"
    assert report["B"] == 20
    assert report["T"] == 5
    assert report["B_minus_T"] == 15
    assert report["material_improvement"]
    assert report["knowledge_and_safe_action"]["pass"]
    assert report["causal_terminal_convergence"]["pass"]
    assert report["no_fault_correctness"]["pass"]
    assert report["timing"]["pass"]

    assert report["timing"]["corpus_median_ratio"] == %{
             "numerator" => 11,
             "denominator" => 10,
             "decimal" => 1.1
           }
  end

  test "a safety disqualifier cannot be averaged away", %{
    manifest: manifest,
    fault_records: fault_records,
    no_fault_records: no_fault_records
  } do
    [first | _rest] = fault_records
    row_id = first["row_id"]
    condition = first["condition"]

    unsafe =
      Enum.map(fault_records, fn record ->
        if record["row_id"] == row_id and record["condition"] == condition do
          record
          |> Map.put("primary_recovery_class", "safety_disqualifier")
          |> Map.put("safety_disqualifiers", ["duplicate external mutation"])
        else
          record
        end
      end)

    report = Scorer.score(manifest, unsafe, no_fault_records)

    assert report["valid"]
    assert report["status"] == "Fail"
    assert "duplicate external mutation" in report["safety_disqualifiers"]
  end

  test "missing, skipped, non-comparable, and harness-failure evidence remain distinct", %{
    manifest: manifest,
    fault_records: [first | rest] = fault_records,
    no_fault_records: no_fault_records
  } do
    missing = Scorer.score(manifest, rest, no_fault_records)
    refute missing["valid"]
    assert error?(missing, "missing_fault_run")

    skipped_records =
      replace_record(fault_records, first, Map.put(first, "record_status", "skipped"))

    skipped = Scorer.score(manifest, skipped_records, no_fault_records)
    refute skipped["valid"]
    assert error?(skipped, "skipped_fault_run")

    non_comparable_record =
      first
      |> Map.put("record_status", "non_comparable")
      |> Map.put("primary_recovery_class", "non_comparable")

    non_comparable =
      Scorer.score(
        manifest,
        replace_record(fault_records, first, non_comparable_record),
        no_fault_records
      )

    refute non_comparable["valid"]
    assert error?(non_comparable, "non_comparable_fault_run")

    harness_record =
      first
      |> Map.put("record_status", "harness_failure")
      |> Map.put("primary_recovery_class", "harness_failure")
      |> Map.put("harness_errors", ["synthetic failure"])

    harness =
      Scorer.score(
        manifest,
        replace_record(fault_records, first, harness_record),
        no_fault_records
      )

    refute harness["valid"]
    assert error?(harness, "harness_failure")
  end

  test "inconsistent repetitions and missing no-fault runs invalidate the report", %{
    manifest: manifest,
    fault_records: [first | _rest] = fault_records,
    no_fault_records: [_no_fault | remaining_no_fault] = no_fault_records
  } do
    inconsistent = Map.put(first, "primary_recovery_class", "automatic_known_nonterminal")

    report =
      Scorer.score(manifest, replace_record(fault_records, first, inconsistent), no_fault_records)

    refute report["valid"]

    assert error?(report, "inconsistent_recovery_class")

    report = Scorer.score(manifest, fault_records, remaining_no_fault)
    refute report["valid"]
    assert error?(report, "missing_no_fault_run")
  end

  test "correct but too-slow evidence is Mixed rather than silently passing", %{
    manifest: manifest,
    fault_records: fault_records,
    no_fault_records: no_fault_records
  } do
    slow =
      Enum.map(no_fault_records, fn record ->
        if record["condition"] == "receipts" do
          Map.put(record, "elapsed_wall_us", 130)
        else
          record
        end
      end)

    report = Scorer.score(manifest, fault_records, slow)

    assert report["valid"]
    assert report["status"] == "Mixed"
    refute report["timing"]["pass"]
  end

  test "a consistent automatic-known-nonterminal class remains valid and is not bad recovery", %{
    manifest: manifest,
    fault_records: fault_records,
    no_fault_records: no_fault_records
  } do
    row_id = hd(fault_records)["row_id"]

    adjusted =
      Enum.map(fault_records, fn record ->
        if record["row_id"] == row_id and record["condition"] == "baseline" do
          Map.put(record, "primary_recovery_class", "automatic_known_nonterminal")
        else
          record
        end
      end)

    report = Scorer.score(manifest, adjusted, no_fault_records)

    assert report["valid"]
    assert report["status"] == "Pass"
    assert report["B"] == 19
  end

  test "schedule order drift and a zero measured timing are actionable invalid inputs", %{
    manifest: manifest,
    fault_records: [fault | _fault_rest] = fault_records,
    no_fault_records: [no_fault | _no_fault_rest] = no_fault_records
  } do
    wrong_fault_order = Map.put(fault, "order_index", 99)

    report =
      Scorer.score(
        manifest,
        replace_record(fault_records, fault, wrong_fault_order),
        no_fault_records
      )

    refute report["valid"]
    assert error?(report, "fault_order_mismatch", fn details -> List.last(details) == 99 end)

    measured = Enum.find(no_fault_records, &(&1["phase"] == "measured"))
    zero = Map.put(measured, "elapsed_wall_us", 0)

    report =
      Scorer.score(manifest, fault_records, replace_record(no_fault_records, measured, zero))

    refute report["valid"]
    assert error?(report, "zero_no_fault_timing")

    wrong_no_fault_order = Map.put(no_fault, "order_index", 99)

    report =
      Scorer.score(
        manifest,
        fault_records,
        replace_record(no_fault_records, no_fault, wrong_no_fault_order)
      )

    refute report["valid"]

    assert error?(report, "no_fault_order_mismatch", fn details -> List.last(details) == 99 end)
  end

  test "condition-specific V6 F4 terminal applicability and diagnostics are canonical JSON" do
    assert {:ok, source} = Manifest.load(@v6_manifest_path)
    assert {:ok, manifest} = Elara.Benchmark.Qualification.manifest(source)
    fault_records = good_fault_records(manifest)
    no_fault_records = good_no_fault_records(manifest)

    report = Scorer.score(manifest, fault_records, no_fault_records)

    assert report["valid"]
    assert report["status"] == "Pass"
    assert report["causal_terminal_convergence"]["applicable_repetitions"] == 9

    invalid = Scorer.score(manifest, tl(fault_records), no_fault_records)
    encoded = Elara.Benchmark.InternalConfirmatory.canonical_json(invalid)
    assert JSON.decode!(encoded) == invalid
    assert error?(invalid, "missing_fault_run")
  end

  defp good_fault_records(manifest) do
    Enum.map(Runner.fault_schedule(manifest), fn run ->
      row = manifest.rows[run["row_id"]]
      task = manifest.tasks[row["task_id"]]
      condition = run["condition"]
      expected_terminal = expected_terminal(row, condition)

      manifest
      |> Manifest.required_evidence_fields()
      |> Map.new(&{&1, nil})
      |> Map.merge(%{
        "schema" => Evidence.fault_schema(),
        "record_status" => "completed",
        "preregistration_version" => manifest.data["preregistration_version"],
        "seed_round" => manifest.data["beacon"]["round"],
        "seed_digest" => manifest.data["seed"]["sha256"],
        "corpus_manifest_digest" => manifest.sha256,
        "task_id" => task["id"],
        "row_id" => row["row_id"],
        "operation_class" => row["operation_class"],
        "scope_id" => manifest.data["scope_id"],
        "exposure_split" => task["exposure_split"],
        "fixture_commit" => task["fixture"]["fixture_commit"],
        "initial_workspace_digest" => task["fixture"]["initial_workspace_sha256"],
        "initial_reset_verified" => true,
        "condition" => condition,
        "run_index" => run["run_index"],
        "order_index" => run["order_index"],
        "fault_type" => row["fault_type"],
        "barrier_id" => row["barrier_id"],
        "killed_owner" => row["crash_target"],
        "delivered_messages" => row["delivered_messages"],
        "dropped_messages" => row["dropped_messages"],
        "surviving_storage" => row["surviving_storage"],
        "restart_order" => row["restart_order"],
        "observation_deadline_ms" => row["observation_deadline_ms"],
        "expected_workspace_digest" => task["fixture"]["expected_no_fault_workspace_sha256"],
        "safe_next_action_expected" => row["expected_safe_action"][condition],
        "safe_next_action_observed" => row["expected_safe_action"][condition],
        "knowledge_convergence_ms" => 10,
        "causal_terminal_evidence_expected" => expected_terminal,
        "causal_terminal_evidence_observed" => expected_terminal,
        "terminal_convergence_ms" => if(expected_terminal, do: 10, else: nil),
        "admission_count" => 1,
        "callback_attempt_count" => 1,
        "external_mutation_count" => 1,
        "session_result_count" => 1,
        "unplanned_intervention_count" => 0,
        "primary_recovery_class" => row["expected_primary_recovery_class"][condition],
        "safety_disqualifiers" => [],
        "harness_errors" => [],
        "elapsed_ms" => 10,
        "cpu_ms" => 1,
        "storage_bytes" => 100,
        "model_call_count" => 0,
        "tool_call_count" => 1
      })
    end)
  end

  defp good_no_fault_records(manifest) do
    Enum.map(Runner.no_fault_schedule(manifest), fn run ->
      task = manifest.tasks[run["task_id"]]

      expected_outcome =
        task["plan"]["steps"] |> List.last() |> Map.fetch!("expected_no_fault_outcome")

      %{
        "schema" => Evidence.no_fault_schema(),
        "task_id" => run["task_id"],
        "condition" => run["condition"],
        "phase" => run["phase"],
        "run_index" => run["run_index"],
        "order_index" => run["order_index"],
        "fixture_commit" => task["fixture"]["fixture_commit"],
        "initial_workspace_sha256" => task["fixture"]["initial_workspace_sha256"],
        "expected_workspace_sha256" => task["fixture"]["expected_no_fault_workspace_sha256"],
        "final_workspace_sha256" => task["fixture"]["expected_no_fault_workspace_sha256"],
        "observed_outcome" => expected_outcome,
        "expected_outcome" => expected_outcome,
        "workspace_correct" => true,
        "outcome_correct" => true,
        "elapsed_wall_us" => if(run["condition"] == "baseline", do: 100, else: 110),
        "cpu_time_us" => 10,
        "storage_bytes" => 100
      }
    end)
  end

  defp replace_record(records, original, replacement) do
    Enum.map(records, fn record -> if record == original, do: replacement, else: record end)
  end

  defp expected_terminal(row, condition) do
    case row["causal_terminal_evidence_expected_to_survive"] do
      expectations when is_map(expectations) -> Map.fetch!(expectations, condition)
      expectation -> expectation
    end
  end

  defp error?(report, code, predicate \\ fn _details -> true end) do
    Enum.any?(report["errors"], fn
      %{"code" => ^code, "details" => details} -> predicate.(details)
      _other -> false
    end)
  end
end
