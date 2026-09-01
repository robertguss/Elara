defmodule Elara.Benchmark.ManifestTest do
  use ExUnit.Case, async: true

  alias Elara.Benchmark.Manifest

  @manifest_path Path.expand("../../fixtures/benchmark/exp003/manifest.json", __DIR__)
  @manifest_sha256 "a40fa18d3ea00eee5c6b8963055cff49ca7f94388f42325c793e0460be98a5b7"

  test "loads the immutable manifest and verifies its expected digest" do
    assert {:ok, manifest} = Manifest.load(@manifest_path, sha256: @manifest_sha256)

    assert manifest.sha256 == @manifest_sha256
    assert map_size(manifest.tasks) == 12
    assert map_size(manifest.rows) == 20
    assert {:ok, %{"id" => "S03"}} = Manifest.task(manifest, "S03")
    assert {:ok, %{"row_id" => "S03-F3"}} = Manifest.row(manifest, "S03-F3")
    assert {:error, :unknown_task} = Manifest.task(manifest, "missing")
    assert {:error, :unknown_row} = Manifest.row(manifest, "missing")
  end

  test "rejects a manifest whose immutable digest does not match" do
    assert {:error, [{:manifest_digest_mismatch, "wrong", @manifest_sha256}]} =
             Manifest.load(@manifest_path, sha256: "wrong")
  end

  test "reports malformed and internally inconsistent manifests without crashing" do
    root = temporary_fixture_copy()
    manifest_path = Path.join(root, "manifest.json")

    File.write!(manifest_path, "[]")
    assert {:error, [:manifest_not_an_object]} = Manifest.load(manifest_path)

    data = @manifest_path |> File.read!() |> JSON.decode!()
    [first | rest] = data["tasks"]

    malformed =
      data
      |> Map.put("tasks", [42, first | rest])
      |> put_in(["selection", "task_count"], 13)
      |> put_in(["selection", "selected_task_ids"], [nil | data["selection"]["selected_task_ids"]])

    File.write!(manifest_path, JSON.encode!(malformed))

    assert {:error, reasons} = Manifest.load(manifest_path)
    assert {:invalid_task_fixture, nil} in reasons
  end

  test "rejects fixture and beacon artifacts that no longer match their frozen digests" do
    root = temporary_fixture_copy()
    manifest_path = Path.join(root, "manifest.json")
    data = manifest_path |> File.read!() |> JSON.decode!()

    updated =
      update_in(
        data,
        ["tasks", Access.at(0), "fixture", "initial_files", Access.at(0), "content"],
        &(&1 <> "corruption")
      )

    File.write!(manifest_path, JSON.encode!(updated))

    assert {:error, reasons} = Manifest.load(manifest_path)
    assert {:initial_fixture_digest_mismatch, "S03"} in reasons
    assert {:fixture_content_digest_mismatch, "S03"} in reasons

    File.cp!(@manifest_path, manifest_path)
    File.write!(Path.join(root, "beacon/api.drand.sh.json"), "corruption")

    assert {:error, reasons} = Manifest.load(manifest_path)

    assert Enum.any?(reasons, fn
             {:beacon_artifact_mismatch, "api.drand.sh.json", _actual} -> true
             _other -> false
           end)
  end

  test "validates the unscored adapter fixtures as immutable inputs" do
    root = temporary_fixture_copy()
    manifest_path = Path.join(root, "manifest.json")
    data = manifest_path |> File.read!() |> JSON.decode!()

    corrupted =
      update_in(
        data,
        [
          "adapter_equivalence_fixtures",
          Access.at(0),
          "fixture",
          "expected_no_fault_files",
          Access.at(0),
          "content"
        ],
        &(&1 <> "corruption")
      )

    File.write!(manifest_path, JSON.encode!(corrupted))

    assert {:error, reasons} = Manifest.load(manifest_path)
    assert {:expected_fixture_digest_mismatch, "W01"} in reasons
    assert {:fixture_content_digest_mismatch, "W01"} in reasons
  end

  defp temporary_fixture_copy do
    root =
      Path.join(System.tmp_dir!(), "elara-manifest-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.cp!(@manifest_path, Path.join(root, "manifest.json"))
    File.cp_r!(Path.join(Path.dirname(@manifest_path), "beacon"), Path.join(root, "beacon"))
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
