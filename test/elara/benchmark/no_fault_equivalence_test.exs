defmodule Elara.Benchmark.NoFaultEquivalenceTest do
  use ExUnit.Case, async: false

  alias Elara.Benchmark.{ElaraAdapter, Manifest}

  @manifest_path Path.expand("../../fixtures/benchmark/exp003/manifest.json", __DIR__)
  @report_path Path.expand(
                 "../../fixtures/benchmark/exp003/internal-adapter-equivalence.json",
                 __DIR__
               )

  @tag timeout: 180_000
  test "both pinned targets are no-fault equivalent on all selected tasks" do
    root = temporary_root()
    {:ok, manifest} = Manifest.load(@manifest_path)
    {:ok, config} = ElaraAdapter.prepare(File.cwd!(), Path.join(root, "state"))

    assert {:ok, report} =
             ElaraAdapter.prove_no_fault(manifest, config, Path.join(root, "workspace"))

    assert report == @report_path |> File.read!() |> JSON.decode!()

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
