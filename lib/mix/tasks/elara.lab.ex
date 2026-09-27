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
  `lab/results/SCENARIO/` (gitignored) and a summary is printed. Scenarios:
  #{Enum.join(Elara.Lab.scenarios(), ", ")}.
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
    base = Path.join(System.tmp_dir!(), "elara-lab-#{System.unique_integer([:positive])}")
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
          Mix.shell().info(JSON.encode!(Elara.Lab.summarize(results)))
          Mix.shell().info("results: #{path}")

        {:error, {:unknown_scenario, name, known}} ->
          Mix.raise("unknown scenario #{inspect(name)}; known: #{Enum.join(known, ", ")}")
      end
    after
      File.rm_rf(base)
    end
  end

  def run(_argv),
    do: Mix.raise("usage: mix elara.lab run SCENARIO [--n N] [--seed S] [--set KEY=VALUE]")
end
