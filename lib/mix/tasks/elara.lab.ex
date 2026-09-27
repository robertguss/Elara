defmodule Mix.Tasks.Elara.Lab do
  use Mix.Task

  @shortdoc "Run a seeded lab scenario"
  @moduledoc """
  Run a seeded lab scenario and record its results.

      mix elara.lab run SCENARIO [--n N] [--seed S] [--set KEY=VALUE ...] [--results DIR]
                                 [--provider simulated|real --max-requests R]

  Each repetition uses seed `S + rep` and its own temporary sessions root and
  skills home, so it never touches `~/.elara` state (a real provider still reads
  its saved credentials). `--provider real` uses the configured provider and
  spends real quota; it requires `--max-requests`. Result lines are appended under
  `lab/results/SCENARIO/` (gitignored) and a summary is printed. The task fails
  when any check fails or a repetition's cleanup is unconfirmed. Scenarios:
  #{Enum.join(Elara.Lab.scenarios(), ", ")}.

      mix elara.lab sweep SCENARIO --over KEY=V1,V2,... [--n N] [--seed S] [--set KEY=VALUE ...]
                                   [--results DIR]

  Runs one fresh `mix elara.lab run` process per value and seed (seed-major:
  every value at seed `S`, then every value at `S + 1`, ...), each with its own
  TMPDIR, and writes `repetitions.jsonl`, `summary.json`, child logs and results
  under `lab/results/SCENARIO/<stamp>-sweep-KEY-seed<S>/`. It runs every child,
  then fails if any exited non-zero, left no valid result, failed a check, was
  retained or is incomplete. A bound that fails is a measurement, not a failure.
  """

  @switches [
    n: :integer,
    seed: :integer,
    set: :keep,
    results: :string,
    provider: :string,
    max_requests: :integer
  ]

  @impl true
  def run(["run", scenario | argv]) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if rest != [] or invalid != [],
      do: Mix.raise("unexpected arguments: #{inspect(rest ++ Enum.map(invalid, &elem(&1, 0)))}")

    # Isolate state before the application starts; each repetition narrows it further.
    base = Path.join(System.tmp_dir!(), "elara-lab-#{Elara.Lab.unique()}")
    Application.put_env(:elara, :sessions_root, Path.join(base, "sessions"))
    Application.put_env(:elara, :skills_home, Path.join(base, "home"))
    Mix.Task.run("app.start")

    params =
      opts
      |> Keyword.get_values(:set)
      |> Map.new(fn pair ->
        case String.split(pair, "=", parts: 2) do
          [key, value] -> {key, value}
          _ -> Mix.raise("--set expects KEY=VALUE, got #{inspect(pair)}")
        end
      end)

    provider =
      case Keyword.get(opts, :provider, "simulated") do
        "simulated" -> :simulated
        "real" -> :real
        other -> Mix.raise("--provider must be simulated or real, got #{inspect(other)}")
      end

    if provider == :real and not is_integer(opts[:max_requests]),
      do: Mix.raise("--provider real requires --max-requests R")

    lab_opts = [
      seed: Keyword.get(opts, :seed, 1),
      n: Keyword.get(opts, :n, 1),
      params: params,
      provider: provider,
      max_requests: opts[:max_requests]
    ]

    try do
      case Elara.Lab.run(scenario, lab_opts) do
        {:ok, results} ->
          path = Elara.Lab.write_results(Keyword.get(opts, :results, "lab/results"), results)
          summary = Elara.Lab.summarize(results)
          Mix.shell().info(JSON.encode!(summary))
          Mix.shell().info("results: #{path}")

          if summary.failed_checks != %{} or summary.retained_dirs != [],
            do:
              Mix.raise(
                "lab run failed: checks #{inspect(summary.failed_checks)}, " <>
                  "retained #{inspect(summary.retained_dirs)}"
              )

        {:error, {:unknown_scenario, name, known}} ->
          Mix.raise("unknown scenario #{inspect(name)}; known: #{Enum.join(known, ", ")}")
      end
    after
      File.rm_rf(base)
    end
  end

  def run(["sweep", scenario | argv]) do
    {opts, rest, invalid} =
      OptionParser.parse(argv,
        strict: [over: :string, n: :integer, seed: :integer, set: :keep, results: :string]
      )

    if rest != [] or invalid != [],
      do: Mix.raise("unexpected arguments: #{inspect(rest ++ Enum.map(invalid, &elem(&1, 0)))}")

    Mix.Task.run("compile")

    unless scenario in Elara.Lab.scenarios(),
      do:
        Mix.raise(
          "unknown scenario #{inspect(scenario)}; known: #{Enum.join(Elara.Lab.scenarios(), ", ")}"
        )

    {key, values} =
      case String.split(opts[:over] || "", "=", parts: 2) do
        [key, values] when key != "" and values != "" -> {key, String.split(values, ",")}
        _ -> Mix.raise("--over expects KEY=V1,V2,...")
      end

    if "" in values, do: Mix.raise("--over values must not be empty")
    if Enum.uniq(values) != values, do: Mix.raise("--over values must be distinct")
    params = opts |> Keyword.get_values(:set) |> Map.new(&pair/1)
    if Map.has_key?(params, key), do: Mix.raise("--set #{key} conflicts with --over #{key}")

    n = Keyword.get(opts, :n, 1)
    if n < 1, do: Mix.raise("--n must be at least 1")
    seed = Keyword.get(opts, :seed, 1)
    stamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic) |> String.replace(~r/[^0-9TZ]/, "")
    root = opts |> Keyword.get(:results, "lab/results") |> Path.expand()
    dir = Path.join([root, scenario, "#{stamp}-sweep-#{key}-seed#{seed}"])
    total = n * length(values)

    result =
      Elara.Lab.Sweep.run(scenario,
        key: key,
        values: values,
        n: n,
        seed: seed,
        params: params,
        dir: dir,
        on_child: fn repetition ->
          sweep = repetition["sweep"]
          state = if Elara.Lab.Sweep.ok?(repetition), do: "ok", else: "NOT OK"

          Mix.shell().info(
            "[#{sweep["index"] + 1}/#{total}] #{key}=#{sweep["value"]} seed=#{sweep["seed"]} " <>
              "exit #{sweep["exit_status"]} #{state}"
          )
        end
      )

    File.write!(
      Path.join(dir, "repetitions.jsonl"),
      Enum.map(result.repetitions, &[JSON.encode!(&1), "\n"])
    )

    File.write!(Path.join(dir, "summary.json"), JSON.encode!(result.summary))
    Mix.shell().info(JSON.encode!(result.summary))

    for point <- result.summary["points"] do
      bounds = Enum.map_join(point["bounds"], " ", fn {name, verdict} -> "#{name}=#{verdict}" end)

      Mix.shell().info(
        "#{key}=#{point["value"]}: #{point["present"]}/#{point["expected_repetitions"]} present, " <>
          "#{point["errors"]} errors, incomplete #{inspect(point["incomplete"])}, #{bounds}"
      )
    end

    Mix.shell().info("saturation: #{inspect(result.summary["saturation_value"])}")
    Mix.shell().info("sweep: #{dir}")

    unless result.ok,
      do:
        Mix.raise(
          "sweep incomplete: at least one repetition is not a clean measurement; see #{dir}"
        )
  end

  def run(_argv),
    do:
      Mix.raise(
        "usage: mix elara.lab run SCENARIO [--n N] [--seed S] [--set KEY=VALUE] | " <>
          "mix elara.lab sweep SCENARIO --over KEY=V1,V2 [--n N] [--seed S] [--set KEY=VALUE]"
      )

  defp pair(pair) do
    case String.split(pair, "=", parts: 2) do
      [key, value] -> {key, value}
      _ -> Mix.raise("--set expects KEY=VALUE, got #{inspect(pair)}")
    end
  end
end
