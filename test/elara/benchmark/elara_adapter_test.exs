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

    calls = Map.new(mappings, fn {id, mapping} -> {id, hd(mapping["tool_calls"])} end)

    assert Enum.frequencies_by(calls, fn {_id, call} -> call["tool_name"] end) ==
             %{"bash" => 4, "edit" => 4, "write" => 4}

    for {task_id, mapping} <- mappings do
      [call] = mapping["tool_calls"]
      assert call["tool_call_id"] == "exp003-#{String.downcase(task_id)}"
      assert mapping["fault_target_tool_call_id"] == call["tool_call_id"]
      assert mapping["final_assistant_text"] == "Task complete."

      assert mapping["non_ok_halt_assistant_text"] ==
               "Task halted after non-ok target result."

      assert mapping["continuation_policy"] == "not_applicable"
      assert is_map(call["tool_arguments"])
      assert is_map(call["execution_constraints"])
    end

    assert calls["W07"]["tool_arguments"] |> Map.keys() |> Enum.sort() ==
             ~w(content path)

    assert calls["P07"]["tool_arguments"] |> Map.keys() |> Enum.sort() ==
             ~w(new_text old_text path)

    assert calls["S01"]["tool_arguments"] |> Map.keys() == ["command"]
    assert calls["S01"]["execution_constraints"]["requested_timeout_ms"] == 5_000

    assert calls["S01"]["execution_constraints"]["environment"] == %{
             "LANG" => "C",
             "LC_ALL" => "C"
           }
  end

  test "maps P06 as two ordered unique calls with the frozen continuation policy" do
    {:ok, manifest} = Manifest.load(@v6_manifest_path)
    task = manifest.tasks["P06"]

    assert {:ok, mapping} = ElaraAdapter.mapping(task)

    assert Enum.map(mapping["tool_calls"], & &1["step_id"]) == ~w(effect continuation)

    assert Enum.map(mapping["tool_calls"], & &1["tool_call_id"]) ==
             ~w(exp003-p06 exp003-p06-continuation)

    assert Enum.map(mapping["tool_calls"], & &1["step_index"]) == [0, 1]
    assert mapping["fault_target_step"] == "effect"
    assert mapping["fault_target_tool_call_id"] == "exp003-p06"
    assert mapping["continuation_policy"] == task["plan"]["continuation_policy"]
  end

  test "fails closed on malformed multi-step provider and identity shapes" do
    {:ok, manifest} = Manifest.load(@v6_manifest_path)
    task = manifest.tasks["P06"]
    [target, continuation, final] = task["plan"]["scripted_provider"]

    duplicate =
      put_in(
        task,
        ["plan", "scripted_provider"],
        [target, Map.put(continuation, "tool_call_id", target["tool_call_id"]), final]
      )

    bad_ref =
      put_in(
        task,
        ["plan", "scripted_provider"],
        [target, Map.put(continuation, "arguments_ref", "plan.steps[0].arguments"), final]
      )

    extra_turn_key =
      put_in(
        task,
        ["plan", "scripted_provider"],
        [Map.put(target, "unexpected", true), continuation, final]
      )

    missing_policy = update_in(task, ["plan"], &Map.delete(&1, "continuation_policy"))

    for malformed <- [duplicate, bad_ref, extra_turn_key, missing_policy] do
      assert {:error, {:invalid_frozen_plan, _reason}} = ElaraAdapter.mapping(malformed)
    end
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
