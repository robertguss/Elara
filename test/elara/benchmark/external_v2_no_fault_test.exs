defmodule Elara.Benchmark.ExternalV2NoFaultTest do
  use ExUnit.Case, async: false

  alias Elara.Benchmark.{ExternalAdapterV2, Manifest}

  @manifest_path Path.expand("../../fixtures/benchmark/exp003-v2/manifest.json", __DIR__)
  @report_path Path.expand(
                 "../../fixtures/benchmark/exp003-v2/external-adapter-equivalence.json",
                 __DIR__
               )

  setup_all do
    {:ok, manifest} = Manifest.load(@manifest_path)
    report = @report_path |> File.read!() |> JSON.decode!()
    %{manifest: manifest, report: report}
  end

  test "the v2 attestation is version-aligned, complete, and fault-unexposed", %{
    manifest: manifest,
    report: report
  } do
    assert report["schema"] == "elara.exp003.external-adapter-equivalence.v2"
    assert report["preregistration_version"] == "ER-3/FND-2-v2"
    assert report["manifest_sha256"] == manifest.sha256
    assert report["comparator"]["commit"] == ExternalAdapterV2.comparator_commit()
    assert report["adapter"]["sha256"] == file_sha256(report["adapter"]["source"])

    assert report["version_adapter"]["sha256"] ==
             file_sha256(report["version_adapter"]["source"])

    assert report["version_adapter"]["base_adapter_source"] == report["adapter"]["source"]
    assert report["version_adapter"]["base_adapter_sha256"] == report["adapter"]["sha256"]

    assert report["adapter"]["target_runner_sha256"] ==
             file_sha256(report["adapter"]["target_runner_source"])

    assert report["adapter"]["neutral_runner_sha256"] ==
             "3b3ab321dcd0540bc1a8532be834021c8d3f471b7c87951a5626a6663f084a71"

    assert report["summary"] == %{
             "fixture_count" => 3,
             "included_operation_classes" => ~w(write patch shell),
             "equivalent" => 3,
             "non_equivalent" => 0,
             "adapter_failure" => 0
           }

    assert Enum.all?(report["tasks"], &(&1["classification"] == "equivalent"))
    assert Enum.all?(report["tasks"], &(&1["observed_outcome"] == &1["expected_outcome"]))

    assert Enum.map(report["fault_comparability"], & &1["row_id"]) ==
             Enum.map(manifest.data["fault_rows"], & &1["row_id"])

    assert length(report["fault_comparability"]) == 20
    assert Enum.all?(report["fault_comparability"], &(&1["classification"] == "non_comparable"))
    assert Enum.all?(report["fault_comparability"], &(&1["adapter_failure"] == false))
    assert Enum.all?(report["fault_comparability"], &(&1["source_refs"] != []))

    assert report["comparability_floor"]["observed_equivalent_fault_rows"] == 0
    assert report["comparability_floor"]["observed_equivalent_fault_types"] == []
    assert report["comparability_floor"]["status"] == "below_floor"

    assert report["comparability_floor"]["required_later_outcome"] ==
             "Insufficient comparability"

    assert report["exposure"]["lemon_fault_rows_executed"] == 0
    assert report["exposure"]["target_fault_rows_executed"] == 0
    refute report["exposure"]["B_or_T_calculated"]
  end

  @tag :external_lemon
  @tag timeout: 180_000
  test "the pinned Lemon checkout regenerates the frozen v2 attestation byte for byte", %{
    manifest: manifest,
    report: frozen
  } do
    case System.get_env("LEMON_SOURCE_ROOT") do
      lemon_root when is_binary(lemon_root) and lemon_root != "" ->
        root = temporary_root()

        assert {:ok, config} =
                 ExternalAdapterV2.prepare(File.cwd!(), Path.join(root, "state"), lemon_root)

        assert {:ok, report} =
                 ExternalAdapterV2.prove_no_fault(manifest, config, Path.join(root, "workspace"))

        assert report == frozen

      _other ->
        assert frozen["comparator"]["commit"] == ExternalAdapterV2.comparator_commit()
    end
  end

  defp temporary_root do
    root =
      Path.join(
        System.tmp_dir!(),
        "elara-external-v2-equivalence-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp file_sha256(relative_path) do
    relative_path
    |> Path.expand(File.cwd!())
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
