defmodule Elara.LabTest do
  use ExUnit.Case, async: false

  defmodule Checked do
    @behaviour Elara.Lab
    @impl true
    def run(%{seed: seed, dir: dir}) do
      File.write!(Path.join(dir, "evidence"), "kept")
      send(Process.whereis(:lab_test), {:dir, seed, dir})
      %{checks: %{even_seed: rem(seed, 2) == 0, always: true}, cleanup_confirmed: seed != 3}
    end
  end

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

  test "real mode refuses a request cap below one request per turn, before any network use" do
    params = %{"sessions" => "2", "turns" => "2"}

    assert_raise RuntimeError, ~r/below one request per turn/, fn ->
      Elara.Lab.run("smoke", seed: 1, provider: :real, max_requests: 3, params: params)
    end

    assert_raise RuntimeError, ~r/requires --max-requests/, fn ->
      Elara.Lab.run("smoke", seed: 1, provider: :real, params: params)
    end
  end

  test "unknown scenarios are rejected with the known list" do
    assert {:error,
            {:unknown_scenario, "nope",
             ["concurrent_jobs", "provider_fault", "session_crash", "smoke"]}} =
             Elara.Lab.run("nope", seed: 1)
  end

  test "failed checks are reported and uncertain cleanup keeps the directory and stops" do
    Process.register(self(), :lab_test)
    {:ok, results} = Elara.Lab.run(Checked, seed: 2, n: 3)

    assert Enum.map(results, & &1.seed) == [2, 3]
    assert Enum.map(results, &Elara.Lab.failed_checks/1) == [[], [:even_seed]]
    assert_received {:dir, 2, cleaned}
    assert_received {:dir, 3, kept}
    refute_received {:dir, 4, _}
    refute File.exists?(cleaned)
    on_exit(fn -> File.rm_rf!(kept) end)
    assert File.read!(Path.join(kept, "evidence")) == "kept"
    assert List.last(results).retained_dir == kept

    summary = Elara.Lab.summarize(results)
    assert summary.failed_checks == %{even_seed: 1}
    assert summary.retained_dirs == [kept]
  end

  test "percentiles use nearest rank" do
    assert %{count: 100, p50: 50, p95: 95, p99: 99, max: 100} =
             Elara.Lab.percentiles(Enum.to_list(1..100))

    assert Elara.Lab.percentiles([]) == nil
  end
end
