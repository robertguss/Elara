defmodule Elara.Benchmark.ExternalAdapterTest do
  use ExUnit.Case, async: true

  alias Elara.Benchmark.{ExternalAdapter, Manifest}

  @manifest_path Path.expand("../../fixtures/benchmark/exp003/manifest.json", __DIR__)

  setup do
    {:ok, manifest} = Manifest.load(@manifest_path)
    %{manifest: manifest}
  end

  test "maps all frozen external fixtures explicitly onto native Lemon builtins", %{
    manifest: manifest
  } do
    mappings =
      Map.new(~w(adapter-w01 adapter-p01 adapter-s02), fn id ->
        {:ok, task} = Manifest.adapter_fixture(manifest, id)
        {:ok, mapping} = ExternalAdapter.mapping(task)
        {id, mapping}
      end)

    assert mappings["adapter-w01"]["tool_name"] == "write"
    assert mappings["adapter-w01"]["tool_arguments"]["format"] == false
    assert mappings["adapter-w01"]["tool_arguments"]["diagnostics"] == false

    assert mappings["adapter-p01"]["tool_name"] == "edit"
    assert mappings["adapter-p01"]["execution_constraints"]["match"] == "exact_unique"
    assert mappings["adapter-p01"]["execution_constraints"]["fuzzy_fallback_used"] == false

    assert mappings["adapter-s02"]["tool_name"] == "bash"
    assert mappings["adapter-s02"]["tool_arguments"]["pty"] == false
    assert mappings["adapter-s02"]["execution_constraints"]["timeout_ms"] == 5_000
    assert mappings["adapter-s02"]["execution_constraints"]["stderr"] == "merged"
  end

  test "pins Lemon and forbids all fault execution" do
    assert ExternalAdapter.comparator_commit() ==
             "b9ed0660e0d7fe61f38156f0aeb65e839b4e7f39"

    assert {:error, :fault_execution_forbidden} =
             ExternalAdapter.execute(%{}, "/tmp/not-used", %{kind: :fault})
  end

  test "committed artifact freezes checksums and all rows before fault exposure", %{
    manifest: manifest
  } do
    report = frozen_report()

    assert report["manifest_sha256"] == manifest.sha256
    assert report["comparator"]["commit"] == ExternalAdapter.comparator_commit()
    assert report["adapter"]["sha256"] == file_sha256(report["adapter"]["source"])

    assert report["adapter"]["target_runner_sha256"] ==
             file_sha256(report["adapter"]["target_runner_source"])

    assert report["adapter"]["neutral_runner_sha256"] ==
             "3b3ab321dcd0540bc1a8532be834021c8d3f471b7c87951a5626a6663f084a71"

    assert length(report["fault_comparability"]) == 20
    assert Enum.all?(report["fault_comparability"], &(&1["classification"] == "non_comparable"))
    assert Enum.all?(report["fault_comparability"], &(&1["adapter_failure"] == false))
    assert length(Enum.uniq_by(report["fault_comparability"], & &1["row_id"])) == 20
    assert Enum.all?(report["fault_comparability"], &(&1["source_refs"] != []))

    assert report["comparability_floor"]["observed_equivalent_fault_rows"] == 0
    assert report["comparability_floor"]["observed_equivalent_fault_types"] == []
    assert report["comparability_floor"]["status"] == "below_floor"
    assert report["comparability_floor"]["required_later_outcome"] == "Insufficient comparability"
    assert report["exposure"]["lemon_fault_rows_executed"] == 0
    assert report["exposure"]["target_fault_rows_executed"] == 0
  end

  defp frozen_report do
    path =
      Path.expand("../../fixtures/benchmark/exp003/external-adapter-equivalence.json", __DIR__)

    path |> File.read!() |> JSON.decode!()
  end

  defp file_sha256(relative_path) do
    relative_path
    |> Path.expand(File.cwd!())
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
