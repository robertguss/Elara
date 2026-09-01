defmodule Elara.Benchmark.ElaraAdapterTest do
  use ExUnit.Case, async: false

  alias Elara.Benchmark.{ElaraAdapter, Manifest}

  @manifest_path Path.expand("../../fixtures/benchmark/exp003/manifest.json", __DIR__)

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

  test "forbids fault execution before the immutable comparison" do
    assert {:error, :fault_execution_forbidden} =
             ElaraAdapter.execute(%{}, "/tmp/not-used", %{kind: :fault})
  end

  test "pins both immutable target commits" do
    assert ElaraAdapter.target_commits() == %{
             "baseline" => "23e603550253c69846795b13cc2f2670f1122e21",
             "receipts" => "9ff416f2c22327c5ef38edcd52a9e89108fbc726"
           }
  end

  defp unwrap({:ok, value}), do: value
end
