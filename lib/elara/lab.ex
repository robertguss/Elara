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
  A scenario can `hold/2` a shared actor across that switch; the runner resumes
  it only once the root and the directory are final.
  """

  @scenarios %{
    "smoke" => Elara.Lab.Scenarios.Smoke,
    "concurrency" => Elara.Lab.Scenarios.Concurrency,
    "concurrent_jobs" => Elara.Lab.Scenarios.ConcurrentJobs,
    "session_crash" => Elara.Lab.Scenarios.SessionCrash,
    "provider_fault" => Elara.Lab.Scenarios.ProviderFault,
    "session_recovery" => Elara.Lab.Scenarios.SessionRecovery
  }

  @type context :: %{
          seed: integer(),
          dir: String.t(),
          params: %{String.t() => String.t()},
          provider: :simulated | :real,
          max_requests: pos_integer() | nil,
          hook: (term() -> term())
        }

  @callback run(context()) :: map()

  @doc "Optional: `{label, path}` pairs of a result line (string keys) that a sweep summarizes."
  @callback curve_fields() :: [{String.t(), [String.t()]}]
  @optional_callbacks curve_fields: 0

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
      before_release = Keyword.get(opts, :before_release, fn _dir -> :ok end)

      results =
        Enum.reduce_while(0..(Keyword.get(opts, :n, 1) - 1)//1, [], fn rep, acc ->
          result =
            run_once(
              module,
              name,
              %{
                seed: seed + rep,
                params: params,
                provider: Keyword.get(opts, :provider, :simulated),
                max_requests: Keyword.get(opts, :max_requests),
                hook: Keyword.get(opts, :hook, fn _point -> :ok end)
              },
              before_release
            )

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

  @doc "The module registered under a scenario name."
  @spec scenario_module(String.t()) :: {:ok, module()} | :error
  def scenario_module(name), do: Map.fetch(@scenarios, name)

  # A module is accepted directly so tests can run scenarios that are not registered.
  defp scenario(module) when is_atom(module), do: {:ok, module}

  defp scenario(name) do
    case Map.fetch(@scenarios, name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_scenario, name, scenarios()}}
    end
  end

  # Held actors are released only once the root and the directory are final, on
  # every path; `before_release` is a test seam at exactly that point.
  defp run_once(module, name, context, before_release) do
    dir = Path.join(System.tmp_dir!(), "elara-lab-#{name}-#{context.seed}-#{unique()}")

    try do
      try do
        settle_once(module, name, context, dir)
      after
        before_release.(dir)
      end
    after
      release_held()
    end
  end

  defp settle_once(module, name, context, dir) do
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
      |> Map.update(:latency_ms, nil, fn
        samples when is_list(samples) -> percentiles(samples)
        precomputed -> precomputed
      end)
      |> Map.merge(%{
        scenario: name,
        seed: context.seed,
        params: context.params,
        elapsed_ms: System.monotonic_time(:millisecond) - started,
        vm: %{os_pid: System.pid(), tmp_dir: System.tmp_dir!(), run_dir: dir}
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

  @held {__MODULE__, :held}

  @doc """
  Suspend `target` (a pid or registered name) at a callback boundary until the
  current repetition's root and directory are final; the runner then resumes
  it. The pid is recorded before suspension, so a suspend that times out and
  takes effect later is still resumed.
  """
  @spec hold(pid() | atom(), timeout()) :: :ok | {:error, term()}
  def hold(target, timeout) do
    case if(is_pid(target), do: target, else: Process.whereis(target)) do
      nil ->
        {:error, :noproc}

      pid ->
        Process.put(@held, [pid | Process.get(@held, [])])

        try do
          :sys.suspend(pid, timeout)
        catch
          :exit, reason -> {:error, reason}
        end
    end
  end

  defp release_held, do: resume_all(Enum.reverse(Process.delete(@held) || []))

  @doc """
  Run `fun` only while every target is confirmed suspended at a callback
  boundary, then resume each target. Tracked apart from `hold/2`. If a target is
  missing or its suspend fails, `fun` is not called; every pid it tried to
  suspend is still resumed.
  """
  @spec with_held([pid() | atom()], timeout(), (-> result)) ::
          {:ok, result} | {:error, {:not_held, [term()]}}
        when result: term()
  def with_held(targets, timeout, fun) do
    {pids, failures} =
      Enum.reduce(targets, {[], []}, fn target, {pids, failures} ->
        case if(is_pid(target), do: target, else: Process.whereis(target)) do
          nil ->
            {pids, [{target, :noproc} | failures]}

          pid ->
            try do
              :sys.suspend(pid, timeout)
              {[pid | pids], failures}
            catch
              :exit, reason -> {[pid | pids], [{target, reason} | failures]}
            end
        end
      end)

    try do
      if failures == [],
        do: {:ok, fun.()},
        else: {:error, {:not_held, Enum.reverse(failures)}}
    after
      resume_all(Enum.reverse(pids))
    end
  end

  # In order; a failed resume never skips the rest.
  defp resume_all(pids) do
    for pid <- pids do
      try do
        :sys.resume(pid, 5_000)
      catch
        :exit, _reason -> :ok
      end
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

  # Non-numeric values (an unbounded percentile is :infinity) are counted, not averaged.
  defp spread(values) do
    case Enum.split_with(values, &is_number/1) do
      {numbers, []} ->
        numeric(numbers)

      {numbers, others} ->
        Map.put(numeric(numbers), :infinite, Enum.count(others, &(&1 == :infinity)))
    end
  end

  defp numeric([]), do: %{min: nil, mean: nil, max: nil}

  defp numeric(values),
    do: %{
      min: Enum.min(values),
      mean: Float.round(Enum.sum(values) / length(values), 1),
      max: Enum.max(values)
    }

  @doc "Host, runtime and build metadata recorded with each result."
  @spec host() :: map()
  def host do
    %{
      cpu: command("sysctl", ["-n", "machdep.cpu.brand_string"]),
      memory_bytes:
        with(
          bytes when is_binary(bytes) <- command("sysctl", ["-n", "hw.memsize"]),
          {n, ""} <- Integer.parse(bytes),
          do: n,
          else: (_ -> nil)
        ),
      logical_cpus: :erlang.system_info(:logical_processors),
      os: command("uname", ["-sr"]),
      otp: to_string(:erlang.system_info(:otp_release)),
      erts: to_string(:erlang.system_info(:version)),
      elixir: System.version(),
      schedulers: :erlang.system_info(:schedulers_online),
      dirty_cpu_schedulers: :erlang.system_info(:dirty_cpu_schedulers),
      dirty_io_schedulers: :erlang.system_info(:dirty_io_schedulers),
      commit: command("git", ["rev-parse", "HEAD"]),
      dirty: command("git", ["status", "--porcelain"]) not in [nil, ""]
    }
  end

  defp command(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  rescue
    ErlangError -> nil
  end

  # Unique across VMs: fresh VMs repeat unique_integer values, and a retained
  # directory outlives its VM.
  @doc false
  def unique,
    do: "#{System.pid()}-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
end
