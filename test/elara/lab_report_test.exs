defmodule Elara.Lab.ReportTest do
  use ExUnit.Case, async: true

  alias Elara.Lab.{Report, Sweep}

  @fields [
    {"latency_p95_ms", ["latency_ms", "p95"]},
    {"throughput_ratio", ["throughput", "ratio"]}
  ]

  # A decoded sweep repetition: a clean measurement unless `extra` says otherwise.
  defp rep(value, seed, extra \\ %{}) do
    Map.merge(
      %{
        "seed" => seed,
        "checks" => %{"a" => true, "b" => true},
        "incomplete" => nil,
        "complete" => true,
        "latency_ms" => %{"p95" => 9},
        "throughput" => %{"ratio" => 0.98},
        "bounds" => %{"latency" => "holds", "memory" => "fails", "throughput" => "holds"},
        "sweep" => %{"value" => value, "seed" => seed, "exit_status" => 0}
      },
      extra
    )
  end

  defp error(value, seed, reason \\ "missing_result"),
    do: %{
      "sweep" => %{"value" => value, "seed" => seed, "exit_status" => 1},
      "error" => %{"reason" => reason, "detail" => "no result file"}
    }

  test "status is clean exactly when the sweep counts a clean measurement, else names each problem" do
    cases = [
      {rep("10", 42), "clean"},
      {error("10", 42), "error:missing_result;exit:1"},
      {rep("10", 42, %{"sweep" => %{"value" => "10", "seed" => 42, "exit_status" => 2}}),
       "exit:2"},
      {rep("10", 42, %{"checks" => %{"b" => false, "a" => false}}), "checks:a,b"},
      {rep("10", 42, %{"retained_dir" => "/tmp/x"}), "retained"},
      {rep("10", 42, %{"incomplete" => "guard_memory", "complete" => false}),
       "incomplete:guard_memory;not_complete"},
      {rep("10", 42, %{"complete" => false}), "not_complete"},
      {rep("10", 42, %{
         "sweep" => %{"value" => "10", "seed" => 42, "exit_status" => 1},
         "checks" => %{"a" => false},
         "retained_dir" => "/tmp/x"
       }), "exit:1;checks:a;retained"}
    ]

    for {repetition, status} <- cases do
      assert Report.status(repetition) == status
      assert Report.status(repetition) == "clean" == Sweep.ok?(repetition)
    end
  end

  test "repetition rows carry status, bounds and fields; an error row is undetermined" do
    [header | rows] = Report.repetition_rows([rep("10", 42), error("50", 42)], @fields)

    assert header ==
             ~w(value seed status latency_bound memory_bound throughput_bound latency_p95_ms throughput_ratio)

    assert rows == [
             ["10", 42, "clean", "holds", "fails", "holds", 9, 0.98],
             [
               "50",
               42,
               "error:missing_result;exit:1",
               "undetermined",
               "undetermined",
               "undetermined",
               "error",
               "error"
             ]
           ]
  end

  test "an absent field is null, not an error" do
    [_header, row] = Report.repetition_rows([rep("10", 42, %{"latency_ms" => nil})], @fields)
    assert Enum.at(row, 6) == nil
  end

  test "points aggregate bounds as the sweep does and report cleanliness separately" do
    dirty = %{"sweep" => %{"value" => "50", "seed" => 0, "exit_status" => 1}}

    repetitions =
      [rep("10", 42), rep("10", 43), rep("10", 44)] ++
        for(seed <- 42..44, do: rep("50", seed, put_in(dirty["sweep"]["seed"], seed))) ++
        [error("200", 42), error("200", 43), rep("200", 44)] ++
        for(seed <- 42..44, do: error("1000", seed))

    [header | rows] = Report.point_rows(repetitions, ["10", "50", "200", "1000"], 3)

    assert header == ~w(value expected present clean errors latency memory throughput)

    assert rows == [
             ["10", 3, 3, 3, 0, "holds", "fails", "holds"],
             # Three holds with non-zero exits still aggregate to holds; clean says otherwise.
             ["50", 3, 3, 0, 0, "holds", "fails", "holds"],
             ["200", 3, 1, 1, 2, "undetermined", "fails", "undetermined"],
             # An all-error point has no named bounds at all.
             ["1000", 3, 0, 0, 3, "undetermined", "undetermined", "undetermined"]
           ]

    point = fn value -> Enum.find(rows, &(hd(&1) == value)) end

    for %{"value" => value, "bounds" => bounds} <-
          Sweep.summarize(repetitions, "sessions", ["10", "50", "200", "1000"], 3, @fields)[
            "points"
          ],
        {name, verdict} <- bounds do
      index = Enum.find_index(header, &(&1 == name))
      assert Enum.at(point.(value), index) == verdict
    end
  end

  describe "profile runs" do
    # A profile run records no verdict: empty bounds and a profile.
    defp profiled(value, seed),
      do:
        rep(value, seed, %{"bounds" => %{}, "profile" => %{"validity" => %{"status" => "valid"}}})

    test "repetition and point rows say no_verdict for profile runs, not undetermined" do
      reps = [profiled("10", 42), rep("50", 42)]
      [_header, p, plain] = Report.repetition_rows(reps, @fields)

      assert Enum.slice(p, 3, 3) == ~w(no_verdict no_verdict no_verdict)
      assert Enum.slice(plain, 3, 3) == ~w(holds fails holds)

      [_header, p10, p50] = Report.point_rows(reps, ["10", "50"], 1)
      assert Enum.slice(p10, 5, 3) == ~w(no_verdict no_verdict no_verdict)
      assert Enum.slice(p50, 5, 3) == ~w(holds fails holds)
    end

    test "a value mixing profile and verdict-bearing runs aggregates only as the sweep does" do
      [_header, row] = Report.point_rows([profiled("10", 42), rep("10", 43)], ["10"], 2)
      assert Enum.slice(row, 5, 3) == ~w(undetermined fails undetermined)
    end

    test "profile runs never enter ratio_below_threshold_values" do
      low = %{"throughput" => %{"ratio" => 0.2}}

      summary =
        Sweep.summarize(
          [Map.merge(profiled("10", 42), low), Map.merge(rep("50", 42), low)],
          "sessions",
          ["10", "50"],
          1,
          @fields
        )

      assert summary["ratio_below_threshold_values"] == ["50"]
    end
  end

  describe "compare" do
    defp compare(base, other, opts \\ []) do
      [header | rows] = Report.compare(base, other, @fields, opts)

      assert header ==
               ~w(value seed base_status other_status field base other difference reason)

      rows
    end

    test "subtracts only numbers; keeps both raw values and says why a difference is unavailable" do
      base = [
        rep("10", 42, %{"latency_ms" => %{"p95" => 9}, "throughput" => %{"ratio" => 0.98}}),
        rep("50", 42, %{"latency_ms" => %{"p95" => "infinity"}, "throughput" => %{"ratio" => nil}})
      ]

      other = [
        rep("10", 42, %{"latency_ms" => %{"p95" => 12}, "throughput" => %{"ratio" => 0.91}}),
        rep("50", 42, %{"latency_ms" => %{"p95" => 30}, "throughput" => %{"ratio" => 0.9}})
      ]

      assert compare(base, other) == [
               ["10", 42, "clean", "clean", "latency_p95_ms", 9, 12, 3, ""],
               ["10", 42, "clean", "clean", "throughput_ratio", 0.98, 0.91, 0.91 - 0.98, ""],
               [
                 "50",
                 42,
                 "clean",
                 "clean",
                 "latency_p95_ms",
                 "infinity",
                 30,
                 "unavailable",
                 "nonnumeric"
               ],
               [
                 "50",
                 42,
                 "clean",
                 "clean",
                 "throughput_ratio",
                 nil,
                 0.9,
                 "unavailable",
                 "nonnumeric"
               ]
             ]
    end

    test "a difference is the exact arithmetic, however small or mixed its operands" do
      base = [rep("10", 42, %{"latency_ms" => %{"p95" => 1}, "throughput" => %{"ratio" => 0.95}})]

      other = [
        rep("10", 42, %{
          "latency_ms" => %{"p95" => 1.0000001},
          "throughput" => %{"ratio" => 0.95 + 4.5e-8}
        })
      ]

      assert [
               [_, _, _, _, "latency_p95_ms", 1, 1.0000001, latency, ""],
               [_, _, _, _, "throughput_ratio", 0.95, _, throughput, ""]
             ] = compare(base, other)

      assert latency == 1.0000001 - 1 and latency != 0
      assert throughput == 0.95 + 4.5e-8 - 0.95 and throughput > 0
    end

    test "status qualifies a numeric difference without suppressing it" do
      base = [rep("10", 42, %{"retained_dir" => "/tmp/x"})]

      other = [
        rep("10", 42, %{
          "incomplete" => "guard_lag",
          "complete" => false,
          "latency_ms" => %{"p95" => 40}
        })
      ]

      assert [
               [
                 "10",
                 42,
                 "retained",
                 "incomplete:guard_lag;not_complete",
                 "latency_p95_ms",
                 9,
                 40,
                 31,
                 ""
               ]
               | _
             ] = compare(base, other)
    end

    test "every key from either side stays, with missing and error sides named" do
      base = [rep("10", 42), rep("50", 42), error("200", 42)]
      other = [rep("10", 42), rep("200", 42), rep("1000", 42)]

      rows = compare(base, other, seed: 42)
      latency = for [_, _, _, _, "latency_p95_ms" | _] = row <- rows, do: row

      assert latency == [
               ["10", 42, "clean", "clean", "latency_p95_ms", 9, 9, 0, ""],
               [
                 "50",
                 42,
                 "clean",
                 "missing",
                 "latency_p95_ms",
                 9,
                 "missing",
                 "unavailable",
                 "other_missing"
               ],
               [
                 "200",
                 42,
                 "error:missing_result;exit:1",
                 "clean",
                 "latency_p95_ms",
                 "error",
                 9,
                 "unavailable",
                 "base_error"
               ],
               [
                 "1000",
                 42,
                 "missing",
                 "clean",
                 "latency_p95_ms",
                 "missing",
                 9,
                 "unavailable",
                 "base_missing"
               ]
             ]

      [row] =
        for [_, _, _, _, "latency_p95_ms" | _] = row <- compare(other, base),
            hd(row) == "200",
            do: row

      assert Enum.at(row, 8) == "other_error"
    end

    test "pairs by value and seed; the seed filter drops other seeds; values sort numerically" do
      base = for value <- ["1000", "200", "10", "50"], seed <- [42, 43], do: rep(value, seed)
      other = for value <- ["10", "50", "200", "1000"], do: rep(value, 42)

      all = compare(base, other)

      assert Enum.uniq(for [v, s | _] <- all, do: {v, s}) ==
               for(v <- ["10", "50", "200", "1000"], s <- [42, 43], do: {v, s})

      unpaired = for [_, 43, _, status | _] <- all, do: status
      assert length(unpaired) == 8 and Enum.all?(unpaired, &(&1 == "missing"))

      filtered = compare(base, other, seed: 42)

      assert Enum.uniq(for [v, s | _] <- filtered, do: {v, s}) ==
               for(v <- ["10", "50", "200", "1000"], do: {v, 42})
    end

    test "non-numeric values keep the base sweep's order" do
      base = [rep("b", 1), rep("a", 1)]
      other = [rep("c", 1), rep("a", 1)]
      assert Enum.uniq(for [v | _] <- compare(base, other), do: v) == ["b", "a", "c"]
    end
  end

  test "tsv encodes numbers, null, maps and text safely, one line per row" do
    text = Report.tsv([["a", "b"], [1, 0.1], [nil, "x\ty\nz"], [%{"k" => 1}, 1.0e-7]])
    assert text == "a\tb\n1\t0.1\nnull\tx y z\n{\"k\":1}\t1.0e-7\n"
  end

  describe "mix elara.lab report and compare" do
    import ExUnit.CaptureIO

    defp tmp do
      dir = Path.join(System.tmp_dir!(), "report-test-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      dir
    end

    # A sweep directory as `mix elara.lab sweep` leaves it.
    defp sweep_dir(root, scenario, name, repetitions, key \\ "sessions") do
      dir = Path.join([root, scenario, name])
      File.mkdir_p!(dir)
      values = repetitions |> Enum.map(& &1["sweep"]["value"]) |> Enum.uniq()
      n = repetitions |> Enum.map(& &1["sweep"]["seed"]) |> Enum.uniq() |> length()

      File.write!(
        Path.join(dir, "repetitions.jsonl"),
        Enum.map(repetitions, &[JSON.encode!(&1), "\n"])
      )

      summary = %{
        "key" => key,
        "repetitions" => n,
        "points" => Enum.map(values, &%{"value" => &1})
      }

      File.write!(Path.join(dir, "summary.json"), JSON.encode!(summary))
      dir
    end

    defp lines(path), do: path |> File.read!() |> String.split("\n", trim: true)
    defp lab(argv), do: capture_io(fn -> Mix.Tasks.Elara.Lab.run(argv) end)

    test "report writes one row per repetition and per value into the sweep directory" do
      reps = for value <- ["10", "50"], seed <- [42, 43], do: rep(value, seed)
      dir = sweep_dir(tmp(), "concurrency", "1-sweep-sessions-seed42", reps ++ [error("200", 42)])
      lab(["report", dir])

      [header | rows] = lines(Path.join(dir, "report.tsv"))
      labels = Enum.map(Elara.Lab.Scenarios.Concurrency.curve_fields(), &elem(&1, 0))

      assert String.split(header, "\t") ==
               ~w(value seed status latency_bound memory_bound throughput_bound) ++ labels

      assert length(rows) == 5
      assert "200\t42\terror:missing_result;exit:1\tundetermined" <> _ = List.last(rows)

      assert lines(Path.join(dir, "points.tsv")) == [
               "value\texpected\tpresent\tclean\terrors\tlatency\tmemory\tthroughput",
               "10\t2\t2\t2\t0\tholds\tfails\tholds",
               "50\t2\t2\t2\t0\tholds\tfails\tholds",
               "200\t2\t0\t0\t1\tundetermined\tundetermined\tundetermined"
             ]
    end

    test "compare writes the paired rows into the other sweep's directory" do
      root = tmp()

      base =
        sweep_dir(
          root,
          "concurrency",
          "1-sweep-sessions-seed42",
          for(v <- ["10", "50"], s <- [42, 43], do: rep(v, s))
        )

      other =
        sweep_dir(root, "concurrency", "2-sweep-sessions-seed42", [
          rep("10", 42, %{"latency_ms" => %{"p95" => 11}}),
          error("50", 42)
        ])

      lab(["compare", base, other, "--seed", "42", "--fields", "latency_p95_ms,throughput_ratio"])

      assert lines(Path.join(other, "compare-1-sweep-sessions-seed42.tsv")) == [
               "value\tseed\tbase_status\tother_status\tfield\tbase\tother\tdifference\treason",
               "10\t42\tclean\tclean\tlatency_p95_ms\t9\t11\t2\t",
               "10\t42\tclean\tclean\tthroughput_ratio\t0.98\t0.98\t0.0\t",
               "50\t42\tclean\terror:missing_result;exit:1\tlatency_p95_ms\t9\terror\tunavailable\tother_error",
               "50\t42\tclean\terror:missing_result;exit:1\tthroughput_ratio\t0.98\terror\tunavailable\tother_error"
             ]
    end

    test "compare refuses sweeps of different scenarios or keys, and unknown fields" do
      root = tmp()
      base = sweep_dir(root, "concurrency", "1-sweep-sessions-seed42", [rep("10", 42)])
      smoke = sweep_dir(root, "smoke", "2-sweep-sessions-seed42", [rep("10", 42)])
      turns = sweep_dir(root, "concurrency", "3-sweep-turns-seed42", [rep("10", 42)], "turns")
      other = sweep_dir(root, "concurrency", "4-sweep-sessions-seed42", [rep("10", 42)])

      assert_raise Mix.Error, ~r/scenario/, fn -> lab(["compare", base, smoke]) end
      assert_raise Mix.Error, ~r/key/, fn -> lab(["compare", base, turns]) end

      assert_raise Mix.Error, ~r/unknown field/, fn ->
        lab(["compare", base, other, "--fields", "latency_p95_ms,latency_p999_ms"])
      end

      refute File.exists?(Path.join(other, "compare-1-sweep-sessions-seed42.tsv"))
    end

    test "report also writes the five profile tables when a repetition carries a profile" do
      profile = %{
        "validity" => %{"status" => "valid", "reasons" => []},
        "window" => %{
          "a1" => 480_100,
          "n" => 480_200,
          "a2" => 480_300,
          "f1" => 600_100,
          "f2" => 600_200,
          "from" => 480_000,
          "to" => 600_000,
          "envelope_ms" => 120_100,
          "interior_ms" => 119_800
        },
        "classes" => %{"session" => %{"pids" => 1, "calls" => 2, "own_us" => 5}},
        "functions" => [
          %{
            "class" => "session",
            "module" => "Elixir.Elara.Session",
            "function" => "f",
            "arity" => 0,
            "calls" => 2,
            "us" => 5,
            "native" => false
          }
        ],
        "total_us" => 5
      }

      reps = [rep("10", 42, %{"bounds" => %{}, "profile" => profile})]
      dir = sweep_dir(tmp(), "concurrency", "1-sweep-sessions-seed42", reps)
      lab(["report", dir])

      for name <- Elara.Lab.ProfileReport.tables(reps) |> Enum.map(&elem(&1, 0)) do
        assert [_header | _rows] = lines(Path.join(dir, name)), name
      end

      [_header, row] = lines(Path.join(dir, "profile-functions.tsv"))
      assert row =~ "Elara.Session.f/0"
    end

    test "report writes no profile tables for a sweep without profiles" do
      dir = sweep_dir(tmp(), "concurrency", "1-sweep-sessions-seed42", [rep("10", 42)])
      lab(["report", dir])
      assert Path.wildcard(Path.join(dir, "profile-*.tsv")) == []
    end

    test "report refuses a directory that is not a known scenario's sweep" do
      root = tmp()

      assert_raise Mix.Error, ~r/unknown scenario/, fn ->
        lab(["report", sweep_dir(root, "nope", "1-sweep-sessions-seed42", [rep("10", 42)])])
      end

      assert_raise Mix.Error, ~r/cannot read .*absent/, fn ->
        lab(["report", Path.join([root, "concurrency", "absent"])])
      end
    end
  end
end
