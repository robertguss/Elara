defmodule Elara.Benchmark.CorpusSpecTest do
  use ExUnit.Case, async: true

  @manifest_path Path.expand("../../fixtures/benchmark/exp003/manifest.json", __DIR__)
  @external_resource @manifest_path
  @manifest @manifest_path |> File.read!() |> JSON.decode!()
  @fixture_root Path.dirname(@manifest_path)

  @required_row_fields ~w(
    row_id order_index task_id operation_class fault_type fault_role name
    target_relation barrier_id crash_target failpoint delivered_messages
    dropped_messages surviving_storage restart_order admissible_evidence
    last_durable_fact historical_execution_knowledge
    expected_workspace_observation expected_safe_action
    expected_primary_recovery_class observation_deadline_ms
    knowledge_and_safe_action_convergence_bound_ms
    causal_terminal_evidence_expected_to_survive permitted_recovery_actions
    prohibited_recovery_actions safety_invariants semantic_equivalence
  )

  test "the committed future beacon round and seed match the frozen derivation" do
    gate = @manifest["gate_2"]
    beacon = @manifest["beacon"]
    seed = @manifest["seed"]

    target = gate["completed_at_unix_second"] + 300
    expected_round = ceil_div(target - beacon["genesis_time"], beacon["period_seconds"]) + 1

    assert gate["future_target_unix_second"] == target
    assert beacon["round"] == expected_round
    assert beacon["nominal_time"] == "2026-09-01T02:44:30Z"

    material =
      "elara:exp-003:er3:fnd-2:v1\0" <>
        beacon["chain_hash"] <>
        ":" <>
        Integer.to_string(beacon["round"]) <>
        ":" <> beacon["randomness"] <> ":" <> seed["frozen_commit"]

    assert sha256(material) == seed["sha256"]
  end

  test "both raw relay responses agree and the official client verification is preserved" do
    [api_path, cloudflare_path] = @manifest["beacon"]["relay_response_paths"]
    api = api_path |> fixture_path() |> File.read!() |> JSON.decode!()
    cloudflare = cloudflare_path |> fixture_path() |> File.read!() |> JSON.decode!()

    verification =
      @manifest["beacon"]["verification_path"] |> fixture_path() |> File.read!() |> JSON.decode!()

    assert api == cloudflare
    assert api["round"] == @manifest["beacon"]["round"]
    assert api["randomness"] == @manifest["beacon"]["randomness"]
    assert sha256(Base.decode16!(api["signature"], case: :mixed)) == api["randomness"]

    assert verification["verified"]
    assert verification["client"] == @manifest["beacon"]["official_client"]
    assert Enum.map(verification["results"], &Map.drop(&1, ["url"])) == [api, api]

    for {filename, expected} <- @manifest["beacon"]["artifact_sha256"] do
      assert filename |> then(&fixture_path("beacon/" <> &1)) |> File.read!() |> sha256() ==
               expected
    end
  end

  test "Universal membership follows the seed and disclosed shell interpretation" do
    candidates = @manifest["candidate_frame"]
    seed = Base.decode16!(@manifest["seed"]["sha256"], case: :mixed)

    assert length(candidates) == 20

    for candidate <- candidates do
      assert candidate["order_key"] == sha256(seed <> <<0>> <> candidate["id"])
    end

    expected_typed =
      for operation <- ["write", "patch"], fault <- ~w(F1 F2 F3 F4) do
        candidates
        |> Enum.filter(&(&1["operation_class"] == operation and &1["primary_fault"] == fault))
        |> Enum.min_by(& &1["order_key"])
        |> Map.fetch!("id")
      end

    expected_ids =
      (expected_typed ++ ~w(S01 S02 S03 S04))
      |> Enum.sort_by(fn id -> candidate(candidates, id)["order_key"] end)

    assert @manifest["selection"]["selected_task_ids"] == expected_ids
    assert @manifest["selection"]["secondary_row_task_ids"] == Enum.take(expected_ids, 8)
    assert Enum.map(@manifest["tasks"], & &1["id"]) == expected_ids

    assert Enum.frequencies_by(@manifest["tasks"], & &1["operation_class"]) == %{
             "patch" => 4,
             "shell" => 4,
             "write" => 4
           }

    shell = Enum.filter(@manifest["tasks"], &(&1["operation_class"] == "shell"))

    assert Enum.map(shell, & &1["primary_fault"]) |> Enum.frequencies() == %{
             "F1" => 1,
             "F2" => 2,
             "F3" => 1
           }

    assert @manifest["selection"]["shell_primary_distribution"] == ~w(F1 F2 F3 F2)

    assert @manifest["selection"]["non_amending_shell_interpretation"] =~
             "do not correct S04"
  end

  test "the 20 scored rows are the frozen primary then lowest-key secondary construction" do
    tasks = Map.new(@manifest["tasks"], &{&1["id"], &1})
    selected = @manifest["selection"]["selected_task_ids"]
    secondary = @manifest["selection"]["secondary_row_task_ids"]

    expected =
      Enum.map(selected, &"#{&1}-#{tasks[&1]["primary_fault"]}") ++
        Enum.map(secondary, &"#{&1}-#{tasks[&1]["secondary_fault"]}")

    assert Enum.map(@manifest["fault_rows"], & &1["row_id"]) == expected
    assert Enum.map(@manifest["fault_rows"], & &1["order_index"]) == Enum.to_list(1..20)
    assert length(Enum.uniq(expected)) == 20

    for row <- @manifest["fault_rows"] do
      assert Enum.all?(@required_row_fields, &Map.has_key?(row, &1))
      assert row["fault_type"] in ~w(F1 F2 F3 F4)
      assert row["barrier_id"] != ""
      refute String.contains?(row["barrier_id"], "sleep")
      refute String.contains?(row["failpoint"], "sleep")
      assert row["crash_target"] in ["controller", "selected_worker_or_tool_owner"]
      assert row["observation_deadline_ms"] in [2_000, 5_000]
      assert row["knowledge_and_safe_action_convergence_bound_ms"] == 1_000

      assert row["expected_primary_recovery_class"]["baseline"] in [
               "manual_recovery",
               "ambiguous_no_safe_action"
             ]

      assert row["expected_primary_recovery_class"]["receipts"] in [
               "automatic_terminal",
               "automatic_safe_indeterminate"
             ]

      assert row["semantic_equivalence"]["baseline_target_only_seams"] =~ "N/A"
      assert "workspace postcondition never proves this job caused it" in row["safety_invariants"]
    end
  end

  test "tasks freeze offline plans, generated tokens, evidence, and adapter fixtures" do
    assert @manifest["schema"] == "elara.exp003.corpus.v1"
    assert @manifest["preregistration_version"] == "ER-3/FND-2-v1"
    assert @manifest["scope_id"] == "continue_universal"

    assert @manifest["fault_repetitions"]["interleaving"] ==
             ~w(baseline receipts receipts baseline baseline receipts)

    assert @manifest["no_fault_timing"] == %{"warmups" => 2, "measured_repetitions" => 10}

    assert Enum.map(@manifest["adapter_equivalence_fixtures"], & &1["template_id"]) ==
             ~w(W01 P01 S02)

    assert Enum.all?(@manifest["adapter_equivalence_fixtures"], &(not &1["scored"]))

    for task <- @manifest["tasks"] do
      assert task["exposure_split"] == "held_out_relative_to_target_implementation"
      assert task["fixture"]["fixture_commit"] == "sha256:" <> task["fixture"]["fixture_sha256"]
      assert task["plan"]["schema"] == "elara.exp003.plan.v1"
      assert length(task["plan"]["steps"]) == 1
      assert length(task["plan"]["scripted_provider"]) == 2
      assert task["plan"]["fault_target_step"] == "effect"

      assert task["ground_truth"]["required_counts"] == [
               "admission_count",
               "callback_attempt_count",
               "external_mutation_count",
               "session_result_count"
             ]

      refute task["request"] =~ "http://"
      refute task["request"] =~ "https://"

      for token <- Map.values(task["generated_tokens"]) do
        refute String.contains?(task["request"], token)
      end

      step = hd(task["plan"]["steps"])
      refute step["arguments"] |> JSON.encode!() |> String.contains?("curl ")
      refute step["arguments"] |> JSON.encode!() |> String.contains?("wget ")
    end

    required_evidence = MapSet.new(@manifest["required_evidence_fields"])

    for field <- ~w(
          controller_facts executor_facts workspace_observations
          historical_execution_knowledge session_classification
          safe_next_action_expected safe_next_action_observed
          admission_count callback_attempt_count external_mutation_count
          session_result_count primary_recovery_class safety_disqualifiers
          harness_errors raw_evidence_digest artifact_digests
        ) do
      assert MapSet.member?(required_evidence, field)
    end
  end

  defp candidate(candidates, id), do: Enum.find(candidates, &(&1["id"] == id))
  defp fixture_path(relative), do: Path.join(@fixture_root, relative)
  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
