defmodule Elara.Lab.Report do
  @moduledoc """
  Tables over a sweep's recorded repetitions: per repetition, per value, and
  paired across two sweeps. Reads records only; judges nothing the sweep did
  not.
  """

  alias Elara.Lab.Sweep

  @bounds ~w(latency memory throughput)

  @doc """
  `"clean"` exactly when `Sweep.ok?/1` holds; otherwise every problem, joined
  by `;`: `error:<reason>`, `exit:<n>`, `checks:<names>`, `retained`,
  `incomplete:<reason>`, `not_complete`.
  """
  @spec status(map()) :: String.t()
  def status(repetition) do
    exit_status = repetition["sweep"]["exit_status"]
    failed = for {name, passed} <- repetition["checks"] || %{}, passed != true, do: name

    problems =
      [
        repetition["error"] && "error:#{repetition["error"]["reason"]}",
        exit_status != 0 && "exit:#{exit_status}",
        failed != [] && "checks:#{failed |> Enum.sort() |> Enum.join(",")}",
        Map.has_key?(repetition, "retained_dir") && "retained",
        repetition["incomplete"] && "incomplete:#{repetition["incomplete"]}",
        repetition["complete"] == false && "not_complete"
      ]
      |> Enum.filter(&is_binary/1)

    if problems == [], do: "clean", else: Enum.join(problems, ";")
  end

  @doc """
  A header and one row per repetition: value, seed, status, each bound's verdict
  (`undetermined` where absent), then each field (`error` for an error
  repetition, nil where the result has no value).
  """
  @spec repetition_rows([map()], [{String.t(), [String.t()]}]) :: [list()]
  def repetition_rows(repetitions, fields) do
    header =
      ["value", "seed", "status"] ++
        Enum.map(@bounds, &"#{&1}_bound") ++ Enum.map(fields, &elem(&1, 0))

    rows =
      for repetition <- repetitions do
        [repetition["sweep"]["value"], repetition["sweep"]["seed"], status(repetition)] ++
          Enum.map(@bounds, &Map.get(repetition["bounds"] || %{}, &1, "undetermined")) ++
          Enum.map(fields, fn {_label, path} -> cell(repetition, path) end)
      end

    [header | rows]
  end

  @doc """
  A header and one row per value: expected, present, clean and error
  repetitions, and each bound as `Sweep.aggregate_bounds/2` gives it
  (`undetermined` where no repetition names it). Cleanliness does not enter
  the bounds.
  """
  @spec point_rows([map()], [String.t()], pos_integer()) :: [list()]
  def point_rows(repetitions, values, n) do
    by_value = Enum.group_by(repetitions, & &1["sweep"]["value"])

    rows =
      for value <- values do
        reps = Map.get(by_value, value, [])
        present = Enum.reject(reps, &Map.has_key?(&1, "error"))
        bounds = Sweep.aggregate_bounds(Enum.map(present, &(&1["bounds"] || %{})), n)

        [
          value,
          n,
          length(present),
          Enum.count(reps, &Sweep.ok?/1),
          length(reps) - length(present)
        ] ++
          Enum.map(@bounds, &Map.get(bounds, &1, "undetermined"))
      end

    [~w(value expected present clean errors) ++ @bounds | rows]
  end

  @doc """
  Pairs two sweeps' repetitions by (value, seed), every key from either side
  (only `seed` when given), one row per key and field: both statuses (`missing`
  for an absent side), both raw values, and `other - base` only when both are
  numbers. Otherwise the difference is `unavailable` and the reason is
  `base_missing`, `other_missing`, `base_error`, `other_error` or `nonnumeric`.
  Values sort numerically when all are numbers, else in the base sweep's order.
  """
  @spec compare([map()], [map()], [{String.t(), [String.t()]}], keyword()) :: [list()]
  def compare(base, other, fields, opts \\ []) do
    seed = Keyword.get(opts, :seed)
    key = &{&1["sweep"]["value"], &1["sweep"]["seed"]}
    base_by = Map.new(base, &{key.(&1), &1})
    other_by = Map.new(other, &{key.(&1), &1})

    keys =
      (Enum.map(base, key) ++ Enum.map(other, key))
      |> Enum.uniq()
      |> Enum.filter(fn {_value, s} -> seed == nil or s == seed end)
      |> order()

    rows =
      for {value, s} = k <- keys, {label, path} <- fields do
        b = Map.get(base_by, k)
        o = Map.get(other_by, k)
        {difference, reason} = difference(b, o, path)

        [value, s, side_status(b), side_status(o), label, side(b, path), side(o, path)] ++
          [difference, reason]
      end

    [~w(value seed base_status other_status field base other difference reason) | rows]
  end

  @doc "Tab-separated text, one line per row. Nil is `null`; tabs and newlines in text become spaces."
  @spec tsv([list()]) :: String.t()
  def tsv(rows),
    do: Enum.map_join(rows, fn row -> Enum.map_join(row, "\t", &encode/1) <> "\n" end)

  # Numeric when every value parses as a number, else first-seen (base first).
  defp order(keys) do
    numbers = Enum.map(keys, fn {value, _seed} -> number(value) end)

    if Enum.all?(numbers, &is_number/1) do
      keys
      |> Enum.zip(numbers)
      |> Enum.sort_by(fn {{_v, s}, n} -> {n, s} end)
      |> Enum.map(&elem(&1, 0))
    else
      firsts = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.with_index() |> Map.new()
      Enum.sort_by(keys, fn {v, s} -> {firsts[v], s} end)
    end
  end

  defp difference(nil, _other, _path), do: {"unavailable", "base_missing"}
  defp difference(_base, nil, _path), do: {"unavailable", "other_missing"}
  defp difference(%{"error" => _}, _other, _path), do: {"unavailable", "base_error"}
  defp difference(_base, %{"error" => _}, _path), do: {"unavailable", "other_error"}

  defp difference(base, other, path) do
    case {cell(base, path), cell(other, path)} do
      {b, o} when is_number(b) and is_number(o) -> {o - b, ""}
      _ -> {"unavailable", "nonnumeric"}
    end
  end

  defp side_status(nil), do: "missing"
  defp side_status(repetition), do: status(repetition)

  defp side(nil, _path), do: "missing"
  defp side(repetition, path), do: cell(repetition, path)

  defp cell(%{"error" => _}, _path), do: "error"
  defp cell(repetition, path), do: value_at(repetition, path)

  defp value_at(value, []), do: value
  defp value_at(%{} = map, [key | rest]), do: value_at(Map.get(map, key), rest)
  defp value_at(_value, _path), do: nil

  defp number(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} ->
        n

      _ ->
        case Float.parse(value) do
          {n, ""} -> n
          _ -> nil
        end
    end
  end

  defp number(_value), do: nil

  defp encode(nil), do: "null"
  defp encode(value) when is_integer(value), do: Integer.to_string(value)
  defp encode(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])
  defp encode(value) when is_binary(value), do: String.replace(value, ["\t", "\r", "\n"], " ")
  defp encode(value) when is_boolean(value), do: Atom.to_string(value)
  defp encode(value), do: JSON.encode!(value)
end
