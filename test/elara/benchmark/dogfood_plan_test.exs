defmodule Elara.Benchmark.DogfoodPlanTest do
  use ExUnit.Case, async: false

  alias Elara.Benchmark.Dogfood.Plan

  @path "test/fixtures/benchmark/exp003/dogfood-plan.json"
  @expected_order ~w(D01 D03 D06 D12 D04 D10 D02 D11 D08 D05 D09 D07)

  test "the frozen plan pins the complete historical frame and seed order" do
    assert {:ok, plan} = Plan.load(@path)

    assert Enum.map(plan.data["tasks"], & &1["id"]) ==
             ~w(D01 D02 D03 D04 D05 D06 D07 D08 D09 D10 D11 D12)

    assert Enum.map(Plan.execution_tasks(plan), & &1["id"]) == @expected_order

    assert Enum.frequencies_by(plan.data["tasks"], & &1["assignment"])["no_fault_control"] == 2
    assert Enum.count(plan.data["tasks"], &(&1["fault"] != nil)) == 10

    assert plan.data["tasks"]
           |> Enum.reject(&(&1["assignment"] == "no_fault_control"))
           |> Enum.map(& &1["assignment"])
           |> Enum.uniq()
           |> length() == 6

    assert plan.data["denominators"] == %{"P" => 12, "I" => 10, "C" => 2}
    assert plan.data["rounding"] == "one_decimal_half_away_from_zero"
    assert plan.data["target"]["commit"] == "9ff416f2c22327c5ef38edcd52a9e89108fbc726"
    assert plan.data["provider"]["requested_model"] == "grok-4"
    assert plan.data["provider"]["credential_values_in_manifest"] == false
    assert plan.data["exposure"]["dogfood_task_runs"] == 0
    assert plan.data["exposure"]["dogfood_fault_runs"] == 0
  end

  test "every task freezes its parent, ground truth, prompt, operation, deadlines, and acceptance" do
    assert {:ok, plan} = Plan.load(@path)

    for task <- plan.data["tasks"] do
      assert byte_size(task["commit"]) == 40
      assert byte_size(task["parent_commit"]) == 40
      assert byte_size(task["tree"]) == 40
      assert byte_size(task["patch_sha256"]) == 64
      assert task["prompt"] != ""
      assert task["operation_mapping"] in ~w(write patch)
      assert task["active_deadline_ms"] > 0
      assert task["knowledge_deadline_ms"] == 5_000
      assert task["changed_files"] != []
      assert task["acceptance"] != []

      for command <- task["acceptance"] do
        assert command["expected_exit"] == 0
        assert command["timeout_ms"] > 0
      end
    end
  end

  test "the plan rejects changed immutable Git evidence" do
    data = @path |> File.read!() |> JSON.decode!()
    [first | rest] = data["tasks"]
    changed = put_in(first["patch_sha256"], String.duplicate("0", 64))

    path =
      Path.join(
        System.tmp_dir!(),
        "dogfood-plan-tampered-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, JSON.encode!(%{data | "tasks" => [changed | rest]}))
    on_exit(fn -> File.rm(path) end)

    assert {:error, errors} = Plan.load(path)
    assert {:git_content_mismatch, "D01"} in errors
  end
end
