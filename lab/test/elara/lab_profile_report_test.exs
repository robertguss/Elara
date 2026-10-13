defmodule Elara.Lab.ProfileReportTest do
  use ExUnit.Case, async: true

  alias Elara.Lab.ProfileReport

  # Decoded profile runs as a sweep records them. Window times are ms after t0;
  # the default is qualified: f1 is 10 s late.
  defp window(extra \\ %{}) do
    Map.merge(
      %{
        "a1" => 481_000,
        "n" => 481_500,
        "a2" => 482_000,
        "f1" => 610_000,
        "f2" => 611_000,
        "from" => 480_000,
        "to" => 600_000,
        "envelope_ms" => 130_000,
        "interior_ms" => 128_000
      },
      extra
    )
  end

  defp census(extra \\ %{}) do
    Map.merge(
      %{
        "started_ms" => 1_000,
        "ended_ms" => 1_250,
        "memory" => %{"total" => 900, "binary" => 300},
        "classes" => %{
          "session" => %{"pids" => 2, "process_bytes" => 100, "binary_exclusive_bytes" => 40},
          "task" => %{"pids" => 1, "process_bytes" => 10, "binary_exclusive_bytes" => 0}
        },
        "binary_shared" => %{"bytes" => 60, "pairs" => %{"session+task" => 60}},
        "binary_unique_total" => 100,
        "binary_memory" => 80,
        "unreconciled_binary_difference" => -20,
        "ets" => [
          %{"table" => "#Reference<1>", "class" => "session", "bytes" => 500},
          %{"table" => "Elixir.Registry", "class" => "unmeasured", "bytes" => 700}
        ],
        "ets_by_class" => %{"session" => 500, "unmeasured" => 700}
      },
      extra
    )
  end

  defp fun(class, module, function, arity, us, calls \\ 1, native \\ false),
    do: %{
      "class" => class,
      "module" => module,
      "function" => function,
      "arity" => arity,
      "calls" => calls,
      "us" => us,
      "native" => native
    }

  defp profile(extra \\ %{}) do
    Map.merge(
      %{
        "validity" => %{"status" => "qualified", "reasons" => ["lateness_over_5s"]},
        "window" => window(),
        "coverage" => %{
          "failures" => [],
          "births" => %{"before_n_census" => 1, "before_n_dead" => 2, "after_n" => 3},
          "receipt" => %{"present" => 4, "absent" => 5, "dead" => 6}
        },
        "classes" => %{
          "session" => %{"pids" => 2, "calls" => 30, "own_us" => 600},
          "task" => %{"pids" => 3, "calls" => 10, "own_us" => 200},
          "exec" => %{"pids" => 1, "calls" => 1, "own_us" => 0},
          "other" => %{"pids" => 9, "calls" => 5, "own_us" => 150},
          "client" => %{"pids" => 2, "calls" => 2, "own_us" => 40},
          "unclassified" => %{"pids" => 1, "calls" => 1, "own_us" => 10}
        },
        "functions" => [
          fun("session", "Elixir.Elara.Session", "handle_info", 2, 400, 20),
          # Tied at 200 us, listed out of identity order.
          fun("task", "Elixir.Elara.Session", "handle_info", 2, 200, 10),
          fun("session", "prim_file", "write", 2, 200, 10, true),
          fun("other", "prim_file", "write", 2, 150, 5, true),
          fun("client", "Elixir.Elara.Lab.Client", "loop", 1, 40, 2),
          fun("unclassified", "erlang", "apply", 2, 10, 1, true)
        ],
        "total_us" => 1_000,
        "unclassified_us" => 10,
        "unclassified_share" => 0.01,
        "memory" => %{
          "before_activation" => census(),
          "after_freeze" => census(%{"started_ms" => 9_000, "ended_ms" => 9_400})
        },
        "clients_started" => 2,
        "t0_ms" => 400,
        "collection_ms" => 77,
        "collection_failure" => nil
      },
      extra
    )
  end

  defp rep(profile, value \\ "10", seed \\ 42),
    do: %{
      "seed" => seed,
      "checks" => %{"a" => true},
      "incomplete" => nil,
      "complete" => true,
      "bounds" => %{},
      "profile" => profile,
      "sweep" => %{"value" => value, "seed" => seed, "exit_status" => 0}
    }

  defp invalid do
    profile(%{
      "validity" => %{
        "status" => "invalid",
        "reasons" => ["run_checks_failed", "lateness_over_5s"]
      }
    })
  end

  # The fallback of a failed collection: window and census, counters unavailable.
  defp fallback do
    %{
      "validity" => %{"status" => "invalid", "reasons" => ["collection_timeout"]},
      "window" => window(),
      "coverage" => %{"failures" => []},
      "counters" => "unavailable",
      "memory" => %{
        "before_activation" => census(),
        "after_freeze" =>
          census(%{
            "classification" => "unavailable",
            "classes" => %{
              "unavailable" => %{
                "pids" => 4,
                "process_bytes" => 22_240,
                "binary_exclusive_bytes" => 1_000
              }
            },
            "binary_shared" => %{"bytes" => 0, "pairs" => %{}},
            "ets" => [%{"table" => "#Reference<2>", "class" => "unavailable", "bytes" => 64}],
            "ets_by_class" => %{"unavailable" => 64}
          })
      },
      "clients_started" => 2,
      "collection_ms" => nil,
      "collection_failure" => nil
    }
  end

  defp not_activated,
    do: %{"validity" => %{"status" => "invalid", "reasons" => ["not_activated"]}}

  defp table([header | rows]) do
    for row <- rows, do: Map.new(Enum.zip(header, row))
  end

  @prefix ~w(value seed status validity_status validity_reasons ranked a1_late_ms a2_minus_a1_ms f1_late_ms f2_minus_f1_ms)

  describe "every table" do
    test "starts with the qualification prefix: validity, reasons and the four latenesses" do
      reps = [rep(profile()), rep(invalid(), "500")]

      for {name, rows} <- ProfileReport.tables(reps) do
        [header | _] = rows
        assert Enum.take(header, length(@prefix)) == @prefix, name
        [q, i] = rows |> table() |> Enum.uniq_by(& &1["value"])

        assert q["validity_status"] == "qualified" and q["validity_reasons"] == "lateness_over_5s"
        assert q["ranked"] == true
        assert q["a1_late_ms"] == 1_000 and q["a2_minus_a1_ms"] == 1_000
        assert q["f1_late_ms"] == 10_000 and q["f2_minus_f1_ms"] == 1_000, name

        assert i["validity_status"] == "invalid"
        assert i["validity_reasons"] == "run_checks_failed;lateness_over_5s"
        assert i["ranked"] == false
      end
    end

    test "names the five files" do
      assert ProfileReport.tables([rep(profile())]) |> Enum.map(&elem(&1, 0)) ==
               ~w(profile-windows.tsv profile-classes.tsv profile-functions.tsv profile-modules.tsv profile-memory.tsv)
    end

    test "ignores repetitions without a profile" do
      plain = rep(profile()) |> Map.put("profile", nil)
      assert Enum.all?(ProfileReport.tables([plain]), fn {_name, rows} -> length(rows) == 1 end)
    end
  end

  describe "windows" do
    test "one row per profile with timestamps, overlap, coverage and collection" do
      [row] = ProfileReport.windows([rep(profile())]) |> table()

      assert row["a1"] == 481_000 and row["f2"] == 611_000
      assert row["interior_ms"] == 128_000 and row["envelope_ms"] == 130_000
      # min(f1, to) - max(a2, from)
      assert row["overlap_ms"] == 600_000 - 482_000
      assert row["total_us"] == 1_000 and row["ranked_us"] == 800
      assert row["unclassified_us"] == 10 and row["unclassified_share"] == 0.01
      assert row["births_before_n_dead"] == 2 and row["receipt_dead"] == 6
      assert row["collection_ms"] == 77 and row["clients_started"] == 2
      assert row["counters"] == "available"
    end

    test "a fallback and an unactivated profile each keep a row, without inventing numbers" do
      [f, n] = ProfileReport.windows([rep(fallback()), rep(not_activated(), "500")]) |> table()

      assert f["counters"] == "unavailable" and f["a1"] == 481_000
      assert f["total_us"] == nil and f["ranked_us"] == nil
      assert n["validity_reasons"] == "not_activated"
      assert n["a1"] == nil and n["a1_late_ms"] == nil and n["counters"] == nil
    end
  end

  describe "classes" do
    test "kinds, pid counts and shares of traced and of ranked own time" do
      rows = ProfileReport.classes([rep(profile())]) |> table()
      by = Map.new(rows, &{&1["class"], &1})

      assert Enum.map(rows, & &1["class"]) ==
               ~w(exec session connection task client threads transport other unclassified) --
                 ~w(connection threads transport)

      assert by["session"]["kind"] == "ranked"
      assert by["other"]["kind"] == "descriptive"
      assert by["unclassified"]["kind"] == "unclassified"
      assert by["session"]["share_traced"] == 0.6 and by["session"]["share_ranked"] == 0.75
      assert by["other"]["pids"] == 9 and by["other"]["share_traced"] == 0.15
      assert by["other"]["share_ranked"] == nil
      assert by["session"]["counters"] == "available"
    end

    test "a fallback has one row with counters unavailable and null numbers, never zeros" do
      [row] = ProfileReport.classes([rep(fallback())]) |> table()

      assert row["class"] == "all" and row["counters"] == "unavailable"
      assert Enum.all?(~w(pids calls own_us share_traced share_ranked), &(row[&1] == nil))
    end
  end

  describe "functions and modules" do
    test "ranked classes only, ranked within class and across ranked classes, ties by full identity" do
      rows = ProfileReport.functions([rep(profile())]) |> table()

      assert Enum.map(
               rows,
               &{&1["class"], &1["function"], &1["rank_ranked"], &1["rank_in_class"]}
             ) == [
               {"session", "Elara.Session.handle_info/2", 1, 1},
               {"session", ":prim_file.write/2", 2, 2},
               {"task", "Elara.Session.handle_info/2", 3, 1}
             ]

      [first, second, _] = rows
      assert first["share_of_class"] == 400 / 600 and first["share_of_ranked"] == 0.5
      assert second["native"] == true
      assert first["us_per_s_approx"] == 400 / 128
      assert first["interior_ms"] == 128_000 and first["envelope_ms"] == 130_000
    end

    test "modules roll up by class and module" do
      rows = ProfileReport.modules([rep(profile())]) |> table()

      assert Enum.map(rows, &{&1["class"], &1["module"], &1["us"], &1["rank_ranked"]}) == [
               {"session", "Elara.Session", 400, 1},
               {"session", ":prim_file", 200, 2},
               {"task", "Elara.Session", 200, 3}
             ]

      assert hd(rows)["calls"] == 20 and hd(rows)["share_of_ranked"] == 0.5
    end

    test "a module sums its functions and flags any native part, with its own time" do
      mixed =
        profile(%{
          "functions" => [
            fun("session", "Elixir.Elara.Store", "save", 1, 300, 7),
            fun("session", "Elixir.Elara.Store", "nif_write", 2, 120, 5, true),
            fun("session", "Elixir.Elara.Session", "handle_info", 2, 100, 3)
          ]
        })

      rows = ProfileReport.modules([rep(mixed)]) |> table()
      [store, session] = rows

      assert store["module"] == "Elara.Store"
      assert store["us"] == 420 and store["calls"] == 12
      assert store["includes_native"] == true and store["native_us"] == 120
      assert session["includes_native"] == false and session["native_us"] == 0
    end

    test "an invalid profile keeps its rows with null ranks" do
      for export <- [&ProfileReport.functions/1, &ProfileReport.modules/1] do
        rows = export.([rep(invalid())]) |> table()
        assert length(rows) == 3
        assert Enum.all?(rows, &(&1["rank_ranked"] == nil and &1["rank_in_class"] == nil))
        assert Enum.all?(rows, &is_integer(&1["us"]))
      end
    end

    test "a fallback or an unactivated profile has no function or module rows" do
      reps = [rep(fallback()), rep(not_activated(), "500")]
      assert ProfileReport.functions(reps) |> tl() == []
      assert ProfileReport.modules(reps) |> tl() == []
    end
  end

  describe "memory" do
    test "both censuses with timestamps, class totals, each ETS table, binaries and VM categories" do
      rows = ProfileReport.memory([rep(profile())]) |> table()
      before = Enum.filter(rows, &(&1["census"] == "before_activation"))
      after_freeze = Enum.filter(rows, &(&1["census"] == "after_freeze"))

      assert hd(before)["census_started_ms"] == 1_000 and hd(before)["census_duration_ms"] == 250
      assert hd(before)["census_started_after_t0_ms"] == 600
      assert hd(after_freeze)["census_ended_after_t0_ms"] == 9_000
      assert hd(after_freeze)["census_ended_ms"] == 9_400
      assert Enum.all?(rows, &(&1["classification"] == "classified"))

      session = Enum.find(before, &(&1["kind"] == "class" and &1["class"] == "session"))
      assert session["pids"] == 2 and session["process_bytes"] == 100
      assert session["binary_exclusive_bytes"] == 40 and session["ets_bytes"] == 500

      task = Enum.find(before, &(&1["kind"] == "class" and &1["class"] == "task"))
      assert task["ets_bytes"] == 0

      unmeasured = Enum.find(before, &(&1["kind"] == "class" and &1["class"] == "unmeasured"))
      assert unmeasured["pids"] == nil and unmeasured["ets_bytes"] == 700

      tables = Enum.filter(before, &(&1["kind"] == "ets_table"))

      assert Enum.map(tables, &{&1["name"], &1["class"], &1["bytes"]}) == [
               {"#Reference<1>", "session", 500},
               {"Elixir.Registry", "unmeasured", 700}
             ]

      kinds = fn kind -> Enum.find(before, &(&1["kind"] == kind)) end
      assert kinds.("binary_shared")["bytes"] == 60

      assert kinds.("binary_pair")["name"] == "session+task" and
               kinds.("binary_pair")["bytes"] == 60

      assert kinds.("binary_unique_total")["bytes"] == 100
      assert kinds.("erlang_binary_memory")["bytes"] == 80
      assert kinds.("unreconciled_binary_difference")["bytes"] == -20

      vm =
        before |> Enum.filter(&(&1["kind"] == "vm_memory")) |> Map.new(&{&1["name"], &1["bytes"]})

      assert vm == %{"total" => 900, "binary" => 300}
    end

    test "an unavailable census keeps its measured holders under unavailable, not zero" do
      rows = ProfileReport.memory([rep(fallback())]) |> table()
      # Without a recorded t0, relative times are null, not guessed.
      assert Enum.all?(rows, &(&1["census_started_after_t0_ms"] == nil))
      after_freeze = Enum.filter(rows, &(&1["census"] == "after_freeze"))

      assert Enum.all?(after_freeze, &(&1["classification"] == "unavailable"))
      holder = Enum.find(after_freeze, &(&1["kind"] == "class"))
      assert holder["class"] == "unavailable" and holder["pids"] == 4
      assert holder["process_bytes"] == 22_240 and holder["ets_bytes"] == 64
      assert Enum.find(after_freeze, &(&1["kind"] == "ets_table"))["class"] == "unavailable"
    end

    test "a profile without a census has no memory rows" do
      assert ProfileReport.memory([rep(not_activated())]) |> tl() == []
    end
  end
end
