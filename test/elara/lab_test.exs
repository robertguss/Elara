defmodule Elara.LabTest do
  use ExUnit.Case, async: false

  @params %{"sessions" => "2", "turns" => "3", "rate_limited_pct" => "20", "ttft_ms" => "5"}

  test "a seed reproduces the scenario's choices and a different seed changes them" do
    {:ok, [first]} = Elara.Lab.run("smoke", seed: 11, params: @params)
    {:ok, [again]} = Elara.Lab.run("smoke", seed: 11, params: @params)
    {:ok, [other]} = Elara.Lab.run("smoke", seed: 12, params: @params)

    assert first.choices_digest == again.choices_digest
    refute first.choices_digest == other.choices_digest
    assert first.completed_turns + first.failed_turns == 6
    assert %{count: count, p50: _, p95: _, p99: _} = first.latency_ms
    assert count > 0
  end

  test "repetitions use consecutive seeds and isolated state roots" do
    home = Application.fetch_env!(:elara, :sessions_root)
    {:ok, results} = Elara.Lab.run("smoke", seed: 3, n: 2, params: @params)

    assert Enum.map(results, & &1.seed) == [3, 4]
    assert Application.fetch_env!(:elara, :sessions_root) == home

    summary = Elara.Lab.summarize(results)
    assert summary.repetitions == 2
    assert length(summary.choices_digests) == 2
  end

  test "results are written as one JSON line per repetition" do
    root = Path.join(System.tmp_dir!(), "lab-results-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, results} = Elara.Lab.run("smoke", seed: 5, n: 2, params: @params)

    path = Elara.Lab.write_results(root, results)
    lines = path |> File.read!() |> String.split("\n", trim: true)

    assert [%{"seed" => 5, "scenario" => "smoke"}, %{"seed" => 6}] =
             Enum.map(lines, &JSON.decode!/1)
  end

  test "unknown scenarios are rejected with the known list" do
    assert {:error, {:unknown_scenario, "nope", ["smoke"]}} = Elara.Lab.run("nope", seed: 1)
  end

  test "percentiles use nearest rank" do
    assert %{count: 100, p50: 50, p95: 95, p99: 99, max: 100} =
             Elara.Lab.percentiles(Enum.to_list(1..100))

    assert Elara.Lab.percentiles([]) == nil
  end
end
