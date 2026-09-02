defmodule Elara.Benchmark.PreflightV8Test do
  use ExUnit.Case, async: true

  alias Elara.Benchmark.InternalConfirmatory

  @root Path.expand("../../..", __DIR__)
  @report_path Path.join(
                 @root,
                 "docs/experiments/003-effect-receipt-v8-pre-beacon-qualification.json"
               )
  @report_sha256 "ce31ac3a940fca7e14c1722c4a4a4c3c8e9813cc78fba856d59e3f920bfb309f"

  setup_all do
    bytes = File.read!(@report_path)
    %{bytes: bytes, report: JSON.decode!(bytes)}
  end

  test "freezes the exact pre-beacon materialization and command-stack result", %{report: report} do
    assert report["schema"] == "elara.exp003.pre-beacon-qualification.v8"
    assert report["preregistration_version"] == "ER-3/FND-2-v8-development"

    assert report["summary"] == %{
             "byte_identical_materializations" => true,
             "candidate_construction_count" => 20,
             "candidate_source_count" => 20,
             "eligible_candidate_count" => 17,
             "materialization_count" => 2,
             "qualification_checkpoint_event_count" => 288,
             "qualification_fault_run_count" => 72,
             "qualification_no_fault_run_count" => 72,
             "qualification_status" => "Pass",
             "replay_status" => "Pass",
             "selected_row_count" => 20,
             "selected_task_count" => 12
           }

    assert report["command_stack"]["score"] == %{
             "errors" => [],
             "safety_disqualifiers" => [],
             "schema" => "elara.exp003.score.v1",
             "status" => "Pass",
             "valid" => true
           }

    assert report["command_stack"]["replay"] == report["command_stack"]["score"]
    assert report["command_stack"]["all_no_fault_correct"]
    assert report["command_stack"]["harness_error_count"] == 0
    assert report["command_stack"]["safety_disqualifier_count"] == 0

    assert report["command_stack"]["exact_cli_entrypoints_exercised"] == [
             "mix run priv/benchmark/preflight_exp003_v8.exs",
             "mix run priv/benchmark/materialize_exp003_v8.exs",
             "mix run priv/benchmark/run_exp003_v8.exs -- qualify",
             "mix run priv/benchmark/run_exp003_v8.exs -- replay"
           ]

    assert report["command_stack"]["authorization_probe"] == %{
             "correct_manifest_digest_accepted" => true,
             "exact_task_and_row_binding_accepted" => true,
             "fault_execution_attempted" => false,
             "held_out_data_used" => false,
             "wrong_manifest_digest_rejected" => true,
             "wrong_row_rejected" => true,
             "wrong_task_rejected" => true
           }
  end

  test "records complete candidate proofs before the frozen selection", %{report: report} do
    materialization = report["materialization"]
    proofs = materialization["candidate_construction_proofs"]

    assert length(proofs) == 20
    assert Enum.all?(proofs, & &1["validated_before_selection"])
    assert length(materialization["eligible_candidate_ids"]) == 17
    assert length(materialization["selected_task_ids"]) == 12
    assert length(materialization["secondary_row_task_ids"]) == 8
    assert length(materialization["selected_development_rows"]) == 20
    assert Map.keys(materialization["output_sha256"]) |> length() == 4

    for proof <- proofs do
      assert proof["fixture_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
      assert proof["mapping_sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    end
  end

  test "preserves zero future-beacon, held-out, confirmatory, comparator, and dogfood exposure",
       %{
         report: report
       } do
    assert report["exposure"] == %{
             "statement" => "fixed non-confirmatory development entropy only",
             "v8_B_or_T_calculated" => false,
             "v8_dogfood_runs" => 0,
             "v8_external_fault_runs" => 0,
             "v8_future_beacon_committed" => false,
             "v8_future_beacon_fetched" => false,
             "v8_held_out_literals_generated" => false,
             "v8_held_out_selection_performed" => false,
             "v8_target_fault_runs" => 0,
             "v8_target_timing_runs" => 0
           }
  end

  test "the report is canonical, byte-stable, and bound to every source identity", context do
    %{bytes: bytes, report: report} = context

    assert sha256(bytes) == @report_sha256
    assert InternalConfirmatory.canonical_json(report) == bytes
    refute bytes =~ System.tmp_dir!()

    assert file_sha256(get_in(report, ["inputs", "protocol_path"])) ==
             get_in(report, ["inputs", "protocol_sha256"])

    assert file_sha256(get_in(report, ["inputs", "development_beacon_path"])) ==
             get_in(report, ["inputs", "development_beacon_sha256"])

    for {name, identity} <- get_in(report, ["inputs", "semantics"]) do
      assert file_sha256(identity["path"]) == identity["sha256"], name
      assert read_json(identity["path"])["schema"] == identity["schema"], name
    end

    for {path, expected} <- report["source_identities"] do
      assert file_sha256(path) == expected, path
    end
  end

  defp read_json(path), do: @root |> Path.join(path) |> File.read!() |> JSON.decode!()
  defp file_sha256(path), do: @root |> Path.join(path) |> File.read!() |> sha256()
  defp sha256(value), do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
