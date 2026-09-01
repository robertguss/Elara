defmodule Elara.Benchmark.PreregistrationV5Test do
  use ExUnit.Case, async: true

  alias Elara.Benchmark.Compatibility

  @root Path.expand("../../..", __DIR__)
  @contract_path Path.join(
                   @root,
                   "docs/experiments/003-effect-receipt-v5-compatibility.json"
                 )
  @preregistration_path Path.join(
                          @root,
                          "docs/experiments/003-effect-receipt-confirmatory-preregistration-v5.md"
                        )

  setup_all do
    {:ok, contract} = Compatibility.load(@contract_path)
    %{contract: contract}
  end

  test "preserves all v4 candidates and workspace semantics", %{contract: contract} do
    assert :ok = Compatibility.validate(contract)
    assert length(contract["candidates"]) == 20

    assert contract["candidates"]
           |> Enum.flat_map(&[&1["primary_fault"], &1["secondary_fault"]])
           |> length() == 40

    v4 =
      @root
      |> Path.join("docs/experiments/003-effect-receipt-v4-compatibility.json")
      |> File.read!()
      |> JSON.decode!()

    inherited_fault_contracts =
      Map.new(contract["fault_contracts"], fn {fault, value} ->
        {fault, Map.delete(value, "causal_terminal_evidence_expected_to_survive")}
      end)

    assert inherited_fault_contracts == v4["fault_contracts"]

    assert contract["candidates"] == v4["candidates"]
  end

  test "freezes condition-specific causal-terminal applicability", %{contract: contract} do
    for fault <- ~w(F1 F2 F3) do
      assert get_in(contract, [
               "fault_contracts",
               fault,
               "causal_terminal_evidence_expected_to_survive"
             ]) == %{
               "baseline" => false,
               "receipts" => false
             }
    end

    assert get_in(contract, [
             "fault_contracts",
             "F4",
             "causal_terminal_evidence_expected_to_survive"
           ]) == %{
             "baseline" => false,
             "receipts" => true
           }

    assert contract["command_corrections"] == %{
             "diagnostic_encoding" => "canonical_json_values_only",
             "qualification_authorization" => %{
               "status" => "Pass",
               "valid" => true
             },
             "record_expectation" => "condition_specific_scalar"
           }

    altered =
      put_in(
        contract,
        ["fault_contracts", "F4", "causal_terminal_evidence_expected_to_survive", "baseline"],
        true
      )

    assert {:error, errors} = Compatibility.validate(altered)
    assert :invalid_causal_terminal_contracts in errors
  end

  test "commits an exact future beacon and unchanged command boundary", %{contract: contract} do
    genesis = 1_595_431_050
    round = 6_428_936
    nominal_time = 1_788_299_100
    preregistration = File.read!(@preregistration_path)

    assert genesis + (round - 1) * 30 == nominal_time
    assert preregistration =~ "qualify <v5-manifest>"
    assert preregistration =~ "execute <v5-manifest>"
    assert preregistration =~ "replay <v5-manifest>"
    assert preregistration =~ "status=Pass"

    assert contract["exposure"] == %{
             "v5_target_fault_rows" => 0,
             "v5_no_fault_timing_runs" => 0,
             "v5_external_fault_rows" => 0,
             "v5_dogfood_runs" => 0,
             "v5_B_or_T_calculated" => false
           }
  end

  test "all preserved v4 artifacts and failure evidence remain byte-identical", %{
    contract: contract
  } do
    for {path, expected} <- contract["preserved_artifact_sha256"] do
      assert file_sha256(path) == expected
    end
  end

  defp file_sha256(path) do
    @root
    |> Path.join(path)
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
