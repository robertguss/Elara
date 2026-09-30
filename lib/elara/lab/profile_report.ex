defmodule Elara.Lab.ProfileReport do
  @moduledoc """
  Tables over recorded profile runs (note 003's attribution): windows, classes,
  functions, modules and memory censuses. Every row carries its profile's
  validity and latenesses; an unranked profile keeps its rows with null ranks.
  It orders by own time and judges no bottleneck.
  """

  alias Elara.Lab.Report

  @ranked ~w(exec session connection task)
  @descriptive ~w(client threads transport other)
  @prefix ~w(value seed status validity_status validity_reasons ranked a1_late_ms a2_minus_a1_ms f1_late_ms f2_minus_f1_ms)
  @rate ~w(us_per_s_approx interior_ms envelope_ms)

  @doc "The five tables, as `{file name, rows}`, over the repetitions that carry a profile."
  @spec tables([map()]) :: [{String.t(), [list()]}]
  def tables(repetitions) do
    [
      {"profile-windows.tsv", windows(repetitions)},
      {"profile-classes.tsv", classes(repetitions)},
      {"profile-functions.tsv", functions(repetitions)},
      {"profile-modules.tsv", modules(repetitions)},
      {"profile-memory.tsv", memory(repetitions)}
    ]
  end

  @doc """
  One row per profile: its timestamps (ms after t0), the interior's overlap with
  the registered interval, own-time totals, coverage and collection. Nothing is
  invented for an unactivated or fallback profile: absent values are null.
  """
  @spec windows([map()]) :: [list()]
  def windows(repetitions) do
    header =
      @prefix ++
        ~w(a1 n a2 f1 f2 from to envelope_ms interior_ms overlap_ms total_us ranked_us
           unclassified_us unclassified_share births_before_n_census births_before_n_dead
           births_after_n receipt_present receipt_absent receipt_dead collection_ms
           collection_failure clients_started counters)

    rows =
      for {rep, p} <- profiles(repetitions) do
        w = p["window"] || %{}
        births = get_in(p, ["coverage", "births"]) || %{}
        receipt = get_in(p, ["coverage", "receipt"]) || %{}

        prefix(rep, p) ++
          Enum.map(~w(a1 n a2 f1 f2 from to envelope_ms interior_ms), &w[&1]) ++
          [
            overlap(w),
            p["total_us"],
            ranked_us(p),
            p["unclassified_us"],
            p["unclassified_share"],
            births["before_n_census"],
            births["before_n_dead"],
            births["after_n"],
            receipt["present"],
            receipt["absent"],
            receipt["dead"],
            p["collection_ms"],
            p["collection_failure"],
            p["clients_started"],
            counters(p)
          ]
      end

    [header | rows]
  end

  @doc """
  One row per class: its kind (ranked, descriptive, unclassified), pids, calls,
  own time, share of all traced own time and, for ranked classes, of ranked own
  time. A profile without counters has one `all` row with null numbers.
  """
  @spec classes([map()]) :: [list()]
  def classes(repetitions) do
    header = @prefix ++ ~w(class kind pids calls own_us share_traced share_ranked counters)

    rows =
      for {rep, p} <- profiles(repetitions), p["window"] != nil, row <- class_rows(p) do
        prefix(rep, p) ++ row
      end

    [header | rows]
  end

  defp class_rows(%{"counters" => "unavailable"}),
    do: [["all", nil, nil, nil, nil, nil, nil, "unavailable"]]

  defp class_rows(p) do
    total = p["total_us"]
    ranked = ranked_us(p)

    for class <- class_order(Map.keys(p["classes"] || %{})) do
      c = p["classes"][class]
      kind = kind(class)

      [
        class,
        kind,
        c["pids"],
        c["calls"],
        c["own_us"],
        share(c["own_us"], total),
        if(kind == "ranked", do: share(c["own_us"], ranked)),
        "available"
      ]
    end
  end

  @doc """
  Ranked classes' functions by own time: rank within the class and across
  ranked classes (ties by class, module, function, arity), shares, and an
  approximate rate over the interior with the envelope beside it. An unranked
  profile's rows keep null ranks.
  """
  @spec functions([map()]) :: [list()]
  def functions(repetitions) do
    ranking(repetitions, ~w(function native calls), fn rows ->
      for r <- rows,
          do:
            {{r["class"], r["module"], r["function"], r["arity"]},
             %{
               "class" => r["class"],
               "us" => r["us"],
               "cells" => [name(r["module"], r["function"], r["arity"]), r["native"], r["calls"]]
             }}
    end)
  end

  @doc """
  Ranked classes' own time rolled up by module, ranked as `functions/1` ranks.
  `includes_native` marks a module with any native function, whose time may
  include blocking; `native_us` is that part of its own time.
  """
  @spec modules([map()]) :: [list()]
  def modules(repetitions) do
    ranking(repetitions, ~w(module includes_native native_us calls), fn rows ->
      rows
      |> Enum.group_by(&{&1["class"], &1["module"]})
      |> Enum.map(fn {{class, module}, group} ->
        {{class, module},
         %{
           "class" => class,
           "us" => group |> Enum.map(& &1["us"]) |> Enum.sum(),
           "cells" => [
             module_name(module),
             Enum.any?(group, & &1["native"]),
             group |> Enum.filter(& &1["native"]) |> Enum.map(& &1["us"]) |> Enum.sum(),
             group |> Enum.map(& &1["calls"]) |> Enum.sum()
           ]
         }}
      end)
    end)
  end

  defp ranking(repetitions, cells, entries) do
    header =
      @prefix ++
        ~w(class rank_in_class rank_ranked) ++
        cells ++ ~w(us share_of_class share_of_ranked) ++ @rate

    rows =
      for {rep, p} <- profiles(repetitions), is_list(p["functions"]) do
        ranked? = ranked?(p)
        own = fn class -> get_in(p, ["classes", class, "own_us"]) end
        w = p["window"]

        ordered =
          p["functions"]
          |> Enum.filter(&(&1["class"] in @ranked))
          |> entries.()
          |> Enum.sort_by(fn {identity, e} -> {-e["us"], identity} end)

        in_class =
          ordered
          |> Enum.group_by(fn {_id, e} -> e["class"] end)
          |> Enum.flat_map(fn {_class, group} ->
            group |> Enum.with_index(1) |> Enum.map(fn {{id, _e}, i} -> {id, i} end)
          end)
          |> Map.new()

        for {{id, e}, i} <- Enum.with_index(ordered, 1) do
          prefix(rep, p) ++
            [e["class"], if(ranked?, do: in_class[id]), if(ranked?, do: i)] ++
            e["cells"] ++
            [
              e["us"],
              share(e["us"], own.(e["class"])),
              share(e["us"], ranked_us(p)),
              rate(e["us"], w["interior_ms"]),
              w["interior_ms"],
              w["envelope_ms"]
            ]
        end
      end

    [header | Enum.concat(rows)]
  end

  @doc """
  Both censuses, each with its timestamps (VM monotonic ms, and ms after t0
  where the profile recorded t0) and classification:
  per class totals (with ETS bytes), each ETS table with its owner's class,
  shared binaries and class pairs, the unique binary total, the VM's binary
  memory and the signed unreconciled difference, and every VM memory category.
  """
  @spec memory([map()]) :: [list()]
  def memory(repetitions) do
    header =
      @prefix ++
        ~w(census census_started_ms census_ended_ms census_started_after_t0_ms
           census_ended_after_t0_ms census_duration_ms classification kind name
           class pids process_bytes binary_exclusive_bytes ets_bytes bytes)

    rows =
      for {rep, p} <- profiles(repetitions),
          name <- ~w(before_activation after_freeze),
          census = get_in(p, ["memory", name]),
          census != nil,
          row <- census_rows(census) do
        prefix(rep, p) ++
          [
            name,
            census["started_ms"],
            census["ended_ms"],
            after_t0(census["started_ms"], p["t0_ms"]),
            after_t0(census["ended_ms"], p["t0_ms"]),
            census["ended_ms"] - census["started_ms"],
            census["classification"] || "classified"
          ] ++ row
      end

    [header | rows]
  end

  defp census_rows(c) do
    ets = c["ets_by_class"] || %{}
    classes = c["classes"] || %{}
    held = Map.keys(classes)

    class_rows =
      for class <- class_order(held) do
        k = classes[class]

        ["class", nil, class, k["pids"], k["process_bytes"], k["binary_exclusive_bytes"]] ++
          [Map.get(ets, class, 0), nil]
      end

    ets_only =
      for class <- ets |> Map.keys() |> Kernel.--(held) |> Enum.sort(),
          do: ["class", nil, class, nil, nil, nil, ets[class], nil]

    tables = for t <- c["ets"] || [], do: row("ets_table", t["table"], t["class"], t["bytes"])
    shared = c["binary_shared"] || %{}

    pairs =
      for {pair, bytes} <- Enum.sort(shared["pairs"] || %{}),
          do: row("binary_pair", pair, nil, bytes)

    vm =
      for {category, bytes} <- Enum.sort(c["memory"] || %{}),
          do: row("vm_memory", category, nil, bytes)

    class_rows ++
      ets_only ++
      tables ++
      [row("binary_shared", nil, nil, shared["bytes"])] ++
      pairs ++
      [
        row("binary_unique_total", nil, nil, c["binary_unique_total"]),
        row("erlang_binary_memory", nil, nil, c["binary_memory"]),
        row("unreconciled_binary_difference", nil, nil, c["unreconciled_binary_difference"])
      ] ++ vm
  end

  defp after_t0(_ms, nil), do: nil
  defp after_t0(ms, t0), do: ms - t0

  defp row(kind, name, class, bytes), do: [kind, name, class, nil, nil, nil, nil, bytes]

  # ── Shared ──────────────────────────────────────────────────────────────

  defp profiles(repetitions),
    do: for(%{"profile" => %{} = p} = rep <- repetitions, do: {rep, p})

  defp prefix(rep, p) do
    w = p["window"]
    validity = p["validity"] || %{}

    late =
      if w,
        do: [w["a1"] - w["from"], w["a2"] - w["a1"], w["f1"] - w["to"], w["f2"] - w["f1"]],
        else: [nil, nil, nil, nil]

    [
      rep["sweep"]["value"],
      rep["sweep"]["seed"],
      Report.status(rep),
      validity["status"],
      Enum.join(validity["reasons"] || [], ";"),
      ranked?(p)
    ] ++ late
  end

  defp ranked?(p), do: get_in(p, ["validity", "status"]) in ["valid", "qualified"]

  defp counters(%{"window" => nil}), do: nil
  defp counters(%{"counters" => "unavailable"}), do: "unavailable"
  defp counters(%{"window" => _}), do: "available"
  defp counters(_p), do: nil

  defp overlap(%{"f1" => f1, "to" => to, "a2" => a2, "from" => from}),
    do: max(0, min(f1, to) - max(a2, from))

  defp overlap(_w), do: nil

  defp ranked_us(%{"classes" => %{} = classes}),
    do: @ranked |> Enum.map(&(get_in(classes, [&1, "own_us"]) || 0)) |> Enum.sum()

  defp ranked_us(_p), do: nil

  defp kind(class) when class in @ranked, do: "ranked"
  defp kind(class) when class in @descriptive, do: "descriptive"
  defp kind("unclassified"), do: "unclassified"
  defp kind(_class), do: "unknown"

  defp class_order(classes) do
    known = @ranked ++ @descriptive ++ ["unclassified"]
    Enum.filter(known, &(&1 in classes)) ++ Enum.sort(classes -- known)
  end

  defp share(_part, whole) when whole in [nil, 0], do: nil
  defp share(part, whole), do: part / whole

  defp rate(_us, ms) when ms in [nil, 0], do: nil
  defp rate(us, ms), do: us / (ms / 1000)

  defp name(module, function, arity), do: "#{module_name(module)}.#{function}/#{arity}"

  defp module_name("Elixir." <> rest), do: rest
  defp module_name(module), do: ":#{module}"
end
