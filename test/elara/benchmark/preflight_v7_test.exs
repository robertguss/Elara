defmodule Elara.Benchmark.PreflightV7Test do
  use ExUnit.Case, async: true

  alias Elara.Benchmark.InternalConfirmatory

  @root Path.expand("../../..", __DIR__)
  @report_path Path.join(
                 @root,
                 "docs/experiments/003-effect-receipt-v7-command-path-preflight.json"
               )
  @report_sha256 "c7522da0fd1730b61241898450893b7761d59ea8dab0721cb01d0e4e7eabf435"
  @eligible ~w(P01 P02 P04 P06 P07 P08 S01 S02 S03 S04 W01 W02 W03 W05 W06 W07 W08)
  @ineligible ~w(P03 P05 W04)

  setup_all do
    bytes = File.read!(@report_path)
    %{bytes: bytes, report: JSON.decode!(bytes)}
  end

  test "freezes the exact 112-run command-path qualification frame", %{report: report} do
    assert report["schema"] == "elara.exp003.command-path-preflight.v7"
    assert report["linear_issue"] == "ROB-873"

    assert report["summary"] == %{
             "all_eligible_fault_runs_valid" => true,
             "assignment_count" => 34,
             "assignment_fault_run_count" => 68,
             "byte_determinism_required" => true,
             "candidate_count" => 20,
             "continuation_probe_count" => 2,
             "continuation_probe_run_count" => 4,
             "eligible_candidate_count" => 17,
             "eligible_candidate_ids" => @eligible,
             "fault_run_count" => 72,
             "ineligible_candidate_count" => 3,
             "ineligible_candidate_ids" => @ineligible,
             "mapping_proof_count" => 20,
             "no_fault_run_count" => 40,
             "total_command_path_run_count" => 112
           }
  end

  test "proves every plan mapping and the two-step P06 continuation contract", %{report: report} do
    proofs = report["mapping_proofs"]

    assert Enum.map(proofs, & &1["task_id"]) == Enum.sort(@eligible ++ @ineligible)

    for proof <- proofs do
      assert proof["step_indices_bijective"]
      assert proof["arguments_refs_bijective"]
      assert proof["unique_tool_call_ids"]
      assert proof["fault_target_step"] == "effect"
      assert proof["mapping_semantic_sha256"] =~ ~r/^[0-9a-f]{64}$/
    end

    p06 = Enum.find(proofs, &(&1["task_id"] == "P06"))
    assert p06["step_count"] == 2
    assert Enum.map(p06["steps"], & &1["step_index"]) == [0, 1]
    assert Enum.map(p06["steps"], & &1["step_id"]) == ~w(effect continuation)

    assert Enum.map(p06["steps"], & &1["tool_call_id"]) ==
             ~w(exp003-p06 exp003-p06-continuation)

    assert p06["fault_target_tool_call_id"] == "exp003-p06"
    assert p06["final_assistant_text"] == "Task complete."
    assert p06["non_ok_halt_assistant_text"] == "Task halted after non-ok target result."
    assert p06["continuation_policy"]["parallelism"] == "forbidden"

    assert p06["continuation_policy"]["fault_injection"] ==
             "effect only; continuation is never faulted"
  end

  test "records the exact bilateral builtin incompatibilities without a semantic shim", %{
    report: report
  } do
    stage = report["stage_a_no_fault_eligibility"]
    records = Map.new(stage["records"], &{&1["task_id"], &1})

    assert stage["exact_ineligible_set_reproduced"]
    assert stage["rule"] =~ "no adapter-owned semantic shim"

    assert records |> Map.values() |> Enum.reject(& &1["eligible"]) |> Enum.map(& &1["task_id"]) ==
             @ineligible

    for condition <- ~w(baseline receipts) do
      p03 = records["P03"]["failure_evidence"][condition]
      assert p03["failures"] == ["outcome_mismatch"]
      assert p03["expected_outcome"] == "ok"
      assert p03["observed"]["outcome"] == "error_conflict"
      assert p03["observed"]["workspace_correct"]

      for task_id <- ~w(P05 W04) do
        conflict = records[task_id]["failure_evidence"][condition]

        assert MapSet.new(conflict["failures"]) ==
                 MapSet.new(~w(workspace_mismatch outcome_mismatch))

        assert conflict["expected_outcome"] == "error_conflict"
        assert conflict["observed"]["outcome"] == "ok"
        refute conflict["observed"]["workspace_correct"]
      end
    end
  end

  test "all 72 fault command paths are valid and P06 transitions are exact", %{report: report} do
    stage = report["stage_b_fault_command_path"]
    assignments = stage["assignment_records"]
    probes = stage["p06_continuation_probe_records"]

    assert length(assignments) == 34
    assert length(probes) == 2

    for record <- assignments ++ probes,
        condition <- ~w(baseline receipts) do
      assert record["conditions"][condition]["valid"]
      assert record["conditions"][condition]["semantic_projection_sha256"] =~ ~r/^[0-9a-f]{64}$/
    end

    proof = report["p06_transition_proof"]
    assert proof["fault_target_tool_call_id"] == "exp003-p06"
    assert proof["continuation_tool_call_id"] == "exp003-p06-continuation"
    assert proof["halt_assistant_text"] == "Task halted after non-ok target result."
    assert length(proof["no_fault"]) == 2
    assert length(proof["faults"]) == 8

    for no_fault <- proof["no_fault"] do
      assert no_fault["provider_state"]["call_count"] == 3
      assert no_fault["provider_state"]["disposition"] == "completed"

      assert no_fault["provider_state"]["emitted_tool_call_ids"] ==
               ~w(exp003-p06 exp003-p06-continuation)
    end

    for fault <- proof["faults"] do
      assert fault["barrier_count"] == 1
      assert fault["injection_count"] == 1
      assert fault["barrier_identity_matches"]
      assert fault["target_tool_call_count"] == 1
      assert fault["target_session_result_count"] == 1

      case {fault["fault_type"], fault["condition"]} do
        {"F2", "receipts"} ->
          assert fault["provider_state"]["disposition"] == "completed"
          assert fault["task_tool_call_count"] == 2
          assert fault["executor_task_job_count"] == 2

        {type, _condition} when type in ~w(F1 F4) ->
          assert fault["provider_state"]["disposition"] == "active"

          assert fault["provider_state"]["remaining_tool_call_ids"] == [
                   "exp003-p06-continuation"
                 ]

        {type, _condition} when type in ~w(F2 F3) ->
          assert fault["provider_state"]["disposition"] == "skipped_non_ok"

          assert fault["provider_state"]["skipped_tool_call_ids"] == [
                   "exp003-p06-continuation"
                 ]
      end
    end
  end

  test "keeps S04 workspace aliases separate from causal completion", %{report: report} do
    proof = report["s04_alias_proof"]

    assert proof["row_id"] == "QUAL-V7-S04-F2-primary"
    assert proof["condition"] == "receipts"

    assert proof["workspace_digest_aliases"] ==
             ~w(initial_reset_workspace pre_effect_workspace fault_target_postcondition complete_task_workspace)

    assert proof["workspace_observation"] == "complete_task_workspace"
    refute proof["workspace_digest_proves_causal_completion"]
    assert proof["callback_attempt_count"] == 1
    assert proof["external_mutation_count"] == 1
    assert proof["barrier"]["barrier_count"] == 1
    assert proof["barrier"]["injection_count"] == 1
    assert proof["controller"]["target_match_count"] == 1
    assert proof["executor"]["target_match_count"] == 1
  end

  test "preserves zero confirmatory exposure and every predecessor artifact", %{report: report} do
    exposure = report["exposure"]

    refute exposure["v7_future_beacon_committed"]
    refute exposure["v7_future_beacon_fetched"]
    refute exposure["v7_beacon_candidate_selection_performed"]
    refute exposure["v7_held_out_task_literals_generated"]
    refute exposure["v7_B_or_T_calculated"]
    assert exposure["v7_held_out_target_fault_rows"] == 0
    assert exposure["v7_target_timing_runs"] == 0
    assert exposure["v7_comparator_runs"] == 0
    assert exposure["v7_dogfood_runs"] == 0
    assert exposure["development_no_fault_runs"] == 40
    assert exposure["development_fault_runs"] == 72

    for {path, expected} <- report["preserved_artifact_sha256"] do
      assert file_sha256(path) == expected
    end
  end

  test "the canonical report is byte-stable and excludes run-local nondeterminism", context do
    %{bytes: bytes, report: report} = context

    assert sha256(bytes) == @report_sha256
    assert InternalConfirmatory.canonical_json(report) == bytes

    for {source_key, digest_key} <- [
          {"adapter_source", "adapter_sha256"},
          {"target_runner_source", "target_runner_sha256"},
          {"neutral_runner_source", "neutral_runner_sha256"},
          {"preflight_source", "preflight_source_sha256"},
          {"candidate_source", "candidate_source_sha256"},
          {"compatibility", "compatibility_sha256"}
        ] do
      assert file_sha256(report["inputs"][source_key]) == report["inputs"][digest_key]
    end

    forbidden_keys =
      MapSet.new(
        ~w(timestamp started_at ended_at elapsed_ms duration_ms knowledge_convergence_ms terminal_convergence_ms job_id operation_digest pid process_hash state_root workspace_root output_path)
      )

    assert MapSet.disjoint?(all_keys(report), forbidden_keys)

    refute Enum.any?(all_strings(report), fn value ->
             String.starts_with?(value, "/") or String.contains?(value, "/tmp/") or
               String.contains?(value, "#PID<")
           end)
  end

  defp all_keys(value),
    do: value |> collect_keys(MapSet.new())

  defp collect_keys(map, keys) when is_map(map) do
    Enum.reduce(map, keys, fn {key, value}, acc ->
      value
      |> collect_keys(MapSet.put(acc, key))
    end)
  end

  defp collect_keys(list, keys) when is_list(list),
    do: Enum.reduce(list, keys, &collect_keys/2)

  defp collect_keys(_value, keys), do: keys

  defp all_strings(value), do: collect_strings(value, [])

  defp collect_strings(map, strings) when is_map(map),
    do: Enum.reduce(map, strings, fn {_key, value}, acc -> collect_strings(value, acc) end)

  defp collect_strings(list, strings) when is_list(list),
    do: Enum.reduce(list, strings, &collect_strings/2)

  defp collect_strings(value, strings) when is_binary(value), do: [value | strings]
  defp collect_strings(_value, strings), do: strings

  defp file_sha256(path), do: @root |> Path.join(path) |> File.read!() |> sha256()
  defp sha256(value), do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
