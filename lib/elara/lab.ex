defmodule Elara.Lab do
  @moduledoc """
  Seeded lab runner. Runs a scenario once per repetition, each in its own
  temporary sessions root and skills home, and summarizes the results.

  A seed fixes a scenario's choices (simulated responses, tool plans, fault
  schedules). It does not fix concurrent interleavings or timings, so those
  are reported across repetitions with their spread.

  A scenario reports invariants as `checks: %{name => boolean}`; a repetition
  with a failed check keeps its directory as `evidence_dir`. A scenario settles
  its own jobs and sessions before returning. If it cannot confirm that
  (`cleanup_confirmed: false`) or it raises, the runner keeps the directory, runs
  no further repetitions, and leaves the global sessions root bound to it, so
  unsettled work keeps resolving its own records. Such a VM should not be reused.
  """

  @scenarios %{
    "smoke" => Elara.Lab.Scenarios.Smoke,
    "concurrent_jobs" => Elara.Lab.Scenarios.ConcurrentJobs,
    "session_crash" => Elara.Lab.Scenarios.SessionCrash,
    "provider_fault" => Elara.Lab.Scenarios.ProviderFault
  }

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
  @spec run(String.t() | module(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def run(name, opts) do
    with {:ok, module} <- scenario(name) do
      name =
        if is_atom(name),
          do: name |> Module.split() |> List.last() |> Macro.underscore(),
          else: name

      seed = Keyword.fetch!(opts, :seed)
      params = Keyword.get(opts, :params, %{})

      results =
        Enum.reduce_while(0..(Keyword.get(opts, :n, 1) - 1)//1, [], fn rep, acc ->
          result =
            run_once(module, name, %{
              seed: seed + rep,
              params: params,
              provider: Keyword.get(opts, :provider, :simulated),
              max_requests: Keyword.get(opts, :max_requests)
            })

          if Map.has_key?(result, :retained_dir),
            do: {:halt, [result | acc]},
            else: {:cont, [result | acc]}
        end)

      {:ok, Enum.reverse(results)}
    end
  end

  @doc "Names of the checks a result reports as failed."
  @spec failed_checks(map()) :: [atom() | String.t()]
  def failed_checks(result),
    do:
      for({name, passed} <- Map.get(result, :checks, %{}), passed != true, do: name)
      |> Enum.sort()

  # A module is accepted directly so tests can run scenarios that are not registered.
  defp scenario(module) when is_atom(module), do: {:ok, module}

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

    result =
      try do
        module.run(Map.put(context, :dir, dir))
      rescue
        error ->
          IO.warn("lab scenario #{name} raised; retained #{dir}; its sessions root stays bound")
          reraise error, __STACKTRACE__
      end

    result =
      result
      |> Map.update(:latency_ms, nil, &percentiles/1)
      |> Map.merge(%{
        scenario: name,
        seed: context.seed,
        params: context.params,
        elapsed_ms: System.monotonic_time(:millisecond) - started
      })

    {cleanup, result} = Map.pop(result, :cleanup_confirmed, true)

    cond do
      # Unsettled work (a job runner, say) still resolves paths through the
      # global sessions root, so leave it bound to this run's root.
      cleanup != true ->
        IO.warn("lab cleanup unconfirmed; retained #{dir}; its sessions root stays bound")
        Map.put(result, :retained_dir, dir)

      failed_checks(result) != [] ->
        restore(previous)
        Map.put(result, :evidence_dir, dir)

      true ->
        restore(previous)
        File.rm_rf!(dir)
        result
    end
  end

  defp restore(previous) do
    Enum.each(previous, fn
      {key, nil} -> Application.delete_env(:elara, key)
      {key, value} -> Application.put_env(:elara, key, value)
    end)
  end

  @doc """
  Start a process that logs simulated choices; pass it as a provider's
  `collector`. Kept out of the scenario's mailbox so receive loops cannot drop
  entries.
  """
  @spec choice_log() :: pid()
  def choice_log, do: spawn_link(fn -> log_choices(%{}) end)

  @doc "Stop a choice log and return its choices, per simulated id in request order."
  @spec choices(pid()) :: %{term() => [term()]}
  def choices(log) do
    ref = make_ref()
    send(log, {:dump, self(), ref})

    receive do
      {^ref, choices} -> choices
    after
      5_000 -> raise "choice log did not answer"
    end
  end

  @doc "Stop a choice log and digest its choices."
  @spec choices_digest(pid()) :: String.t()
  def choices_digest(log), do: log |> choices() |> digest()

  defp log_choices(choices) do
    receive do
      {:lab_choice, id, _request, choice} ->
        log_choices(Map.update(choices, id, [choice], &[choice | &1]))

      {:dump, from, ref} ->
        send(from, {ref, Map.new(choices, fn {id, list} -> {id, Enum.reverse(list)} end)})

      _other ->
        log_choices(choices)
    end
  end

  @doc "Deterministic SHA-256 of a term, lowercase hex."
  @spec digest(term()) :: String.t()
  def digest(term),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
      |> Base.encode16(case: :lower)

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
      failed_checks: results |> Enum.flat_map(&failed_checks/1) |> Enum.frequencies(),
      retained_dirs: for(%{retained_dir: dir} <- results, do: dir),
      evidence_dirs: for(%{evidence_dir: dir} <- results, do: dir),
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
