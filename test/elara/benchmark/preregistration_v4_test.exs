defmodule Elara.Benchmark.PreregistrationV4Test do
  use ExUnit.Case, async: true

  alias Elara.Benchmark.Compatibility

  @root Path.expand("../../..", __DIR__)
  @contract_path Path.join(
                   @root,
                   "docs/experiments/003-effect-receipt-v4-compatibility.json"
                 )
  @preregistration_path Path.join(
                          @root,
                          "docs/experiments/003-effect-receipt-confirmatory-preregistration-v4.md"
                        )

  setup_all do
    {:ok, contract} = Compatibility.load(@contract_path)
    %{contract: contract}
  end

  test "preserves the corrected 20-candidate and 40-assignment contract", %{
    contract: contract
  } do
    assert :ok = Compatibility.validate(contract)
    assert length(contract["candidates"]) == 20

    assert contract["candidates"]
           |> Enum.flat_map(&[&1["primary_fault"], &1["secondary_fault"]])
           |> length() == 40

    v3 =
      @root
      |> Path.join("docs/experiments/003-effect-receipt-v3-compatibility.json")
      |> File.read!()
      |> JSON.decode!()

    assert contract["fault_contracts"] == v3["fault_contracts"]
    assert contract["candidates"] == v3["candidates"]
  end

  test "commits the exact future beacon and command-complete boundary", %{contract: contract} do
    genesis = 1_595_431_050
    round = 6_428_786
    nominal_time = 1_788_294_600
    preregistration = File.read!(@preregistration_path)

    assert genesis + (round - 1) * 30 == nominal_time
    assert preregistration =~ "priv/benchmark/run_internal_confirmatory.exs"
    assert preregistration =~ "qualify <v4-manifest>"
    assert preregistration =~ "execute <v4-manifest>"
    assert preregistration =~ "replay <v4-manifest>"

    assert contract["exposure"] == %{
             "v4_target_fault_rows" => 0,
             "v4_no_fault_timing_runs" => 0,
             "v4_external_fault_rows" => 0,
             "v4_dogfood_runs" => 0,
             "v4_B_or_T_calculated" => false
           }
  end

  test "all preserved v3 artifacts remain byte-identical", %{contract: contract} do
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
