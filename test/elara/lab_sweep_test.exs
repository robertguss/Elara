defmodule Elara.Lab.SweepTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Elara.Lab.Sweep

  defp tmp do
    dir = Path.join(System.tmp_dir!(), "sweep-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp arg(args, flag), do: args |> Enum.drop_while(&(&1 != flag)) |> Enum.at(1)

  defp sets(args),
    do:
      args
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn
        ["--set", pair] -> [pair]
        _ -> []
      end)

  # A fake child: writes the result line `result.(value, seed)` returns (a map,
  # raw text, or nil for none) and exits with `status.(value, seed)`.
  defp runner(result, status \\ fn _value, _seed -> 0 end) do
    test = self()

    fn args, env, log ->
      seed = String.to_integer(arg(args, "--seed"))

      value =
        sets(args)
        |> Enum.find_value(
          &(String.split(&1, "=")
            |> then(fn [k, v] -> k == "sessions" && v end))
        )

      send(test, {:child, args, env})
      File.write!(log, "child log\n")

      case result.(value, seed) do
        nil ->
          :ok

        line ->
          dir = Path.join(arg(args, "--results"), "fake")
          File.mkdir_p!(dir)
          text = if is_binary(line), do: line, else: JSON.encode!(line)
          File.write!(Path.join(dir, "#{seed}.jsonl"), text <> "\n")
      end

      status.(value, seed)
    end
  end

  defp line(value, seed, extra \\ %{}) do
    Map.merge(
      %{
        "scenario" => "fake",
        "seed" => seed,
        "params" => %{"sessions" => value},
        "checks" => %{"ok" => true},
        "incomplete" => nil,
        "complete" => true,
        "latency_ms" => %{"p95" => seed},
        "bounds" => %{"latency" => "holds", "throughput" => "holds"},
        "throughput" => %{"ratio" => 0.99}
      },
      extra
    )
  end

  defp sweep(runner, opts \\ []) do
    Sweep.run(
      "fake",
      Keyword.merge(
        [
          key: "sessions",
          values: ["10", "50"],
          n: 2,
          seed: 42,
          params: %{"turns" => "3"},
          dir: tmp(),
          runner: runner,
          fields: [{"latency_p95_ms", ["latency_ms", "p95"]}]
        ],
        opts
      )
    )
  end

  test "children run seed-major, one fresh process each, with their own TMPDIR" do
    result = sweep(runner(&line/2))
    assert result.ok

    calls = for _ <- 1..4, do: receive(do: ({:child, args, env} -> {args, env}))
    seeds_values = for {args, _} <- calls, do: {arg(args, "--seed"), Enum.sort(sets(args))}

    assert seeds_values == [
             {"42", ["sessions=10", "turns=3"]},
             {"42", ["sessions=50", "turns=3"]},
             {"43", ["sessions=10", "turns=3"]},
             {"43", ["sessions=50", "turns=3"]}
           ]

    assert Enum.all?(calls, fn {args, _} -> arg(args, "--n") == "1" end)
    tmps = for {_args, env} <- calls, do: Map.fetch!(Map.new(env), "TMPDIR")
    assert length(Enum.uniq(tmps)) == 4 and Enum.all?(tmps, &(Path.type(&1) == :absolute))
    assert Enum.all?(tmps, &File.dir?/1)

    assert [%{"sweep" => %{"index" => 0, "value" => "10", "seed" => 42, "exit_status" => 0}} | _] =
             result.repetitions

    assert Enum.map(result.repetitions, & &1["sweep"]["index"]) == [0, 1, 2, 3]
    assert Enum.all?(result.repetitions, &is_binary(&1["sweep"]["started_at"]))
  end

  test "a non-zero exit fails the sweep even with a passing result; later children still run" do
    result =
      sweep(runner(&line/2, fn value, seed -> if {value, seed} == {"10", 42}, do: 1, else: 0 end))

    refute result.ok
    assert length(result.repetitions) == 4
    assert hd(result.repetitions)["sweep"]["exit_status"] == 1
  end

  test "a missing or invalid result is recorded as an error repetition" do
    result =
      sweep(
        runner(fn
          "10", 42 -> nil
          "50", 42 -> "not json"
          "10", 43 -> JSON.encode!(["a list"])
          value, seed -> line(value, seed)
        end)
      )

    refute result.ok
    reasons = for %{"error" => %{"reason" => r}} <- result.repetitions, do: r
    assert reasons == ["missing_result", "invalid_result", "invalid_result"]
    assert result.summary["points"] |> hd() |> Map.fetch!("errors") == 2
  end

  test "a result for another scenario, seed or value, or with malformed fields, is invalid" do
    bad = %{
      {"10", 42} => %{"scenario" => "not-fake"},
      {"50", 42} => %{"seed" => 999},
      {"10", 43} => %{"params" => %{"sessions" => "11"}},
      {"50", 43} => %{"checks" => 42}
    }

    result = sweep(runner(fn v, s -> line(v, s, Map.get(bad, {v, s}, %{})) end))
    refute result.ok

    assert for(%{"error" => e} <- result.repetitions, do: e["detail"]) ==
             ["wrong_scenario", "wrong_seed", "wrong_value", "invalid_checks"]

    more = %{
      {"10", 42} => %{"latency_ms" => "oops"},
      {"50", 42} => %{"bounds" => %{"latency" => 1}},
      {"10", 43} => %{"throughput" => 3}
    }

    result = sweep(runner(fn v, s -> line(v, s, Map.get(more, {v, s}, %{})) end))

    assert for(%{"error" => e} <- result.repetitions, do: e["detail"]) ==
             ["invalid_field", "invalid_bounds", "invalid_field"]

    assert [%{"present" => 0}, %{"present" => 1}] = result.summary["points"]
  end

  test "a structured incomplete reason is invalid, and every artifact still serializes" do
    structured = %{"incomplete" => %{"reason" => "watchdog", "at_ms" => 120}}
    result = sweep(runner(fn v, s -> line(v, s, if(s == 42, do: structured, else: %{})) end))

    refute result.ok

    assert for(%{"error" => e} <- result.repetitions, do: e["detail"]) == [
             "invalid_incomplete",
             "invalid_incomplete"
           ]

    assert is_binary(JSON.encode!(result.summary))
    assert Enum.all?(result.repetitions, &is_binary(JSON.encode!(&1)))
  end

  test "an incomplete repetition fails the sweep; a failed hypothesis bound does not" do
    incomplete = sweep(runner(fn v, s -> line(v, s, %{"incomplete" => "watchdog"}) end))
    refute incomplete.ok

    bound_fails = %{"bounds" => %{"latency" => "fails", "throughput" => "holds"}}
    assert sweep(runner(fn v, s -> line(v, s, bound_fails) end)).ok
  end

  test "spreads come from JSON lines; non-numeric values are counted, not averaged" do
    result =
      sweep(
        runner(fn
          "10", 43 -> line("10", 43, %{"latency_ms" => %{"p95" => "infinity"}})
          value, seed -> line(value, seed)
        end)
      )

    [ten, fifty] = result.summary["points"]

    assert ten["fields"]["latency_p95_ms"] == %{
             "min" => 42,
             "mean" => 42.0,
             "max" => 42,
             "other" => %{"infinity" => 1}
           }

    assert fifty["fields"]["latency_p95_ms"] == %{"min" => 42, "mean" => 42.5, "max" => 43}
  end

  test "bounds: any failure fails, all expected repetitions must hold, else undetermined" do
    holds = %{"latency" => "holds"}
    fails = %{"latency" => "fails"}
    undetermined = %{"latency" => "undetermined"}

    assert Sweep.aggregate_bounds([holds, holds, holds], 3) == %{"latency" => "holds"}
    assert Sweep.aggregate_bounds([holds, fails, holds], 3) == %{"latency" => "fails"}

    assert Sweep.aggregate_bounds([holds, undetermined, holds], 3) == %{
             "latency" => "undetermined"
           }

    assert Sweep.aggregate_bounds([holds, holds], 3) == %{"latency" => "undetermined"}
  end

  test "saturation is the lowest value with a qualifying throughput failure, in any order" do
    ratio = fn r, bound ->
      %{"throughput" => %{"ratio" => r}, "bounds" => %{"throughput" => bound}}
    end

    result =
      sweep(
        runner(fn
          "500", s -> line("500", s, ratio.(0.5, "fails"))
          "200", s -> line("200", s, ratio.(0.9, "fails"))
          "10", s -> line("10", s, ratio.(0.5, "undetermined"))
          "20", s -> line("20", s, ratio.(0.95, "holds"))
        end),
        values: ["500", "10", "200", "20"]
      )

    assert result.summary["saturation_value"] == "200"
    assert Enum.sort(result.summary["ratio_below_threshold_values"]) == ["10", "200", "500"]
  end

  test "the sweep command rejects malformed, duplicate or conflicting values before running" do
    for {argv, message} <- [
          {["smoke"], ~r/--over expects/},
          {["smoke", "--over", "sessions="], ~r/--over expects/},
          {["smoke", "--over", "sessions=1,1"], ~r/distinct/},
          {["smoke", "--over", "sessions=1,"], ~r/must not be empty/},
          {["smoke", "--over", "sessions=1", "--n", "0"], ~r/at least 1/},
          {["smoke", "--over", "sessions=1", "--set", "sessions=2"], ~r/conflicts/},
          {["nope", "--over", "sessions=1"], ~r/unknown scenario/}
        ] do
      assert_raise Mix.Error, message, fn -> Mix.Tasks.Elara.Lab.run(["sweep" | argv]) end
    end
  end

  test "the sweep command runs each child in its own VM and TMPDIR and writes its artifacts" do
    root = tmp()

    sets =
      Enum.flat_map(
        [
          "turns=1",
          "ttft_ms=1",
          "deltas_per_sec=1000",
          "answer_deltas=2",
          "rate_limited_pct=0",
          "server_error_pct=0",
          "bash_ms=1"
        ],
        &["--set", &1]
      )

    capture_io(fn ->
      Mix.Tasks.Elara.Lab.run(
        ["sweep", "smoke", "--over", "sessions=1,2", "--n", "1", "--seed", "7", "--results", root] ++
          sets
      )
    end)

    [dir] = Path.wildcard(Path.join([root, "smoke", "*-sweep-sessions-seed7"]))

    repetitions =
      dir
      |> Path.join("repetitions.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    summary = dir |> Path.join("summary.json") |> File.read!() |> JSON.decode!()

    assert [%{"params" => %{"sessions" => "1"}}, %{"params" => %{"sessions" => "2"}}] =
             repetitions

    assert Enum.all?(repetitions, &(&1["sweep"]["exit_status"] == 0))

    # What the children themselves report: distinct VMs, each inside its own TMPDIR.
    pids = Enum.map(repetitions, & &1["vm"]["os_pid"])
    assert length(Enum.uniq(pids)) == 2 and System.pid() not in pids

    for repetition <- repetitions,
        path <- [repetition["vm"]["tmp_dir"], repetition["vm"]["run_dir"]] do
      assert String.starts_with?(path, repetition["sweep"]["tmp"] <> "/"), path
    end

    assert [%{"value" => "1", "present" => 1}, %{"value" => "2", "present" => 1}] =
             summary["points"]
  end
end
