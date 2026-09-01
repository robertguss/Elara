defmodule Elara.Benchmark.MaterializationV5FailureTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @fixture_root Path.join(@root, "test/fixtures/benchmark/exp003-v5")
  @chain_hash "8990e7a9aaed2ffed73dbd7092123d6f289930540d7651336225dc172e51b2ce"
  @randomness "c9e677cb38d693e56180a238c080e7559905ceaf646cb9dfc1e84b7c2d89af58"
  @frozen_commit "bc1444aacc773b9e7009063e7f40a48f51f0884d"
  @seed "9ddb3981ca995df34afee6c37d614726c1cec9a06317a3dab85ab75a31885468"
  @selected ~w(P02 S03 P03 W03 S04 W07 W02 S02 P07 W01 P06 S01)

  test "preserves the verified v5 beacon and deterministic failed selection" do
    api = read_json("beacon/api.drand.sh.json")
    cloudflare = read_json("beacon/drand.cloudflare.com.json")
    verification = read_json("beacon/verification.json")

    assert api == cloudflare
    assert api["round"] == 6_428_936
    assert api["randomness"] == @randomness
    assert verification["verified"]
    assert verification["client"] == "drand-client@1.4.2"
    assert Enum.map(verification["results"], &Map.drop(&1, ["url"])) == [api, api]
    assert sha256(Base.decode16!(api["signature"], case: :mixed)) == @randomness

    material =
      "elara:exp-003:er3:fnd-2:v5\0" <>
        @chain_hash <> ":6428936:" <> @randomness <> ":" <> @frozen_commit

    assert sha256(material) == @seed
    assert selected_ids(Base.decode16!(@seed, case: :mixed)) == @selected
    assert hd(@selected) == "P02"
  end

  test "freezes the 19-of-20 constructor defect without materialized outputs" do
    materializer = File.read!(Path.join(@root, "priv/benchmark/materialize_exp003_v3.exs"))
    source = read_json("manifest.json", "test/fixtures/benchmark/exp003")

    covered =
      source["tasks"]
      |> Enum.map(& &1["id"])
      |> Kernel.++(Enum.map(source["adapter_equivalence_fixtures"], & &1["template_id"]))
      |> Kernel.++(~w(W02 W04 W06 P03 P05 P06))
      |> MapSet.new()

    candidates = MapSet.new(Enum.map(source["candidate_frame"], & &1["id"]))

    assert MapSet.difference(candidates, covered) == MapSet.new(["P02"])
    refute materializer =~ "defp new_task(\"P02\""

    refute File.exists?(Path.join(@fixture_root, "manifest.json"))
    refute File.exists?(Path.join(@fixture_root, "dogfood-plan.json"))
    refute File.exists?(Path.join(@fixture_root, "external-adapter-equivalence.json"))
  end

  test "beacon artifacts remain exact" do
    assert file_sha256("beacon/api.drand.sh.json") ==
             "24898a55a44ab5b9146cd6e745db0d0a688ebca8261695180bcc55015dd98a04"

    assert file_sha256("beacon/drand.cloudflare.com.json") ==
             "0ab8759a9caa6dabd507ae39d88bdc955ae935f63c21b8996a6436807ff0a60b"

    assert file_sha256("beacon/verification.json") ==
             "26656c573f96abceb9a3b55eb0e933313b352974e42757ec5c0e5bcb37d2c1d1"
  end

  defp selected_ids(seed) do
    source = read_json("manifest.json", "test/fixtures/benchmark/exp003")
    compatibility = read_json("003-effect-receipt-v5-compatibility.json", "docs/experiments")
    profiles = Map.new(compatibility["candidates"], &{&1["id"], &1})

    candidates =
      Enum.map(source["candidate_frame"], fn candidate ->
        profile = profiles[candidate["id"]]

        candidate
        |> Map.put("primary_fault", profile["primary_fault"])
        |> Map.put("order_key", sha256(seed <> <<0>> <> candidate["id"]))
      end)

    typed =
      for operation <- ~w(write patch), fault <- ~w(F1 F2 F3 F4) do
        candidates
        |> Enum.filter(&(&1["operation_class"] == operation and &1["primary_fault"] == fault))
        |> Enum.min_by(& &1["order_key"])
        |> Map.fetch!("id")
      end

    (typed ++ ~w(S01 S02 S03 S04))
    |> Enum.sort_by(fn id -> Enum.find(candidates, &(&1["id"] == id))["order_key"] end)
  end

  defp read_json(relative, root \\ "test/fixtures/benchmark/exp003-v5") do
    @root |> Path.join(root) |> Path.join(relative) |> File.read!() |> JSON.decode!()
  end

  defp file_sha256(relative), do: @fixture_root |> Path.join(relative) |> File.read!() |> sha256()
  defp sha256(value), do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
