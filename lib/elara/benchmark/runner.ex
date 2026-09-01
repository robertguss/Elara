defmodule Elara.Benchmark.Runner do
  @moduledoc false

  alias Elara.Benchmark.{Evidence, Fixture, Manifest}

  @fault_conditions ~w(baseline receipts receipts baseline baseline receipts)

  @spec fault_schedule(Manifest.t()) :: [map()]
  def fault_schedule(%Manifest{data: data}) do
    data["fault_rows"]
    |> Enum.sort_by(& &1["order_index"])
    |> Enum.flat_map(fn row ->
      @fault_conditions
      |> Enum.with_index(1)
      |> Enum.map(fn {condition, order_index} ->
        %{
          "row_id" => row["row_id"],
          "condition" => condition,
          "run_index" => condition_run_index(condition, order_index),
          "order_index" => order_index
        }
      end)
    end)
  end

  @spec no_fault_schedule(Manifest.t()) :: [map()]
  def no_fault_schedule(%Manifest{data: data}) do
    data["selection"]["selected_task_ids"]
    |> Enum.flat_map(fn task_id ->
      Enum.flat_map(~w(baseline receipts), fn condition ->
        entries =
          Enum.map(1..2, &%{"phase" => "warmup", "run_index" => &1}) ++
            Enum.map(1..10, &%{"phase" => "measured", "run_index" => &1})

        Enum.map(entries, &Map.merge(&1, %{"task_id" => task_id, "condition" => condition}))
      end)
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, index} -> Map.put(entry, "order_index", index) end)
  end

  @spec run_no_fault(Manifest.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_no_fault(%Manifest{} = manifest, run, opts) when is_map(run) do
    adapter = Keyword.fetch!(opts, :adapter)
    root = Keyword.fetch!(opts, :root)

    with {:ok, task} <- Manifest.task(manifest, run["task_id"]),
         {:ok, initial_digest} <- Fixture.reset(task, root),
         :ok <- Fixture.apply_pre_operation_changes(task, root),
         timing =
           timed(fn ->
             call_adapter(adapter, task, root, %{
               kind: :no_fault,
               condition: run["condition"],
               phase: run["phase"],
               run_index: run["run_index"]
             })
           end),
         {elapsed_us, cpu_us, adapter_result} = timing,
         {:ok, adapter_evidence} <- adapter_result,
         {:ok, final_digest} <- Fixture.digest_directory(root),
         {:ok, storage_bytes} <- Fixture.storage_bytes(root) do
      expected_outcome =
        task["plan"]["steps"] |> List.last() |> Map.fetch!("expected_no_fault_outcome")

      observed_outcome = adapter_evidence["outcome"]

      record = %{
        "schema" => Evidence.no_fault_schema(),
        "task_id" => task["id"],
        "condition" => run["condition"],
        "phase" => run["phase"],
        "run_index" => run["run_index"],
        "order_index" => run["order_index"],
        "fixture_commit" => task["fixture"]["fixture_commit"],
        "initial_workspace_sha256" => initial_digest,
        "expected_workspace_sha256" => task["fixture"]["expected_no_fault_workspace_sha256"],
        "final_workspace_sha256" => final_digest,
        "observed_outcome" => observed_outcome,
        "expected_outcome" => expected_outcome,
        "workspace_correct" =>
          final_digest == task["fixture"]["expected_no_fault_workspace_sha256"],
        "outcome_correct" => observed_outcome == expected_outcome,
        "elapsed_wall_us" => elapsed_us,
        "cpu_time_us" => cpu_us,
        "storage_bytes" => storage_bytes
      }

      case Evidence.validate_no_fault(record) do
        :ok -> {:ok, record}
        {:error, errors} -> {:error, {:harness_failure, {:invalid_no_fault_evidence, errors}}}
      end
    else
      {:error, {:adapter_error, _reason} = reason} -> {:error, {:harness_failure, reason}}
      {:error, _reason} = error -> error
    end
  end

  @spec run_fault(Manifest.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_fault(%Manifest{} = manifest, run, opts) when is_map(run) do
    adapter = Keyword.fetch!(opts, :adapter)
    root = Keyword.fetch!(opts, :root)

    with {:ok, row} <- Manifest.row(manifest, run["row_id"]),
         {:ok, task} <- Manifest.task(manifest, row["task_id"]),
         {:ok, initial_digest} <- Fixture.reset(task, root),
         :ok <- Fixture.apply_pre_operation_changes(task, root),
         {:ok, adapter_evidence, elapsed_us, cpu_us} <-
           execute_fault(adapter, task, row, root, run),
         {:ok, final_digest} <- Fixture.digest_directory(root),
         {:ok, storage_bytes} <- Fixture.storage_bytes(root) do
      record =
        adapter_evidence
        |> Map.put_new("record_status", "completed")
        |> Map.put_new("raw_evidence_digest", evidence_digest(adapter_evidence))
        |> Map.put_new("artifact_digests", [])
        |> Map.merge(
          fault_metadata(
            manifest,
            task,
            row,
            run,
            opts,
            initial_digest,
            final_digest,
            elapsed_us,
            cpu_us,
            storage_bytes
          )
        )

      case Evidence.validate_fault(manifest, record) do
        :ok -> {:ok, record}
        {:error, errors} -> {:error, {:harness_failure, {:invalid_fault_evidence, errors}}}
      end
    else
      {:error, {:adapter_error, _reason} = reason} -> {:error, {:harness_failure, reason}}
      {:error, {:fault_hook, _reason} = reason} -> {:error, {:harness_failure, reason}}
      {:error, _reason} = error -> error
    end
  end

  defp execute_fault(adapter, task, row, root, run) do
    parent = self()
    reference = make_ref()

    hook = fn barrier_id, facts ->
      send(parent, {:benchmark_fault_hook, reference, barrier_id, facts})

      if barrier_id == row["barrier_id"] do
        {:inject, row["crash_target"]}
      else
        {:error, {:unexpected_barrier, row["barrier_id"], barrier_id}}
      end
    end

    {elapsed_us, cpu_us, result} =
      timed(fn ->
        call_adapter(adapter, task, root, %{
          kind: :fault,
          condition: run["condition"],
          row: row,
          run_index: run["run_index"],
          fault_hook: hook
        })
      end)

    with {:ok, evidence} <- result,
         {:ok, facts} <- collect_fault_hook(reference, row["barrier_id"]) do
      {:ok, Map.put(evidence, "fault_hook_facts", facts), elapsed_us, cpu_us}
    end
  end

  defp fault_metadata(
         manifest,
         task,
         row,
         run,
         opts,
         initial_digest,
         final_digest,
         elapsed_us,
         cpu_us,
         storage_bytes
       ) do
    %{
      "schema" => Evidence.fault_schema(),
      "preregistration_version" => manifest.data["preregistration_version"],
      "seed_round" => manifest.data["beacon"]["round"],
      "seed_digest" => manifest.data["seed"]["sha256"],
      "corpus_manifest_digest" => manifest.sha256,
      "task_id" => task["id"],
      "row_id" => row["row_id"],
      "operation_class" => row["operation_class"],
      "scope_id" => manifest.data["scope_id"],
      "exposure_split" => task["exposure_split"],
      "fixture_commit" => task["fixture"]["fixture_commit"],
      "initial_workspace_digest" => initial_digest,
      "initial_reset_verified" => initial_digest == task["fixture"]["initial_workspace_sha256"],
      "condition" => run["condition"],
      "target_commit" => Keyword.fetch!(opts, :target_commit),
      "adapter_digest" => Keyword.fetch!(opts, :adapter_digest),
      "run_index" => run["run_index"],
      "order_index" => run["order_index"],
      "fault_type" => row["fault_type"],
      "barrier_id" => row["barrier_id"],
      "killed_owner" => row["crash_target"],
      "delivered_messages" => row["delivered_messages"],
      "dropped_messages" => row["dropped_messages"],
      "surviving_storage" => row["surviving_storage"],
      "restart_order" => row["restart_order"],
      "observation_deadline_ms" => row["observation_deadline_ms"],
      "final_workspace_digest" => final_digest,
      "expected_workspace_digest" => task["fixture"]["expected_no_fault_workspace_sha256"],
      "causal_terminal_evidence_expected" => row["causal_terminal_evidence_expected_to_survive"],
      "elapsed_ms" => div(elapsed_us, 1_000),
      "cpu_ms" => div(cpu_us, 1_000),
      "storage_bytes" => storage_bytes
    }
  end

  defp collect_fault_hook(reference, expected_barrier) do
    case drain_fault_hooks(reference, []) do
      [{^expected_barrier, facts}] ->
        {:ok, facts}

      [] ->
        {:error, {:fault_hook, :not_reached}}

      [{barrier, _facts}] ->
        {:error, {:fault_hook, {:unexpected_barrier, expected_barrier, barrier}}}

      calls ->
        {:error, {:fault_hook, {:called_more_than_once, Enum.map(calls, &elem(&1, 0))}}}
    end
  end

  defp call_adapter(adapter, task, root, context) do
    case adapter.execute(task, root, context) do
      {:ok, evidence} when is_map(evidence) -> {:ok, evidence}
      {:ok, evidence} -> {:error, {:adapter_error, {:invalid_evidence, evidence}}}
      {:error, reason} -> {:error, {:adapter_error, reason}}
      other -> {:error, {:adapter_error, {:invalid_return, other}}}
    end
  rescue
    error -> {:error, {:adapter_error, {:exception, error, __STACKTRACE__}}}
  catch
    kind, reason -> {:error, {:adapter_error, {kind, reason}}}
  end

  defp drain_fault_hooks(reference, calls) do
    receive do
      {:benchmark_fault_hook, ^reference, barrier, facts} ->
        drain_fault_hooks(reference, [{barrier, facts} | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end

  defp timed(fun) do
    wall_start = System.monotonic_time(:microsecond)
    {cpu_start, _since_last} = :erlang.statistics(:runtime)
    result = fun.()
    {cpu_end, _since_last} = :erlang.statistics(:runtime)

    {max(System.monotonic_time(:microsecond) - wall_start, 0),
     max((cpu_end - cpu_start) * 1_000, 0), result}
  end

  defp condition_run_index("baseline", order_index) when order_index in [1, 4, 5],
    do: %{1 => 1, 4 => 2, 5 => 3}[order_index]

  defp condition_run_index("receipts", order_index) when order_index in [2, 3, 6],
    do: %{2 => 1, 3 => 2, 6 => 3}[order_index]

  defp evidence_digest(value) do
    value
    |> JSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
