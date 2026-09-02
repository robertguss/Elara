defmodule Elara.Benchmark.PreregistrationV7Test do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @contract_path Path.join(@root, "docs/experiments/003-effect-receipt-v7-protocol.json")
  @preregistration_path Path.join(
                          @root,
                          "docs/experiments/003-effect-receipt-confirmatory-preregistration-v7.md"
                        )
  @eligible ~w(P01 P02 P04 P06 P07 P08 S01 S02 S03 S04 W01 W02 W03 W05 W06 W07 W08)
  @excluded ~w(P03 P05 W04)

  setup_all do
    contract = @contract_path |> File.read!() |> JSON.decode!()
    %{contract: contract, preregistration: File.read!(@preregistration_path)}
  end

  test "pins the pushed 112-run proof and exact conditional frame", %{contract: contract} do
    proof = contract["development_proof"]
    frame = contract["eligibility_frame"]

    assert contract["schema"] == "elara.exp003.preregistration.v7"
    assert contract["preregistration_version"] == "ER-3/FND-2-v7"
    assert contract["frozen_against_commit"] == "98cf40a03b68a943f75342ac9704257bbb083885"
    assert proof["commit"] == contract["frozen_against_commit"]
    assert proof["source_candidate_count"] == 20
    assert proof["mapping_proof_count"] == 20
    assert proof["no_fault_run_count"] == 40
    assert proof["eligible_candidate_count"] == 17
    assert proof["assignment_count"] == 34
    assert proof["assignment_fault_run_count"] == 68
    assert proof["continuation_probe_run_count"] == 4
    assert proof["fault_run_count"] == 72
    assert proof["total_command_path_run_count"] == 112
    assert proof["all_eligible_fault_runs_valid"]
    assert frame["eligible_candidate_ids"] == @eligible
    assert Enum.map(frame["excluded_candidates"], & &1["id"]) == @excluded
    assert frame["estimand"] =~ "17-candidate E=1"
    assert frame["forbidden_inference"] =~ "original 20-candidate population"

    for {path_key, digest_key} <- [
          {"report_path", "report_sha256"},
          {"adapter_path", "adapter_sha256"},
          {"target_runner_path", "target_runner_sha256"},
          {"preflight_path", "preflight_sha256"},
          {"neutral_runner_path", "neutral_runner_sha256"},
          {"candidate_source_path", "candidate_source_sha256"},
          {"compatibility_source_path", "compatibility_source_sha256"}
        ] do
      assert file_sha256(proof[path_key]) == proof[digest_key]
    end

    source = @root |> Path.join(proof["candidate_source_path"]) |> File.read!() |> JSON.decode!()
    assert contract["required_evidence_fields"] == source["required_evidence_fields"]
    assert length(contract["required_evidence_fields"]) == 54
  end

  test "freezes the 17-candidate strata, quotas, and exact inclusion probabilities", %{
    contract: contract
  } do
    sampling = contract["candidate_sampling"]
    candidates = sampling["candidates"]

    assert sampling["task_quota"] == 12
    assert length(candidates) == 17
    assert Enum.map(candidates, & &1["id"]) == @eligible

    assert Enum.frequencies_by(candidates, & &1["class"]) == %{
             "patch" => 6,
             "shell" => 4,
             "write" => 7
           }

    assert Enum.frequencies_by(candidates, & &1["stratum_size"]) == %{1 => 8, 2 => 6, 3 => 3}
    assert sum_probabilities(candidates, "task_inclusion_probability") == {12, 1}
    assert sum_probabilities(candidates, "secondary_row_inclusion_probability") == {8, 1}

    assert sampling["probability_checks"] == %{
             "sum_secondary_row_inclusion_probabilities" => "8",
             "sum_task_inclusion_probabilities" => "12"
           }

    assert sampling["row_rule"] =~ "exactly 20 locked rows"
    assert sampling["forbidden"] =~ "No skip-and-redraw"

    for candidate <- candidates do
      assert candidate["task_inclusion_probability"] ==
               %{1 => "1", 2 => "1/2", 3 => "1/3"}[candidate["stratum_size"]]

      assert candidate["secondary_row_inclusion_probability"] ==
               %{
                 1 => "84223/145860",
                 2 => "8981/21879",
                 3 => "33464/109395"
               }[candidate["stratum_size"]]
    end
  end

  test "normatively freezes provider, identity, cardinality, alias, and P06 F4 behavior", %{
    contract: contract
  } do
    provider = contract["provider_and_identity_contract"]
    p06 = provider["p06"]
    cardinality = provider["receipt_cardinality"]
    workspace = contract["workspace_and_causality_contract"]

    assert provider["barrier_and_injection_count"] == 1
    assert provider["continuation_fault_injection"] == "forbidden"
    assert p06["target_tool_call_id"] == "exp003-p06"
    assert p06["continuation_tool_call_id"] == "exp003-p06-continuation"
    assert p06["halt_assistant_text"] == "Task halted after non-ok target result."
    assert p06["no_fault_and_receipts_F2"]["provider_calls"] == 3
    assert p06["baseline_F2_F3_and_receipts_F3"]["disposition"] == "skipped_non_ok"
    assert p06["F1_F4_controller_recovery"]["provider_calls"] == 1
    assert p06["recovered_controller_continuation"] == "forbidden"
    assert cardinality["p06_no_fault"] == %{"target_jobs" => 1, "task_jobs" => 2}
    assert cardinality["p06_receipts_F2"] == %{"target_jobs" => 1, "task_jobs" => 2}

    assert cardinality["p06_other_receipts_faults"] == %{
             "target_jobs" => 1,
             "task_jobs" => 1
           }

    assert workspace["aliases"] ==
             ~w(initial_reset_workspace pre_effect_workspace fault_target_postcondition complete_task_workspace)

    assert workspace["interpretation"] =~ "never infer causal job completion"

    assert workspace["p06_converged_workspace"]["F4"] == %{
             "baseline" => "fault_target_postcondition",
             "receipts" => "fault_target_postcondition"
           }

    assert workspace["s04_F2_receipts"] =~ "causal receipt rather than bytes"
  end

  test "commits an exact genuinely future drand round without fetching it", context do
    %{contract: contract, preregistration: preregistration} = context
    beacon = contract["beacon"]

    assert beacon["chain_hash"] ==
             "8990e7a9aaed2ffed73dbd7092123d6f289930540d7651336225dc172e51b2ce"

    assert beacon["genesis_unix"] + (beacon["round"] - 1) * beacon["period_seconds"] ==
             beacon["nominal_unix"]

    assert beacon["round"] == 6_429_446
    assert beacon["nominal_unix"] == 1_788_314_400
    assert beacon["nominal_time"] == "2026-09-02T02:00:00Z"
    assert beacon["domain_separator"] == "elara:exp-003:er3:fnd-2:v7\\0"
    assert beacon["verification_client"] == "drand-client@1.4.2"
    assert beacon["early_fetch"] == "forbidden"
    assert beacon["substitution_or_retry"] == "forbidden"
    assert beacon["seed_derivation"] =~ contract["frozen_against_commit"]
    assert preregistration =~ "1595431050 + (6429446 - 1) * 30 = 1788314400"
    assert preregistration =~ "must not fetch before nominal time"

    exposure = contract["exposure"]
    assert exposure["v7_future_beacon_committed"]
    refute exposure["v7_future_beacon_fetched"]
    refute exposure["v7_candidate_selection_performed"]
    refute exposure["v7_held_out_literals_generated"]
    refute exposure["v7_B_or_T_calculated"]
    assert exposure["v7_target_fault_runs"] == 0
    assert exposure["v7_target_timing_runs"] == 0
    assert exposure["v7_external_fault_runs"] == 0
    assert exposure["v7_dogfood_runs"] == 0
  end

  test "inherits exact safety, scoring, gate, comparator, and dogfood rules", %{
    contract: contract,
    preregistration: preregistration
  } do
    assert contract["scoring"]["material_improvement"] ==
             ["B >= 2", "B - T >= 2", "2 * (B - T) >= B"]

    assert contract["gate_3"]["narrow_order"] == ["write+patch", "write", "patch"]
    assert hd(contract["gate_3"]["precedence"]) == "Stop on invalidity or safety"

    assert contract["targets"]["external_comparator"]["disposition"] ==
             "Insufficient comparability"

    refute contract["targets"]["external_comparator"]["external_fault_execution_authorized"]

    assert contract["dogfood"]["thresholds"] ==
             ["D >= 8", "G == I", "5 * U >= 4 * D", "A == 0", "no safety disqualifier"]

    assert contract["invalidation"]["v6"] =~ "cannot be retried"
    assert preregistration =~ "does not test or support BEAM superiority"
    assert preregistration =~ "Safety is Stop-first"
  end

  test "preserves every pinned predecessor artifact and contains no V7 beacon result", %{
    contract: contract
  } do
    for {path, expected} <- contract["preserved_artifact_sha256"] do
      assert file_sha256(path) == expected
    end

    bytes = File.read!(@contract_path)
    refute bytes =~ ~r/"randomness"\s*:/
    refute bytes =~ ~r/"signature"\s*:/
    refute bytes =~ ~r/"seed"\s*:\s*"[0-9a-f]{64}"/
  end

  defp sum_probabilities(candidates, key) do
    candidates
    |> Enum.map(&parse_fraction(&1[key]))
    |> Enum.reduce({0, 1}, &add_fraction/2)
  end

  defp parse_fraction(value) do
    case String.split(value, "/") do
      [numerator] -> {String.to_integer(numerator), 1}
      [numerator, denominator] -> {String.to_integer(numerator), String.to_integer(denominator)}
    end
  end

  defp add_fraction({left_n, left_d}, {right_n, right_d}) do
    numerator = left_n * right_d + right_n * left_d
    denominator = left_d * right_d
    divisor = Integer.gcd(numerator, denominator)
    {div(numerator, divisor), div(denominator, divisor)}
  end

  defp file_sha256(path) do
    @root
    |> Path.join(path)
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
