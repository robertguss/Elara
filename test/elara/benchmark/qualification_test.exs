defmodule Elara.Benchmark.QualificationTest do
  use ExUnit.Case, async: true

  alias Elara.Benchmark.{Manifest, Qualification, Runner}

  @manifest_path Path.expand("../../fixtures/benchmark/exp003-v3/manifest.json", __DIR__)
  @report_path Path.expand(
                 "../../fixtures/benchmark/exp003-v3/internal-adapter-qualification.json",
                 __DIR__
               )

  test "derives only the complete compatible development qualification matrix" do
    {:ok, source} = Manifest.load(@manifest_path)
    assert {:ok, qualification} = Qualification.manifest(source)

    assert qualification.data["schema"] == Qualification.schema()
    assert map_size(qualification.tasks) == 3
    assert map_size(qualification.rows) == 12
    assert length(Runner.fault_schedule(qualification)) == 72

    assert Enum.all?(
             qualification.tasks,
             fn {_id, task} -> task["exposure_split"] == "development_adapter_fixture" end
           )

    assert qualification.rows
           |> Map.values()
           |> Enum.map(&{&1["operation_class"], &1["fault_type"]})
           |> MapSet.new() ==
             MapSet.new([
               {"patch", "F1"},
               {"patch", "F2"},
               {"patch", "F3"},
               {"patch", "F4"},
               {"shell", "F1"},
               {"shell", "F2"},
               {"shell", "F3"},
               {"shell", "F4"},
               {"write", "F1"},
               {"write", "F2"},
               {"write", "F3"},
               {"write", "F4"}
             ])
  end

  test "freezes the qualified adapter and runner identities with zero confirmatory exposure" do
    report = @report_path |> File.read!() |> JSON.decode!()
    repo_root = Path.expand("../../..", __DIR__)

    assert report["fault_qualification"]["run_count"] == 72
    assert report["fault_qualification"]["row_count"] == 12
    assert report["no_fault"]["all_equivalent"]
    assert report["exposure"]["v3_confirmatory_fault_runs"] == 0
    refute report["exposure"]["B_or_T_calculated"]

    for {field, relative} <- [
          {"sha256", "lib/elara/benchmark/elara_adapter.ex"},
          {"target_runner_sha256", "priv/benchmark/elara_target_runner.exs"},
          {"neutral_runner_sha256", "lib/elara/benchmark/runner.ex"}
        ] do
      actual =
        repo_root
        |> Path.join(relative)
        |> File.read!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      assert report["adapter"][field] == actual
    end
  end
end
