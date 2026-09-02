defmodule Elara.Benchmark.NoFaultEquivalenceTest do
  use ExUnit.Case, async: false

  alias Elara.Benchmark.{ElaraAdapter, Manifest}

  @manifest_path Path.expand("../../fixtures/benchmark/exp003/manifest.json", __DIR__)
  @report_path Path.expand(
                 "../../fixtures/benchmark/exp003/internal-adapter-equivalence.json",
                 __DIR__
               )
  @historical_adapter_sha256 "a49d4c91749a07c5fa8d511931928b69e64d1366d91fcdd27e6370abd235244b"
  @current_adapter_sha256 "6b712b2865e4cd3d10fbd3362e8ecc68aa7293cb3c8154c90c1074cfc00a395a"
  @historical_runner_sha256 "3b3ab321dcd0540bc1a8532be834021c8d3f471b7c87951a5626a6663f084a71"
  @current_runner_sha256 "87ee7cb29ea9d0c2a4a7381bc7fcbb13cbc63226b09573907db0ac5862b533dc"
  @historical_target_runner_sha256 "8a540e25ccbea30ddde27f3babf096ad2e5cb7425f34c9883669411dee5215a7"
  @current_target_runner_sha256 "61acaf06d8f0157be11d13cee858c6213f90a612a8f8106417ccbce27ebcaae2"

  @tag timeout: 180_000
  test "both pinned targets are no-fault equivalent on all selected tasks" do
    root = temporary_root()
    {:ok, manifest} = Manifest.load(@manifest_path)
    {:ok, config} = ElaraAdapter.prepare(File.cwd!(), Path.join(root, "state"))

    assert {:ok, report} =
             ElaraAdapter.prove_no_fault(manifest, config, Path.join(root, "workspace"))

    historical_report = @report_path |> File.read!() |> JSON.decode!()

    assert report["adapter"]["sha256"] == @current_adapter_sha256
    assert report["adapter"]["neutral_runner_sha256"] == @current_runner_sha256
    assert report["adapter"]["target_runner_sha256"] == @current_target_runner_sha256
    assert historical_report["adapter"]["sha256"] == @historical_adapter_sha256
    assert historical_report["adapter"]["neutral_runner_sha256"] == @historical_runner_sha256

    assert historical_report["adapter"]["target_runner_sha256"] ==
             @historical_target_runner_sha256

    assert semantic_projection(report) == semantic_projection(historical_report)

    assert report["summary"] == %{
             "adapter_failure" => 0,
             "equivalent" => 12,
             "non_equivalent" => 0,
             "task_count" => 12
           }

    assert report["internal_paired_denominator"]["status"] == "eligible"
    assert report["internal_paired_denominator"]["row_count"] == 20
    assert report["exposure"]["fault_rows_executed"] == 0

    for task <- report["tasks"] do
      assert task["classification"] == "equivalent"

      for condition <- ~w(baseline receipts) do
        evidence = task[condition]
        assert evidence["workspace_correct"]
        assert evidence["outcome_correct"]
        assert evidence["provider_plan_consumed"]

        assert evidence["transcript_shape"] ==
                 ~w(user assistant_tool_call tool_result assistant_text)
      end
    end
  end

  defp semantic_projection(report) do
    %{
      "manifest_sha256" => report["manifest_sha256"],
      "summary" => report["summary"],
      "internal_paired_denominator" => report["internal_paired_denominator"],
      "targets" => report["targets"],
      "tasks" =>
        Enum.map(report["tasks"], fn task ->
          %{
            "task_id" => task["task_id"],
            "operation_class" => task["operation_class"],
            "expected_outcome" => task["expected_outcome"],
            "expected_workspace_sha256" => task["expected_workspace_sha256"],
            "classification" => task["classification"],
            "baseline" => condition_projection(task["baseline"]),
            "receipts" => condition_projection(task["receipts"])
          }
        end)
    }
  end

  defp condition_projection(condition) do
    Map.take(
      condition,
      ~w(target_commit initial_workspace_sha256 final_workspace_sha256 observed_outcome workspace_correct outcome_correct provider_plan_consumed provider_call_count tool_call_count session_result_count session_result session_idle transcript_shape hooks_observed)
    )
  end

  defp temporary_root do
    root =
      Path.join(
        System.tmp_dir!(),
        "elara-internal-equivalence-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
