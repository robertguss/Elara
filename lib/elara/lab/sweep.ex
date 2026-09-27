defmodule Elara.Lab.Sweep do
  @moduledoc """
  Runs a lab scenario over a list of values, one fresh OS process per (value,
  seed), and summarizes the curve from the children's result lines. Records
  every child's exit; does not interpret the curve.
  """

  @throughput_floor 0.95
  @default_fields [
    {"elapsed_ms", ["elapsed_ms"]},
    {"completed_turns", ["completed_turns"]},
    {"latency_p50_ms", ["latency_ms", "p50"]},
    {"latency_p95_ms", ["latency_ms", "p95"]},
    {"latency_p99_ms", ["latency_ms", "p99"]}
  ]

  @doc """
  Run `scenario` for every value and repetition, seed-major: repetition `r`
  runs every value (seed `seed + r`) before repetition `r + 1` starts. `opts`:
  `key`, `values`, `n`, `seed`, `params` (other `--set` pairs), `dir` (absolute;
  receives child logs, results and TMPDIRs), `runner` (`(args, env, log) ->
  exit_status`, default: a `mix` child process), `fields` (curve fields,
  default: the scenario's `curve_fields/0` or a generic set) and `on_child`
  (called with each finished repetition).
  """
  @spec run(String.t(), keyword()) :: %{repetitions: [map()], summary: map(), ok: boolean()}
  def run(scenario, opts) do
    key = Keyword.fetch!(opts, :key)
    values = Keyword.fetch!(opts, :values)
    n = Keyword.fetch!(opts, :n)
    seed = Keyword.fetch!(opts, :seed)
    dir = opts |> Keyword.fetch!(:dir) |> Path.expand()
    runner = Keyword.get(opts, :runner, &mix_child/3)
    on_child = Keyword.get(opts, :on_child, fn _repetition -> :ok end)
    fields = Keyword.get_lazy(opts, :fields, fn -> fields(scenario) end)
    paths = [["throughput", "ratio"] | Enum.map(fields, &elem(&1, 1))]

    sets =
      opts
      |> Keyword.get(:params, %{})
      |> Enum.sort()
      |> Enum.flat_map(fn {k, v} -> ["--set", "#{k}=#{v}"] end)

    children =
      for r <- 0..(n - 1)//1, value <- values do
        %{repetition: r, value: value, seed: seed + r}
      end

    repetitions =
      children
      |> Enum.with_index()
      |> Enum.map(fn {child, index} ->
        child = Map.put(child, :index, index)
        repetition = run_child(scenario, key, sets, dir, child, runner, paths)
        on_child.(repetition)
        repetition
      end)

    summary = summarize(repetitions, key, values, n, fields)
    %{repetitions: repetitions, summary: summary, ok: Enum.all?(repetitions, &ok?/1)}
  end

  defp run_child(scenario, key, sets, dir, child, runner, paths) do
    name = "#{child.index}-#{safe(child.value)}-seed#{child.seed}"
    tmp = Path.join([dir, "tmp", name])
    results = Path.join([dir, "results", name])
    log = Path.join([dir, "logs", name <> ".log"])
    Enum.each([tmp, results, Path.dirname(log)], &File.mkdir_p!/1)

    args =
      ["elara.lab", "run", scenario, "--n", "1", "--seed", Integer.to_string(child.seed)] ++
        ["--set", "#{key}=#{child.value}"] ++ sets ++ ["--results", results]

    started = DateTime.utc_now()
    status = runner.(args, [{"TMPDIR", tmp}], log)

    sweep = %{
      "key" => key,
      "value" => child.value,
      "repetition" => child.repetition,
      "seed" => child.seed,
      "index" => child.index,
      "exit_status" => status,
      "started_at" => DateTime.to_iso8601(started),
      "ended_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "tmp" => tmp,
      "log" => log
    }

    case read_result(results, scenario, key, child, paths) do
      {:ok, result} ->
        Map.put(result, "sweep", sweep)

      {:error, reason, detail} ->
        %{"sweep" => sweep, "error" => %{"reason" => reason, "detail" => detail}}
    end
  end

  defp safe(value), do: String.replace(value, ~r/[^A-Za-z0-9_.-]/, "_")

  # A child writes exactly one result line for its own scenario, seed and value,
  # with the shapes the summary reads; anything else is an invalid result.
  defp read_result(results, scenario, key, child, paths) do
    with {:ok, path} <- one_file(Path.wildcard(Path.join(results, "**/*.jsonl"))),
         {:ok, line} <- one_line(File.read!(path)),
         {:ok, %{} = result} <- decode(line),
         :ok <- same(result["scenario"], scenario, "wrong_scenario"),
         :ok <- same(result["seed"], child.seed, "wrong_seed"),
         :ok <- same(dig(result, ["params", key]), {:ok, child.value}, "wrong_value"),
         :ok <- shape(result["checks"], &is_boolean/1, "invalid_checks"),
         :ok <- shape(result["bounds"], &is_binary/1, "invalid_bounds"),
         :ok <- same(result["complete"] in [true, false, nil], true, "invalid_complete"),
         :ok <- same(incomplete?(result["incomplete"]), true, "invalid_incomplete"),
         :ok <- same(Enum.all?(paths, &(dig(result, &1) != :error)), true, "invalid_field") do
      {:ok, result}
    end
  end

  defp incomplete?(reason), do: is_nil(reason) or is_binary(reason)

  defp one_file([]), do: {:error, "missing_result", "no result file"}
  defp one_file([path]), do: {:ok, path}
  defp one_file(_many), do: {:error, "invalid_result", "several result files"}

  defp one_line(text) do
    case String.split(text, "\n", trim: true) do
      [line] -> {:ok, line}
      _ -> {:error, "invalid_result", "not exactly one line"}
    end
  end

  defp decode(line) do
    case JSON.decode(line) do
      {:ok, %{} = result} -> {:ok, result}
      _ -> {:error, "invalid_result", "not a JSON object"}
    end
  end

  defp same(value, value, _detail), do: :ok
  defp same(_value, _expected, detail), do: {:error, "invalid_result", detail}

  defp shape(nil, _valid?, _detail), do: :ok

  defp shape(%{} = map, valid?, detail),
    do: if(Enum.all?(Map.values(map), valid?), do: :ok, else: {:error, "invalid_result", detail})

  defp shape(_other, _valid?, detail), do: {:error, "invalid_result", detail}

  # A path into decoded JSON: nil where a key is absent, :error where a
  # non-map sits on the path.
  defp dig(value, []), do: {:ok, value}
  defp dig(nil, _path), do: {:ok, nil}

  defp dig(%{} = map, [key | rest]),
    do: dig(Map.get(map, key), rest)

  defp dig(_other, _path), do: :error

  defp mix_child(args, env, log) do
    env = [{"MIX_ENV", Atom.to_string(Mix.env())} | env]

    {_out, status} =
      System.cmd("mix", args, env: env, stderr_to_stdout: true, into: File.stream!(log))

    status
  end

  @doc "The scenario's curve fields (`{label, path}`), or a generic set when it defines none."
  @spec fields(String.t()) :: [{String.t(), [String.t()]}]
  def fields(scenario) do
    case Elara.Lab.scenario_module(scenario) do
      {:ok, module} ->
        Code.ensure_loaded(module)

        if function_exported?(module, :curve_fields, 0),
          do: apply(module, :curve_fields, []),
          else: @default_fields

      :error ->
        @default_fields
    end
  end

  @doc """
  A repetition is a clean measurement when its child exited 0 with a valid
  result, every check passed, nothing was retained, and it completed. A bound
  that fails is still a clean measurement.
  """
  @spec ok?(map()) :: boolean()
  def ok?(%{"error" => _}), do: false

  def ok?(repetition) do
    repetition["sweep"]["exit_status"] == 0 and failed_checks(repetition) == [] and
      not Map.has_key?(repetition, "retained_dir") and repetition["complete"] != false and
      repetition["incomplete"] == nil
  end

  defp failed_checks(repetition),
    do: for({name, passed} <- repetition["checks"] || %{}, passed != true, do: name)

  @doc "Per-value curve summary, bound aggregation and saturation, from decoded result lines."
  @spec summarize([map()], String.t(), [String.t()], pos_integer(), [{String.t(), [String.t()]}]) ::
          map()
  def summarize(repetitions, key, values, n, fields) do
    by_value = Enum.group_by(repetitions, & &1["sweep"]["value"])

    points =
      for value <- values do
        reps = Map.get(by_value, value, [])
        present = Enum.reject(reps, &Map.has_key?(&1, "error"))

        %{
          "value" => value,
          "expected_repetitions" => n,
          "present" => length(present),
          "errors" => length(reps) - length(present),
          "failed_checks" => present |> Enum.flat_map(&failed_checks/1) |> Enum.frequencies(),
          "incomplete" =>
            present
            |> Enum.map(& &1["incomplete"])
            |> Enum.reject(&is_nil/1)
            |> Enum.frequencies(),
          "fields" =>
            Map.new(fields, fn {label, path} ->
              {label, spread(Enum.map(present, &field(&1, path)))}
            end),
          "bounds" => aggregate_bounds(Enum.map(present, &(&1["bounds"] || %{})), n)
        }
      end

    %{
      "key" => key,
      "repetitions" => n,
      "points" => points,
      "saturation_value" => saturation(repetitions),
      "ratio_below_threshold_values" =>
        repetitions
        |> Enum.filter(&below_floor?(field(&1, ["throughput", "ratio"])))
        |> Enum.map(& &1["sweep"]["value"])
        |> Enum.uniq()
    }
  end

  @doc """
  Per bound: "fails" if any repetition established a failure; "holds" only if
  all `n` expected repetitions hold; otherwise "undetermined".
  """
  @spec aggregate_bounds([map()], pos_integer()) :: map()
  def aggregate_bounds(bounds, n) do
    bounds
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.uniq()
    |> Map.new(fn name ->
      verdicts = Enum.map(bounds, &Map.get(&1, name))

      cond do
        "fails" in verdicts -> {name, "fails"}
        length(verdicts) == n and Enum.all?(verdicts, &(&1 == "holds")) -> {name, "holds"}
        true -> {name, "undetermined"}
      end
    end)
  end

  # The lowest numeric value with a qualifying throughput failure (a compliant,
  # complete repetition below the floor), whatever the execution order.
  defp saturation(repetitions) do
    failing =
      for %{"bounds" => %{"throughput" => "fails"}, "sweep" => %{"value" => value}} <- repetitions,
          do: value

    numbers = Enum.map(failing, &parse_number/1)

    if failing != [] and Enum.all?(numbers, &is_number/1),
      do: failing |> Enum.zip(numbers) |> Enum.min_by(&elem(&1, 1)) |> elem(0)
  end

  defp below_floor?(ratio), do: is_number(ratio) and ratio < @throughput_floor

  # Result lines were validated against every summarized path.
  defp field(result, path) do
    {:ok, value} = dig(result, path)
    value
  end

  defp parse_number(value) do
    case Integer.parse(value) do
      {number, ""} ->
        number

      _ ->
        case Float.parse(value) do
          {number, ""} -> number
          _ -> nil
        end
    end
  end

  defp spread(values) do
    {numbers, others} = values |> Enum.reject(&is_nil/1) |> Enum.split_with(&is_number/1)

    base =
      case numbers do
        [] ->
          %{"min" => nil, "mean" => nil, "max" => nil}

        numbers ->
          %{
            "min" => Enum.min(numbers),
            "mean" => Float.round(Enum.sum(numbers) / length(numbers), 3),
            "max" => Enum.max(numbers)
          }
      end

    if others == [],
      do: base,
      else:
        Map.put(
          base,
          "other",
          Enum.frequencies(Enum.map(others, &if(is_binary(&1), do: &1, else: inspect(&1))))
        )
  end
end
