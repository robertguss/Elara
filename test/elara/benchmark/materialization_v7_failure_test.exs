defmodule Elara.Benchmark.MaterializationV7FailureTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @fixture_root Path.join(@root, "test/fixtures/benchmark/exp003-v7")

  @artifact_sha256 %{
    "beacon/api.drand.sh.json" =>
      "6e4f05a476f1ce700d250adc243e360e1b9138d9428f829341310c1f08a1518b",
    "beacon/drand.cloudflare.com.json" =>
      "6e4f05a476f1ce700d250adc243e360e1b9138d9428f829341310c1f08a1518b",
    "beacon/verification.json" =>
      "bd5f1c7be2612e9832e8eb51bebee5cd29cf62d621b566f26425804621b43d11",
    "beacon/verify.cjs" => "7fc21b05daa29aa520964eebd1bd091c0a13b4ff5d1ee16f2d1908be9d99c066",
    "beacon/package.json" => "7674a6925d4d822771fbca3118c78208e20a8607bee8159aefc90e149c0d8291",
    "../../../../priv/benchmark/materialize_exp003_v7.exs" =>
      "c7553203e057a15fbe6fe18bb41f8f1edf6005582e1567e19727952f81af684c"
  }

  test "preserves the one verified committed beacon" do
    api = read_json("beacon/api.drand.sh.json")
    cloudflare = read_json("beacon/drand.cloudflare.com.json")
    verification = read_json("beacon/verification.json")

    assert api == cloudflare
    assert api["round"] == 6_429_446

    assert api["randomness"] ==
             "04a354a886b685477dd10dc439ded5fd66202f1e4d7077ac1b019447f3c75049"

    assert verification["verified"]
    assert verification["client"] == "drand-client@1.4.2"
    assert Enum.map(verification["results"], &Map.drop(&1, ["url"])) == [api, api]

    assert sha256(Base.decode16!(api["signature"], case: :mixed)) == api["randomness"]
  end

  test "locks the failed source and all raw evidence bytes" do
    for {relative_path, expected} <- @artifact_sha256 do
      assert relative_path |> then(&Path.join(@fixture_root, &1)) |> file_sha256() == expected
    end

    source = File.read!(Path.join(@root, "priv/benchmark/materialize_exp003_v7.exs"))
    base = File.read!(Path.join(@root, "priv/benchmark/materialize_exp003_v6.exs"))
    assert base =~ "preflight_exp003_v6.exs"
    refute source =~ ~s[String.replace("exp003_v6", "exp003_v7")]
  end

  test "preserves the fail-closed absence of every materialized output" do
    refute File.exists?(Path.join(@fixture_root, "manifest.json"))
    refute File.exists?(Path.join(@fixture_root, "dogfood-plan.json"))
    refute File.exists?(Path.join(@fixture_root, "external-adapter-equivalence.json"))
  end

  defp read_json(path),
    do: path |> then(&Path.join(@fixture_root, &1)) |> File.read!() |> JSON.decode!()

  defp file_sha256(path), do: path |> File.read!() |> sha256()
  defp sha256(value), do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
