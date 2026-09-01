defmodule Elara.Benchmark.PreregistrationV3Test do
  use ExUnit.Case, async: true

  alias Elara.Benchmark.Compatibility

  @contract_path Path.expand(
                   "../../../docs/experiments/003-effect-receipt-v3-compatibility.json",
                   __DIR__
                 )
  @root Path.expand("../../..", __DIR__)

  setup_all do
    {:ok, contract} = Compatibility.load(@contract_path)
    %{contract: contract}
  end

  test "all 20 candidates and 40 corrected assignments match the frozen frame", %{
    contract: contract
  } do
    assert :ok = Compatibility.validate(contract)
    assert length(contract["candidates"]) == 20

    assert Enum.sum(
             Enum.map(contract["candidates"], fn candidate ->
               Enum.count([candidate["primary_fault"], candidate["secondary_fault"]])
             end)
           ) == 40

    source =
      @root
      |> Path.join("test/fixtures/benchmark/exp003/manifest.json")
      |> File.read!()
      |> JSON.decode!()
      |> then(&Map.new(&1["candidate_frame"], fn candidate -> {candidate["id"], candidate} end))

    for candidate <- contract["candidates"] do
      frozen = source[candidate["id"]]

      assert candidate["class"] == frozen["operation_class"]
      assert candidate["primary_fault"] == frozen["primary_fault"]

      if candidate["id"] not in ~w(P05 P06) do
        assert candidate["secondary_fault"] == frozen["secondary_fault"]
      end
    end

    assert candidate(contract, "P05")["secondary_fault"] == "F4"
    assert candidate(contract, "P06")["secondary_fault"] == "F2"
  end

  test "v2's impossible P05-F3 assignment is rejected", %{contract: contract} do
    changed = replace_secondary(contract, "P05", "F3")

    assert {:error, errors} = Compatibility.validate(changed)
    assert {:f3_requires_one_job_mutation, "P05"} in errors
  end

  test "v2's generic P06-F3 continuation contract is rejected", %{contract: contract} do
    changed = replace_secondary(contract, "P06", "F3")

    assert {:error, errors} = Compatibility.validate(changed)
    assert {:f3_requires_live_continuation, "P06"} in errors
  end

  test "the future beacon commitment and zero-exposure boundary are exact", %{
    contract: contract
  } do
    genesis = 1_595_431_050
    round = 6_427_122
    nominal_time = 1_788_244_680
    frozen_at = DateTime.from_iso8601("2026-09-01T06:12:46Z") |> elem(1)
    nominal = DateTime.from_unix!(nominal_time)

    assert genesis + (round - 1) * 30 == nominal_time
    assert DateTime.compare(frozen_at, nominal) == :lt

    assert contract["exposure"] == %{
             "v3_target_fault_rows" => 0,
             "v3_external_fault_rows" => 0,
             "v3_dogfood_runs" => 0,
             "v3_B_or_T_calculated" => false
           }
  end

  test "v1 and v2 evidence artifacts remain byte-identical", %{contract: contract} do
    for {path, expected} <- contract["preserved_artifact_sha256"] do
      assert file_sha256(path) == expected
    end
  end

  defp candidate(contract, id), do: Enum.find(contract["candidates"], &(&1["id"] == id))

  defp replace_secondary(contract, id, fault) do
    Map.update!(contract, "candidates", fn candidates ->
      Enum.map(candidates, fn candidate ->
        if candidate["id"] == id,
          do: Map.put(candidate, "secondary_fault", fault),
          else: candidate
      end)
    end)
  end

  defp file_sha256(path) do
    @root
    |> Path.join(path)
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
