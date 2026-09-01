defmodule Elara.Benchmark.PreregistrationV6Test do
  use ExUnit.Case, async: true

  alias Elara.Benchmark.Compatibility

  @root Path.expand("../../..", __DIR__)
  @contract_path Path.join(
                   @root,
                   "docs/experiments/003-effect-receipt-v6-compatibility.json"
                 )
  @preregistration_path Path.join(
                          @root,
                          "docs/experiments/003-effect-receipt-confirmatory-preregistration-v6.md"
                        )

  setup_all do
    {:ok, contract} = Compatibility.load(@contract_path)
    %{contract: contract}
  end

  test "inherits the exact condition-correct candidate and fault contract", %{contract: contract} do
    assert :ok = Compatibility.validate(contract)
    v5 = read_json("docs/experiments/003-effect-receipt-v5-compatibility.json")

    assert contract["candidates"] == v5["candidates"]
    assert contract["fault_contracts"] == v5["fault_contracts"]
    assert length(contract["candidates"]) == 20

    assert contract["candidates"]
           |> Enum.flat_map(&[&1["primary_fault"], &1["secondary_fault"]])
           |> length() == 40
  end

  test "pins the completed pre-seed proof before a genuinely future beacon", %{contract: contract} do
    genesis = 1_595_431_050
    round = 6_429_026
    nominal_time = 1_788_301_800
    preregistration = File.read!(@preregistration_path)

    assert genesis + (round - 1) * 30 == nominal_time
    assert contract["frozen_against_commit"] == "ed9a2dbbdd2ba9ab743a9dc95d1f0ba08663891c"
    assert contract["preflight"]["completed_before_beacon_commitment"]
    assert contract["preflight"]["candidate_count"] == 20
    assert contract["preflight"]["validated_assignment_count"] == 40
    refute contract["preflight"]["sampling_or_selection_performed"]

    assert file_sha256(contract["preflight"]["report_path"]) ==
             contract["preflight"]["report_sha256"]

    assert file_sha256(contract["preflight"]["source_path"]) ==
             contract["preflight"]["source_sha256"]

    assert preregistration =~ "6429026"
    assert preregistration =~ "2026-09-01T22:30:00Z"
    assert preregistration =~ "elara:exp-003:er3:fnd-2:v6\\0"
    refute File.exists?(Path.join(@root, "test/fixtures/benchmark/exp003-v6/beacon"))
  end

  test "freezes exact command authorization, scoring, and zero exposure", %{contract: contract} do
    preregistration = File.read!(@preregistration_path)

    assert contract["command_contract"]["qualification_authorization"] == %{
             "valid" => true,
             "status" => "Pass"
           }

    assert contract["command_contract"]["diagnostic_encoding"] ==
             "canonical_json_values_only"

    assert contract["exposure"] == %{
             "v6_target_fault_rows" => 0,
             "v6_no_fault_timing_runs" => 0,
             "v6_external_fault_rows" => 0,
             "v6_dogfood_runs" => 0,
             "v6_B_or_T_calculated" => false
           }

    assert preregistration =~ "B - T >= 2"
    assert preregistration =~ "2 * (B - T) >= B"
    assert preregistration =~ "5 * U >= 4 * D"
    assert preregistration =~ "no comparative claim"
    assert preregistration =~ "does not test or support BEAM superiority"
  end

  test "preserves every pinned prior artifact", %{contract: contract} do
    for {path, expected} <- contract["preserved_artifact_sha256"] do
      assert file_sha256(path) == expected
    end
  end

  test "rejects an incorrect V6 causal-terminal map", %{contract: contract} do
    altered =
      put_in(
        contract,
        ["fault_contracts", "F4", "causal_terminal_evidence_expected_to_survive", "baseline"],
        true
      )

    assert {:error, errors} = Compatibility.validate(altered)
    assert :invalid_causal_terminal_contracts in errors
  end

  defp read_json(path), do: @root |> Path.join(path) |> File.read!() |> JSON.decode!()

  defp file_sha256(path) do
    @root
    |> Path.join(path)
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
