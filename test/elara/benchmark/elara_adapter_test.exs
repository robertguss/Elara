defmodule Elara.Benchmark.ElaraAdapterTest do
  use ExUnit.Case, async: false

  alias Elara.Benchmark.{ElaraAdapter, Manifest}

  @manifest_path Path.expand("../../fixtures/benchmark/exp003/manifest.json", __DIR__)
  @v3_manifest_path Path.expand("../../fixtures/benchmark/exp003-v3/manifest.json", __DIR__)
  @v4_manifest_path Path.expand("../../fixtures/benchmark/exp003-v4/manifest.json", __DIR__)
  @v6_manifest_path Path.expand("../../fixtures/benchmark/exp003-v6/manifest.json", __DIR__)

  setup do
    {:ok, manifest} = Manifest.load(@manifest_path)
    %{manifest: manifest}
  end

  test "maps every frozen plan explicitly onto the unchanged builtin API", %{manifest: manifest} do
    mappings =
      Map.new(manifest.tasks, fn {id, task} -> {id, unwrap(ElaraAdapter.mapping(task))} end)

    assert Enum.frequencies_by(mappings, fn {_id, mapping} -> mapping["tool_name"] end) == %{
             "bash" => 4,
             "edit" => 4,
             "write" => 4
           }

    for {task_id, mapping} <- mappings do
      assert mapping["tool_call_id"] == "exp003-#{String.downcase(task_id)}"
      assert mapping["final_assistant_text"] == "Task complete."
      assert is_map(mapping["tool_arguments"])
      assert is_map(mapping["execution_constraints"])
    end

    assert mappings["W07"]["tool_arguments"] |> Map.keys() |> Enum.sort() ==
             ~w(content path)

    assert mappings["P07"]["tool_arguments"] |> Map.keys() |> Enum.sort() ==
             ~w(new_text old_text path)

    assert mappings["S01"]["tool_arguments"] |> Map.keys() == ["command"]
    assert mappings["S01"]["execution_constraints"]["requested_timeout_ms"] == 5_000

    assert mappings["S01"]["execution_constraints"]["environment"] == %{
             "LANG" => "C",
             "LC_ALL" => "C"
           }
  end

  test "categorically forbids confirmatory fault execution" do
    task = manifest_task("P01")
    row = manifest_row("P01-F1")
    config = %{targets: %{}, fault_authorization: nil}

    assert {:error, :confirmatory_fault_execution_forbidden} =
             ElaraAdapter.with_config(config, fn ->
               ElaraAdapter.execute(task, "/tmp/not-used", %{
                 kind: :fault,
                 condition: "baseline",
                 row: row
               })
             end)
  end

  test "only exact frozen historical or active manifests authorize confirmatory execution" do
    {:ok, manifest} = Manifest.load(@v3_manifest_path)
    base = %{targets: %{}, fault_authorization: nil}

    assert {:ok, authorized} = ElaraAdapter.authorize_confirmatory(base, manifest)

    assert {:error, {:target_not_prepared, "baseline"}} =
             ElaraAdapter.with_config(authorized, fn ->
               ElaraAdapter.execute(manifest.tasks["P01"], "/tmp/not-used", %{
                 kind: :fault,
                 condition: "baseline",
                 row: manifest.rows["P01-F1"]
               })
             end)

    forged_row = Map.put(manifest.rows["P01-F1"], "observation_deadline_ms", 1)

    assert {:error, :confirmatory_fault_execution_forbidden} =
             ElaraAdapter.with_config(authorized, fn ->
               ElaraAdapter.execute(manifest.tasks["P01"], "/tmp/not-used", %{
                 kind: :fault,
                 condition: "baseline",
                 row: forged_row
               })
             end)

    altered = %{manifest | sha256: String.duplicate("0", 64)}

    assert {:error, :confirmatory_manifest_not_frozen} =
             ElaraAdapter.authorize_confirmatory(base, altered)

    {:ok, v4_manifest} = Manifest.load(@v4_manifest_path)
    assert {:ok, v4_authorized} = ElaraAdapter.authorize_confirmatory(base, v4_manifest)

    assert {:error, {:target_not_prepared, "receipts"}} =
             ElaraAdapter.with_config(v4_authorized, fn ->
               ElaraAdapter.execute(v4_manifest.tasks["W08"], "/tmp/not-used", %{
                 kind: :fault,
                 condition: "receipts",
                 row: v4_manifest.rows["W08-F2"]
               })
             end)

    {:ok, v6_manifest} = Manifest.load(@v6_manifest_path)
    assert {:ok, v6_authorized} = ElaraAdapter.authorize_confirmatory(base, v6_manifest)

    assert {:error, {:target_not_prepared, "baseline"}} =
             ElaraAdapter.with_config(v6_authorized, fn ->
               ElaraAdapter.execute(v6_manifest.tasks["S04"], "/tmp/not-used", %{
                 kind: :fault,
                 condition: "baseline",
                 row: v6_manifest.rows["S04-F2"]
               })
             end)
  end

  test "pins both immutable target commits" do
    assert ElaraAdapter.target_commits() == %{
             "baseline" => "23e603550253c69846795b13cc2f2670f1122e21",
             "receipts" => "9ff416f2c22327c5ef38edcd52a9e89108fbc726"
           }
  end

  defp unwrap({:ok, value}), do: value

  defp manifest_task(id) do
    {:ok, manifest} = Manifest.load(@manifest_path)
    manifest.tasks[id]
  end

  defp manifest_row(id) do
    {:ok, manifest} = Manifest.load(@manifest_path)
    manifest.rows[id]
  end
end
