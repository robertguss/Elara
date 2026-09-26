defmodule Elara.Lab do
  @moduledoc """
  Seeded lab runner. Runs a scenario once per repetition, each in its own
  temporary sessions root and skills home, and summarizes the results.

  A seed fixes a scenario's choices (simulated responses, tool plans, fault
  schedules). It does not fix concurrent interleavings or timings, so those
  are reported across repetitions with their spread.
  """

  @scenarios %{"smoke" => Elara.Lab.Scenarios.Smoke}

  @type context :: %{
          seed: integer(),
          dir: String.t(),
          params: %{String.t() => String.t()},
          provider: :simulated | :real,
          max_requests: pos_integer() | nil
        }

  @callback run(context()) :: map()

  @spec scenarios() :: [String.t()]
  def scenarios, do: @scenarios |> Map.keys() |> Enum.sort()

  @doc """
  Run `name` for `n` repetitions with seeds `seed`, `seed + 1`, ... Returns one
  result map per repetition. Raw `latency_ms` samples are replaced by their
  percentiles.
  """
  @spec run(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def run(name, opts) do
    with {:ok, module} <- scenario(name) do
      seed = Keyword.fetch!(opts, :seed)
      params = Keyword.get(opts, :params, %{})

      results =
        for rep <- 0..(Keyword.get(opts, :n, 1) - 1)//1 do
          run_once(module, name, %{
            seed: seed + rep,
            params: params,
            provider: Keyword.get(opts, :provider, :simulated),
            max_requests: Keyword.get(opts, :max_requests)
          })
        end

      {:ok, results}
    end
  end

  defp scenario(name) do
    case Map.fetch(@scenarios, name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_scenario, name, scenarios()}}
    end
  end

  defp run_once(module, name, context) do
    dir = Path.join(System.tmp_dir!(), "elara-lab-#{name}-#{context.seed}-#{unique()}")
    File.mkdir_p!(dir)
    previous = Map.new([:sessions_root, :skills_home], &{&1, Application.get_env(:elara, &1)})
    Application.put_env(:elara, :sessions_root, Path.join(dir, "sessions"))
    Application.put_env(:elara, :skills_home, Path.join(dir, "home"))
    started = System.monotonic_time(:millisecond)

    try do
      result = module.run(Map.put(context, :dir, dir))
      elapsed = System.monotonic_time(:millisecond) - started

      result
      |> Map.update(:latency_ms, nil, &percentiles/1)
      |> Map.merge(%{
        scenario: name,
        seed: context.seed,
        params: context.params,
        elapsed_ms: elapsed
      })
    after
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:elara, key)
        {key, value} -> Application.put_env(:elara, key, value)
      end)

      File.rm_rf!(dir)
    end
  end

  @doc "Nearest-rank percentiles of a list of numbers (nil when empty)."
  @spec percentiles([number()]) :: map() | nil
  def percentiles([]), do: nil

  def percentiles(samples) do
    sorted = Enum.sort(samples)
    count = length(sorted)
    rank = fn p -> Enum.at(sorted, max(ceil(p * count) - 1, 0)) end
    %{count: count, p50: rank.(0.5), p95: rank.(0.95), p99: rank.(0.99), max: List.last(sorted)}
  end

  @doc "Append result lines to `root/<scenario>/<timestamp>-seed<S>.jsonl`; returns the path."
  @spec write_results(String.t(), [map()]) :: String.t()
  def write_results(root, [first | _] = results) do
    stamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic) |> String.replace(~r/[^0-9TZ]/, "")
    path = Path.join([root, first.scenario, "#{stamp}-seed#{first.seed}.jsonl"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map(results, &[JSON.encode!(&1), "\n"]))
    path
  end

  @doc "Summarize numeric fields across repetitions as min/mean/max."
  @spec summarize([map()]) :: map()
  def summarize(results) do
    %{
      repetitions: length(results),
      seeds: Enum.map(results, & &1.seed),
      choices_digests: Enum.map(results, &Map.get(&1, :choices_digest)),
      elapsed_ms: spread(Enum.map(results, & &1.elapsed_ms)),
      completed_turns: spread(Enum.map(results, &Map.get(&1, :completed_turns, 0))),
      latency_p50_ms: spread(for %{latency_ms: %{p50: v}} <- results, do: v),
      latency_p95_ms: spread(for %{latency_ms: %{p95: v}} <- results, do: v),
      latency_p99_ms: spread(for %{latency_ms: %{p99: v}} <- results, do: v)
    }
  end

  defp spread([]), do: nil

  defp spread(values),
    do: %{
      min: Enum.min(values),
      mean: Float.round(Enum.sum(values) / length(values), 1),
      max: Enum.max(values)
    }

  defp unique, do: System.unique_integer([:positive])
end
