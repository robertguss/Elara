defmodule Elara.Benchmark.ElaraAdapter do
  @moduledoc false

  @behaviour Elara.Benchmark.Adapter

  alias Elara.Benchmark.{Fixture, Manifest, Qualification, Runner}

  @baseline_commit "23e603550253c69846795b13cc2f2670f1122e21"
  @receipts_commit "9ff416f2c22327c5ef38edcd52a9e89108fbc726"
  @runner_path "priv/benchmark/elara_target_runner.exs"
  @adapter_path "lib/elara/benchmark/elara_adapter.ex"
  @neutral_runner_path "lib/elara/benchmark/runner.ex"
  @config_key {__MODULE__, :config}
  @conditions ~w(baseline receipts)
  @v3_manifest_sha256 "4129ae964daf35469499dc9506ace9fa89db0c9f00a20826dfc6790edd5b5491"

  @spec target_commits() :: %{String.t() => String.t()}
  def target_commits do
    %{"baseline" => @baseline_commit, "receipts" => @receipts_commit}
  end

  @spec prepare(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def prepare(repo_root, state_root) when is_binary(repo_root) and is_binary(state_root) do
    repo_root = Path.expand(repo_root)
    state_root = Path.expand(state_root)

    with :ok <- validate_state_root(repo_root, state_root),
         :ok <- File.mkdir_p(state_root),
         :ok <- verify_support_files(repo_root),
         {:ok, targets} <- prepare_targets(repo_root, state_root) do
      {:ok,
       %{
         repo_root: repo_root,
         state_root: state_root,
         runner_path: Path.join(repo_root, @runner_path),
         targets: targets,
         evidence_sink: nil,
         fault_authorization: nil
       }}
    end
  end

  @spec with_config(map(), (-> result)) :: result when result: var
  def with_config(config, fun) when is_map(config) and is_function(fun, 0) do
    previous = Process.get(@config_key)
    Process.put(@config_key, config)

    try do
      fun.()
    after
      if previous, do: Process.put(@config_key, previous), else: Process.delete(@config_key)
    end
  end

  @spec authorize_confirmatory(map(), Manifest.t()) :: {:ok, map()} | {:error, term()}
  def authorize_confirmatory(config, %Manifest{
        sha256: @v3_manifest_sha256,
        tasks: tasks,
        rows: rows,
        data: %{
          "schema" => "elara.exp003.corpus.v3",
          "preregistration_version" => "ER-3/FND-2-v3"
        }
      })
      when is_map(config) do
    {:ok,
     Map.put(config, :fault_authorization, %{
       mode: :confirmatory,
       source_manifest_sha256: @v3_manifest_sha256,
       tasks: tasks,
       rows: rows
     })}
  end

  def authorize_confirmatory(_config, %Manifest{}),
    do: {:error, :confirmatory_manifest_not_frozen_v3}

  @spec mapping(map()) :: {:ok, map()} | {:error, term()}
  def mapping(%{"plan" => %{"steps" => [step], "scripted_provider" => [call, final]}}) do
    with {:ok, tool_name, tool_arguments, constraints} <- map_step(step),
         "tool_call" <- call["kind"],
         ^tool_name <- tool_name(call["operation_kind"]),
         "assistant_text" <- final["kind"],
         tool_call_id when is_binary(tool_call_id) <- call["tool_call_id"],
         final_text when is_binary(final_text) <- final["content"] do
      {:ok,
       %{
         "operation_kind" => step["operation_kind"],
         "tool_name" => tool_name,
         "tool_call_id" => tool_call_id,
         "tool_arguments" => tool_arguments,
         "execution_constraints" => constraints,
         "final_assistant_text" => final_text
       }}
    else
      value -> {:error, {:invalid_frozen_plan, value}}
    end
  end

  def mapping(_task), do: {:error, :invalid_frozen_plan}

  @impl true
  def execute(task, cwd, %{kind: :fault, condition: condition, row: row} = context)
      when condition in @conditions do
    with {:ok, config} <- fetch_config(),
         :ok <- authorize_fault(task, row, config),
         {:ok, target} <- fetch_target(config, condition),
         {:ok, mapped} <- mapping(task),
         {:ok, observation} <- run_target(config, target, task, mapped, cwd, context),
         {:ok, final_digest} <- Fixture.digest_directory(cwd) do
      deliver_observation(config.evidence_sink, observation)
      {:ok, fault_evidence(observation, task, row, condition, final_digest)}
    end
  end

  def execute(task, cwd, %{kind: :no_fault, condition: condition} = context)
      when condition in @conditions do
    with {:ok, config} <- fetch_config(),
         {:ok, target} <- fetch_target(config, condition),
         {:ok, mapped} <- mapping(task),
         {:ok, observation} <- run_target(config, target, task, mapped, cwd, context) do
      deliver_observation(config.evidence_sink, observation)
      {:ok, %{"outcome" => observation["observed_outcome"]}}
    end
  end

  def execute(_task, _cwd, context), do: {:error, {:unsupported_context, context}}

  @spec qualify_faults(Manifest.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def qualify_faults(%Manifest{} = source, config, workspace_root)
      when is_map(config) and is_binary(workspace_root) do
    with {:ok, manifest} <- Qualification.manifest(source),
         {:ok, no_fault_records} <-
           execute_qualification_no_fault(manifest, config, workspace_root),
         {:ok, records} <- execute_qualification_schedule(manifest, config, workspace_root),
         :ok <- validate_qualification_records(manifest, no_fault_records, records) do
      {:ok, qualification_report(source, manifest, config, no_fault_records, records)}
    end
  end

  defp execute_qualification_no_fault(manifest, config, workspace_root) do
    runs =
      manifest.data["selection"]["selected_task_ids"]
      |> Enum.flat_map(fn task_id ->
        Enum.map(@conditions, fn condition ->
          %{
            "task_id" => task_id,
            "condition" => condition,
            "phase" => "measured",
            "run_index" => 1
          }
        end)
      end)
      |> Enum.with_index(1)

    with_config(config, fn ->
      Enum.reduce_while(runs, {:ok, []}, fn {run, order_index}, {:ok, records} ->
        run = Map.put(run, "order_index", order_index)

        case Runner.run_no_fault(manifest, run, adapter: __MODULE__, root: workspace_root) do
          {:ok, record} -> {:cont, {:ok, [record | records]}}
          {:error, reason} -> {:halt, {:error, {:no_fault_qualification_failed, run, reason}}}
        end
      end)
      |> then(fn
        {:ok, records} -> {:ok, Enum.reverse(records)}
        error -> error
      end)
    end)
  end

  defp execute_qualification_schedule(manifest, config, workspace_root) do
    adapter_digest = file_sha256!(config.repo_root, @adapter_path)

    with_config(config, fn ->
      manifest
      |> Runner.fault_schedule()
      |> Enum.reduce_while({:ok, []}, fn run, {:ok, records} ->
        opts = [
          adapter: __MODULE__,
          root: workspace_root,
          target_commit: config.targets[run["condition"]].commit,
          adapter_digest: adapter_digest
        ]

        case Runner.run_fault(manifest, run, opts) do
          {:ok, record} -> {:cont, {:ok, [record | records]}}
          {:error, reason} -> {:halt, {:error, {:fault_qualification_failed, run, reason}}}
        end
      end)
      |> then(fn
        {:ok, records} -> {:ok, Enum.reverse(records)}
        error -> error
      end)
    end)
  end

  defp validate_qualification_records(manifest, no_fault_records, records) do
    grouped = Enum.group_by(records, &{&1["row_id"], &1["condition"]})

    invalid_records =
      Enum.reject(records, &valid_qualification_record?(manifest, &1))

    inconsistent_groups =
      Enum.reject(grouped, fn {_key, repetitions} ->
        length(repetitions) == 3 and
          repetitions |> Enum.map(&semantic_projection/1) |> Enum.uniq() |> length() == 1
      end)

    errors =
      []
      |> require_qualification(length(no_fault_records) == 6, :incomplete_no_fault_qualification)
      |> require_qualification(
        Enum.all?(no_fault_records, &(&1["workspace_correct"] and &1["outcome_correct"])),
        :no_fault_non_equivalence
      )
      |> require_qualification(length(records) == 72, :incomplete_fault_qualification)
      |> require_qualification(
        Enum.all?(records, &(&1["exposure_split"] == "development_adapter_fixture")),
        :confirmatory_fault_exposure
      )
      |> require_qualification(
        invalid_records == [],
        {:invalid_fault_semantics, Enum.map(invalid_records, &qualification_failure/1)}
      )
      |> require_qualification(
        inconsistent_groups == [],
        {:inconsistent_repetitions, Enum.map(inconsistent_groups, &elem(&1, 0))}
      )

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  defp valid_qualification_record?(manifest, record) do
    record["initial_reset_verified"] and record["harness_errors"] == [] and
      record["safety_disqualifiers"] == [] and record["external_mutation_count"] <= 1 and
      record["callback_attempt_count"] <= 1 and
      record["primary_recovery_class"] ==
        manifest.rows[record["row_id"]]["expected_primary_recovery_class"][record["condition"]] and
      record["safe_next_action_observed"] ==
        manifest.rows[record["row_id"]]["expected_safe_action"][record["condition"]] and
      record["last_durable_fact"] ==
        manifest.rows[record["row_id"]]["last_durable_fact"][record["condition"]] and
      record["historical_execution_knowledge"] ==
        manifest.rows[record["row_id"]]["historical_execution_knowledge"]
  end

  defp qualification_failure(record) do
    Map.take(record, ~w(
      row_id condition run_index initial_reset_verified harness_errors safety_disqualifiers
      external_mutation_count callback_attempt_count primary_recovery_class
      final_workspace_digest workspace_observations session_classification
    ))
  end

  defp semantic_projection(record) do
    Map.take(record, ~w(
      condition
      row_id
      final_workspace_digest
      workspace_observations
      causal_terminal_evidence_observed
      session_classification
      safe_next_action_observed
      admission_count
      callback_attempt_count
      external_mutation_count
      session_result_count
      primary_recovery_class
      safety_disqualifiers
      harness_errors
    ))
  end

  defp qualification_report(source, manifest, config, no_fault_records, records) do
    by_class_and_fault =
      records
      |> Enum.group_by(&{&1["operation_class"], &1["fault_type"]})
      |> Map.new(fn {{class, fault}, entries} ->
        {"#{class}:#{fault}",
         %{
           "run_count" => length(entries),
           "conditions" => Enum.frequencies_by(entries, & &1["condition"]),
           "classes" => Enum.frequencies_by(entries, & &1["primary_recovery_class"])
         }}
      end)

    %{
      "schema" => "elara.exp003.internal-adapter-qualification-report.v1",
      "source_manifest_sha256" => source.sha256,
      "qualification_manifest_sha256" => manifest.sha256,
      "qualification_schema" => Qualification.schema(),
      "targets" => target_report(config.targets),
      "configuration" => configuration_report(),
      "adapter" => %{
        "source" => @adapter_path,
        "sha256" => file_sha256!(config.repo_root, @adapter_path),
        "target_runner_source" => @runner_path,
        "target_runner_sha256" => file_sha256!(config.repo_root, @runner_path),
        "neutral_runner_source" => @neutral_runner_path,
        "neutral_runner_sha256" => file_sha256!(config.repo_root, @neutral_runner_path)
      },
      "command" =>
        "mix run priv/benchmark/qualify_internal_adapter.exs -- <manifest> <state> <workspace> <output>",
      "no_fault" => %{
        "run_count" => length(no_fault_records),
        "all_equivalent" =>
          Enum.all?(no_fault_records, &(&1["workspace_correct"] and &1["outcome_correct"])),
        "records_sha256" => sha256(JSON.encode!(no_fault_records))
      },
      "fault_qualification" => %{
        "run_count" => length(records),
        "row_count" => map_size(manifest.rows),
        "repetitions_per_condition" => 3,
        "matrix" => by_class_and_fault,
        "records_sha256" => sha256(JSON.encode!(records)),
        "convergence_ms" => %{
          "knowledge_min" => records |> Enum.map(& &1["knowledge_convergence_ms"]) |> Enum.min(),
          "knowledge_max" => records |> Enum.map(& &1["knowledge_convergence_ms"]) |> Enum.max(),
          "terminal_min" =>
            records
            |> Enum.map(& &1["terminal_convergence_ms"])
            |> Enum.reject(&is_nil/1)
            |> Enum.min(),
          "terminal_max" =>
            records
            |> Enum.map(& &1["terminal_convergence_ms"])
            |> Enum.reject(&is_nil/1)
            |> Enum.max()
        }
      },
      "exposure" => %{
        "development_fault_runs" => length(records),
        "v3_confirmatory_fault_runs" => 0,
        "B_or_T_calculated" => false,
        "statement" =>
          "All injected faults used non-scored development_adapter_fixture tasks. Held-out v3 task IDs were rejected by the adapter guard and never fault-executed."
      },
      "limitations" => [
        "Baseline barriers are nearest-existing instrumented router seams and remain N/A/non-equivalent to receipt-native durable seams.",
        "The adapter kills target-owned processes and requests native reopen/replacement APIs; it does not synthesize terminal evidence or retry callbacks.",
        "Qualification proves deterministic capability on development fixtures, not confirmatory effect size.",
        "The receipt target uses the research-only Elara.Effect.TestExecutor."
      ]
    }
  end

  defp require_qualification(errors, true, _reason), do: errors
  defp require_qualification(errors, false, reason), do: [reason | errors]

  @spec prove_no_fault(Manifest.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def prove_no_fault(%Manifest{} = manifest, config, workspace_root)
      when is_map(config) and is_binary(workspace_root) do
    reference = make_ref()
    parent = self()
    sink = fn evidence -> send(parent, {reference, evidence}) end
    config = %{config | evidence_sink: sink}

    runs =
      manifest.data["selection"]["selected_task_ids"]
      |> Enum.flat_map(fn task_id ->
        Enum.map(@conditions, &%{"task_id" => task_id, "condition" => &1})
      end)
      |> Enum.with_index(1)

    result =
      with_config(config, fn ->
        Enum.reduce_while(runs, {:ok, []}, fn {run, order_index}, {:ok, entries} ->
          run =
            Map.merge(run, %{
              "phase" => "measured",
              "run_index" => 1,
              "order_index" => order_index
            })

          case Runner.run_no_fault(manifest, run, adapter: __MODULE__, root: workspace_root) do
            {:ok, record} ->
              receive do
                {^reference, observation} ->
                  entry = %{"record" => record, "observation" => observation}
                  {:cont, {:ok, [entry | entries]}}
              after
                1_000 -> {:halt, {:error, {:adapter_observation_missing, run}}}
              end

            {:error, reason} ->
              {:halt, {:error, {run, reason}}}
          end
        end)
      end)

    with {:ok, entries} <- result do
      build_report(manifest, config, Enum.reverse(entries))
    end
  end

  defp prepare_targets(repo_root, state_root) do
    Enum.reduce_while(target_commits(), {:ok, %{}}, fn {condition, commit}, {:ok, targets} ->
      case prepare_target(repo_root, state_root, condition, commit) do
        {:ok, target} -> {:cont, {:ok, Map.put(targets, condition, target)}}
        {:error, reason} -> {:halt, {:error, {condition, reason}}}
      end
    end)
  end

  defp prepare_target(repo_root, state_root, condition, commit) do
    source_root = Path.join([state_root, "targets", condition, "source"])
    build_root = Path.join([state_root, "targets", condition, "build"])

    with {:ok, ^commit} <- git(repo_root, ["rev-parse", "#{commit}^{commit}"]),
         :ok <- replace_with_archive(repo_root, commit, source_root),
         :ok <- File.mkdir_p(build_root),
         :ok <- compile_target(repo_root, source_root, build_root) do
      {:ok,
       %{
         condition: condition,
         commit: commit,
         source_root: source_root,
         build_root: build_root
       }}
    else
      {:ok, actual} -> {:error, {:commit_mismatch, commit, actual}}
      {:error, _reason} = error -> error
    end
  end

  defp replace_with_archive(repo_root, commit, source_root) do
    with {:ok, _removed} <- File.rm_rf(source_root),
         :ok <- File.mkdir_p(source_root),
         {:ok, archive} <- git_archive(repo_root, commit),
         :ok <- extract_archive(archive, source_root) do
      :ok
    end
  end

  defp compile_target(repo_root, source_root, build_root) do
    {output, status} =
      System.cmd("mix", ["compile", "--warnings-as-errors"],
        cd: source_root,
        env: target_env(repo_root, build_root),
        stderr_to_stdout: true
      )

    if status == 0, do: :ok, else: {:error, {:target_compile_failed, status, output}}
  end

  defp run_target(config, target, task, mapped, cwd, context) do
    run_root = run_root(config.state_root, task["id"], context)
    request_path = Path.join(run_root, "request.json")
    output_path = Path.join(run_root, "output.json")

    request = %{
      "schema" => "elara.exp003.internal-adapter-request.v1",
      "condition" => target.condition,
      "target_commit" => target.commit,
      "workspace_root" => Path.expand(cwd),
      "controller_journal_path" => Path.join(run_root, "controller.sqlite3"),
      "executor_ledger_path" => Path.join(run_root, "executor.sqlite3"),
      "task_id" => task["id"],
      "prompt" => task["request"],
      "mapping" => mapped,
      "tool_timeout_ms" => 5_000
    }

    request = fault_request(request, context, run_root)

    with {:ok, _removed} <- File.rm_rf(run_root),
         :ok <- File.mkdir_p(run_root),
         :ok <- File.write(request_path, JSON.encode!(request)),
         {:ok, process_output} <-
           execute_target(config, target, request_path, output_path, context),
         {:ok, observation} <- decode_target_output(output_path) do
      {:ok, Map.put(observation, "process_output_sha256", sha256(process_output))}
    end
  end

  defp fault_request(request, %{kind: :fault, row: row}, run_root) do
    Map.merge(request, %{
      "mode" => "fault_qualification",
      "row" => row,
      "session_root" => Path.join(run_root, "sessions"),
      "barrier_event_path" => Path.join(run_root, "request.json.barrier.json"),
      "injection_command_path" => Path.join(run_root, "request.json.command.json")
    })
  end

  defp fault_request(request, _context, _run_root), do: request

  defp execute_target(config, target, request_path, output_path, %{kind: :fault} = context) do
    event_path = request_path <> ".barrier.json"
    command_path = request_path <> ".command.json"

    task =
      Task.async(fn ->
        target_command(config, target, request_path, output_path)
      end)

    convergence_deadline = context.row["observation_deadline_ms"]
    startup_deadline = convergence_deadline + 5_000

    result =
      with {:ok, event} <- await_barrier(task, event_path, startup_deadline),
           :ok <- validate_barrier_event(event, context.row),
           {:inject, owner} <-
             context.fault_hook.(event["barrier_id"], event["facts"]),
           true <- owner == context.row["crash_target"],
           :ok <-
             write_atomic(command_path, JSON.encode!(%{"action" => "inject", "owner" => owner})),
           {:ok, command_result} <- await_target(task, convergence_deadline + 3_000) do
        {:ok, command_result}
      else
        false -> {:error, :fault_owner_mismatch}
        {:error, _reason} = error -> error
        other -> {:error, {:fault_protocol_failed, other}}
      end

    if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    result
  end

  defp execute_target(config, target, request_path, output_path, _context) do
    target_command(config, target, request_path, output_path)
  end

  defp target_command(config, target, request_path, output_path) do
    result =
      System.cmd(
        "mix",
        [
          "run",
          "--no-compile",
          config.runner_path,
          "--",
          request_path,
          output_path
        ],
        cd: target.source_root,
        env: target_env(config.repo_root, target.build_root),
        stderr_to_stdout: true
      )

    case result do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:target_run_failed, status, output}}
    end
  end

  defp await_barrier(task, path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_barrier(task, path, deadline)
  end

  defp do_await_barrier(task, path, deadline) do
    case File.read(path) do
      {:ok, encoded} ->
        case JSON.decode(encoded) do
          {:ok, event} -> {:ok, event}
          {:error, reason} -> {:error, {:invalid_barrier_event, reason}}
        end

      {:error, :enoent} ->
        case Task.yield(task, 0) do
          {:ok, result} ->
            {:error, {:target_exited_before_barrier, result}}

          {:exit, reason} ->
            {:error, {:target_exited_before_barrier, reason}}

          nil ->
            if System.monotonic_time(:millisecond) < deadline do
              Process.sleep(10)
              do_await_barrier(task, path, deadline)
            else
              {:error, :fault_barrier_timeout}
            end
        end

      {:error, reason} ->
        {:error, {:barrier_read_failed, reason}}
    end
  end

  defp await_target(task, timeout_ms) do
    case Task.yield(task, timeout_ms) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:target_task_exit, reason}}
      nil -> {:error, :target_completion_timeout}
    end
  end

  defp validate_barrier_event(
         %{
           "schema" => "elara.exp003.fault-barrier.v1",
           "barrier_id" => barrier,
           "facts" => facts
         },
         %{"barrier_id" => barrier}
       )
       when is_map(facts),
       do: :ok

  defp validate_barrier_event(event, row),
    do: {:error, {:invalid_barrier_event, row["barrier_id"], event}}

  defp write_atomic(path, contents) do
    temporary = path <> ".tmp"

    with :ok <- File.write(temporary, contents),
         :ok <- File.rename(temporary, path) do
      :ok
    end
  end

  defp authorize_fault(task, row, config) do
    cond do
      development_fault?(task, row) ->
        :ok

      confirmatory_fault?(task, row, Map.get(config, :fault_authorization)) ->
        :ok

      true ->
        {:error, :confirmatory_fault_execution_forbidden}
    end
  end

  defp development_fault?(task, row) do
    task["exposure_split"] == "development_adapter_fixture" and
      row["exposure_split"] == "development_adapter_fixture" and
      String.starts_with?(row["row_id"] || "", "QUAL-") and
      row["fault_role"] == "development_qualification"
  end

  defp confirmatory_fault?(
         task,
         row,
         %{
           mode: :confirmatory,
           source_manifest_sha256: @v3_manifest_sha256,
           tasks: tasks,
           rows: rows
         }
       ) do
    task_id = task["id"]
    row_id = row["row_id"]

    task["exposure_split"] == "held_out_relative_to_target_implementation" and
      row["task_id"] == task_id and
      not String.starts_with?(row["row_id"] || "", "QUAL-") and
      row["fault_role"] in ~w(primary secondary) and
      Map.get(tasks, task_id) == task and
      Map.get(rows, row_id) == row
  end

  defp confirmatory_fault?(_task, _row, _authorization), do: false

  defp fault_evidence(observation, task, row, condition, final_digest) do
    fixture = task["fixture"]
    pre_digest = fixture["initial_workspace_sha256"]
    post_digest = fixture["expected_no_fault_workspace_sha256"]
    expected_workspace = row["expected_converged_workspace_by_condition"][condition]

    {workspace_observation, external_mutation_count} =
      case final_digest do
        ^pre_digest ->
          {"pre_effect_workspace", 0}

        ^post_digest
        when expected_workspace in ~w(fault_target_postcondition complete_task_workspace) ->
          {expected_workspace, 1}

        ^post_digest ->
          {"fault_target_postcondition", 1}

        _other ->
          {"unexpected_workspace", 0}
      end

    initial_disqualifiers =
      []
      |> maybe_add(workspace_observation == "unexpected_workspace", "unexpected_workspace_digest")
      |> maybe_add(workspace_observation != expected_workspace, "unexpected_converged_workspace")
      |> maybe_add(observation["barrier_call_count"] != 1, "barrier_call_count_not_1")

    callback_attempt_count =
      if condition == "baseline",
        do: get_in(observation, ["barrier_facts", "local_executor_return_count"]),
        else: observation["callback_attempt_count"]

    primary_class =
      classify_fault(
        row,
        condition,
        observation,
        external_mutation_count,
        callback_attempt_count,
        initial_disqualifiers
      )

    expected_class = row["expected_primary_recovery_class"][condition]

    safety_disqualifiers =
      maybe_add(initial_disqualifiers, primary_class != expected_class, "recovery_class_mismatch")

    harness_errors =
      maybe_add(
        observation["harness_errors"],
        primary_class == "harness_failure",
        "unclassified_recovery"
      )

    safe_action =
      if primary_class == expected_class and recovery_actions_valid?(row, condition, observation) do
        observed_safe_action(condition, row["fault_type"])
      else
        "no validated safe action"
      end

    Map.merge(observation, %{
      "workspace_observations" => workspace_observation,
      "last_durable_fact" => observed_last_durable_fact(condition, row["fault_type"]),
      "historical_execution_knowledge" => observed_historical_knowledge(row["fault_type"]),
      "safe_next_action_expected" => row["expected_safe_action"][condition],
      "safe_next_action_observed" => safe_action,
      "callback_attempt_count" => callback_attempt_count,
      "external_mutation_count" => external_mutation_count,
      "primary_recovery_class" => primary_class,
      "safety_disqualifiers" => safety_disqualifiers,
      "harness_errors" => harness_errors,
      "artifact_digests" => [observation["process_output_sha256"]]
    })
  end

  defp classify_fault(row, condition, observation, external_count, callback_count, []) do
    fault = row["fault_type"]
    causal? = observation["causal_terminal_evidence_observed"]
    executor = observation["executor_facts"]

    cond do
      condition == "baseline" and fault == "F3" and external_count == 1 and
        callback_count == 1 and not causal? ->
        "ambiguous_no_safe_action"

      condition == "baseline" and fault in ~w(F1 F2) and external_count == 0 and
        callback_count == 0 and not causal? ->
        "manual_recovery"

      condition == "baseline" and fault == "F4" and external_count == 1 and
        callback_count == 1 and not causal? ->
        "manual_recovery"

      condition == "receipts" and fault == "F3" and external_count == 1 and
        callback_count == 1 and not causal? and executor["status"] == "accepted" and
        executor["terminal_count"] == 0 and
          observation["session_classification"] == "indeterminate" ->
        "automatic_safe_indeterminate"

      condition == "receipts" and fault in ~w(F1 F2 F4) and external_count == 1 and
        callback_count == 1 and causal? and executor["status"] in ~w(completed failed) and
          executor["terminal_count"] == 1 ->
        "automatic_terminal"

      true ->
        "harness_failure"
    end
  end

  defp classify_fault(_row, _condition, _observation, _external_count, _callback_count, _errors),
    do: "harness_failure"

  defp recovery_actions_valid?(row, "baseline", observation) do
    actions = observation["recovery_actions"]

    case row["crash_target"] do
      "controller" ->
        actions == ~w(kill_controller reopen_persisted_session native_transcript_repair)

      "selected_worker_or_tool_owner" ->
        actions == ~w(kill_selected_tool_owner observe_native_session_failure)
    end
  end

  defp recovery_actions_valid?(%{"fault_type" => "F1"}, "receipts", observation) do
    observation["recovery_actions"] ==
      ~w(kill_controller reopen_persisted_session native_same_identity_reconciliation)
  end

  defp recovery_actions_valid?(%{"fault_type" => fault}, "receipts", observation)
       when fault in ~w(F2 F3) do
    observation["recovery_actions"] ==
      ~w(kill_original_executor_process reopen_same_logical_executor replace_effect_executor)
  end

  defp recovery_actions_valid?(%{"fault_type" => "F4"}, "receipts", observation) do
    observation["recovery_actions"] ==
      ~w(kill_controller reopen_persisted_session native_terminal_reconciliation)
  end

  defp observed_last_durable_fact("baseline", "F1"),
    do: "nearest existing request evidence; target-only intent seam N/A"

  defp observed_last_durable_fact("baseline", "F2"),
    do: "dispatch observed; target acceptance seam N/A"

  defp observed_last_durable_fact("baseline", "F3"),
    do: "effect may have occurred; target receipt seam N/A"

  defp observed_last_durable_fact("baseline", "F4"),
    do: "terminal reached volatile controller boundary; target observation seam N/A"

  defp observed_last_durable_fact("receipts", "F1"),
    do: "controller intent committed; executor start unknown"

  defp observed_last_durable_fact("receipts", "F2"),
    do: "accepted on original executor with attempt 0"

  defp observed_last_durable_fact("receipts", "F3"),
    do: "attempt 1 without causal terminal proof"

  defp observed_last_durable_fact("receipts", "F4"),
    do: "causal terminal observation durably synchronized"

  defp observed_historical_knowledge(fault) when fault in ~w(F1 F2), do: "not_invoked at barrier"
  defp observed_historical_knowledge("F3"), do: "invoked; causal terminal outcome unknown"

  defp observed_historical_knowledge("F4"),
    do: "invoked with causal terminal evidence only for receipts condition"

  defp observed_safe_action("baseline", "F3"), do: "no unique automatic safe action"
  defp observed_safe_action("baseline", _fault), do: "manual recovery under baseline semantics"

  defp observed_safe_action("receipts", "F1"),
    do: "same ID/digest dispatch once to original owner, then no action"

  defp observed_safe_action("receipts", "F2"),
    do: "original owner continues callback once; never fail over"

  defp observed_safe_action("receipts", "F3"),
    do: "postcondition_satisfied_no_retry; never invoke/submit/fail over"

  defp observed_safe_action("receipts", "F4"),
    do: "persist exactly one session result; no callback"

  defp maybe_add(items, true, item), do: [item | items]
  defp maybe_add(items, false, _item), do: items

  defp decode_target_output(output_path) do
    with {:ok, encoded} <- File.read(output_path),
         {:ok, decoded} <- JSON.decode(encoded) do
      case decoded do
        %{"status" => "ok"} = observation -> {:ok, observation}
        %{"status" => "error"} = error -> {:error, {:target_reported_error, error}}
        other -> {:error, {:invalid_target_output, other}}
      end
    else
      {:error, reason} -> {:error, {:target_output_failed, reason}}
    end
  end

  defp build_report(manifest, config, entries) do
    grouped = Enum.group_by(entries, & &1["record"]["task_id"])

    tasks =
      Enum.map(manifest.data["selection"]["selected_task_ids"], fn task_id ->
        task = manifest.tasks[task_id]
        by_condition = Map.new(grouped[task_id], &{&1["record"]["condition"], &1})
        baseline = semantic_evidence(by_condition["baseline"])
        receipts = semantic_evidence(by_condition["receipts"])

        %{
          "task_id" => task_id,
          "operation_class" => task["operation_class"],
          "fixture_commit" => task["fixture"]["fixture_commit"],
          "mapping" => unwrap_mapping(task),
          "expected_outcome" => expected_outcome(task),
          "expected_workspace_sha256" => task["fixture"]["expected_no_fault_workspace_sha256"],
          "baseline" => baseline,
          "receipts" => receipts,
          "classification" => classify(task, baseline, receipts)
        }
      end)

    eligible_task_ids =
      tasks
      |> Enum.filter(&(&1["classification"] == "equivalent"))
      |> Enum.map(& &1["task_id"])
      |> MapSet.new()

    denominator =
      manifest.data["fault_rows"]
      |> Enum.filter(&MapSet.member?(eligible_task_ids, &1["task_id"]))
      |> Enum.map(& &1["row_id"])

    report = %{
      "schema" => "elara.exp003.internal-adapter-equivalence.v1",
      "manifest_sha256" => manifest.sha256,
      "targets" => target_report(config.targets),
      "runtime" => hd(entries)["observation"]["runtime"],
      "configuration" => configuration_report(),
      "adapter" => %{
        "source" => @adapter_path,
        "sha256" => file_sha256!(config.repo_root, @adapter_path),
        "target_runner_source" => @runner_path,
        "target_runner_sha256" => file_sha256!(config.repo_root, @runner_path),
        "neutral_runner_source" => @neutral_runner_path,
        "neutral_runner_sha256" => file_sha256!(config.repo_root, @neutral_runner_path)
      },
      "tasks" => tasks,
      "summary" => %{
        "task_count" => length(tasks),
        "equivalent" => Enum.count(tasks, &(&1["classification"] == "equivalent")),
        "non_equivalent" => Enum.count(tasks, &(&1["classification"] == "non_equivalent")),
        "adapter_failure" => 0
      },
      "internal_paired_denominator" => %{
        "status" => if(length(denominator) == 20, do: "eligible", else: "ineligible"),
        "row_count" => length(denominator),
        "row_ids" => denominator
      },
      "hook_disclosure" => hook_disclosure(),
      "shell_timeout_qualification" =>
        "The plan's unaccelerated timeout_ms=5000 is represented by session " <>
          "tool_timeout_ms=5000. Neither pinned builtin consumes the plan argument directly, " <>
          "and ER-2 did not prove production enforcement of that exact timeout. The receipt " <>
          "sidecar also has its pinned 1000 ms recovery wait. No timeout claim is made here.",
      "tool_result_payload_qualification" =>
        "Equivalence uses the frozen outcome category and workspace digest. Opaque shell output " <>
          "bodies are not compared because commands such as mix test may emit nondeterministic " <>
          "metadata; result kind, transcript shape, and exact plan consumption are compared.",
      "exposure" => %{
        "fault_rows_executed" => 0,
        "B_or_T_calculated" => false,
        "adapter_fault_execution" => "forbidden",
        "statement" =>
          "Only one no-fault execution per selected task and pinned target was run. No fault " <>
            "barrier, recovery score, target tuning, Lemon run, or dogfood run was executed."
      },
      "limitations" => [
        "OS-process and filesystem isolation are behavior-neutral adapter boundaries, not recovery mechanisms.",
        "No-fault equivalence does not prove fault behavior or timing equivalence.",
        "Workspace postconditions do not prove causal job completion.",
        "The receipt target uses the research-only Elara.Effect.TestExecutor."
      ]
    }

    if length(entries) == 24, do: {:ok, report}, else: {:error, :incomplete_equivalence_evidence}
  end

  defp semantic_evidence(%{"record" => record, "observation" => observation}) do
    %{
      "target_commit" => observation["target_commit"],
      "initial_workspace_sha256" => record["initial_workspace_sha256"],
      "final_workspace_sha256" => record["final_workspace_sha256"],
      "workspace_correct" => record["workspace_correct"],
      "observed_outcome" => record["observed_outcome"],
      "outcome_correct" => record["outcome_correct"],
      "provider_plan_consumed" => observation["provider_plan_consumed"],
      "provider_call_count" => observation["provider_call_count"],
      "tool_call_count" => observation["tool_call_count"],
      "session_result_count" => observation["session_result_count"],
      "session_result" => observation["session_result"],
      "session_idle" => observation["session_idle"],
      "transcript_shape" => observation["transcript_shape"],
      "tool_result_kind" => observation["tool_result_kind"],
      "hooks_observed" => observation["hooks_observed"],
      "receipt_evidence" => observation["receipt_evidence"]
    }
  end

  defp classify(task, baseline, receipts) do
    expected = expected_outcome(task)
    expected_shape = ~w(user assistant_tool_call tool_result assistant_text)

    common? =
      Enum.all?([baseline, receipts], fn evidence ->
        evidence["workspace_correct"] and evidence["outcome_correct"] and
          evidence["observed_outcome"] == expected and evidence["provider_plan_consumed"] and
          evidence["provider_call_count"] == 2 and evidence["tool_call_count"] == 1 and
          evidence["session_result_count"] == 1 and evidence["session_result"] == "Task complete." and
          evidence["session_idle"] and evidence["transcript_shape"] == expected_shape
      end)

    receipt? =
      receipts["receipt_evidence"]["admission_count"] == 1 and
        receipts["receipt_evidence"]["callback_attempt_count"] == 1 and
        receipts["receipt_evidence"]["terminal_count"] == 1 and
        receipts["receipt_evidence"]["result_persisted"] and
        receipts["receipt_evidence"]["identity_consistent"]

    baseline? = baseline["receipt_evidence"] == "not_applicable"

    if common? and receipt? and baseline?, do: "equivalent", else: "non_equivalent"
  end

  defp configuration_report do
    %{
      "provider" => "Elara.Provider.Scripted: exactly one tool-call turn then Task complete.",
      "persist" => false,
      "plugins" => [],
      "tools" => ~w(read write edit bash),
      "tool_timeout_ms" => 5_000,
      "workspace" =>
        "fresh exact fixture reset per run; state and SQLite storage outside workspace",
      "environment" => %{
        "LANG" => "C",
        "LC_ALL" => "C",
        "HEX_OFFLINE" => "1",
        "MIX_ENV" => "test for target; frozen shell commands control their own MIX_ENV"
      },
      "baseline_effect_executor" => "not_applicable",
      "receipts_effect_executor" =>
        "isolated Elara.Effect.TestExecutor with one SQLite ledger per task/condition/run",
      "receipts_controller_journal" => "one isolated SQLite journal per task/condition/run",
      "authority" => %{"allowed_capabilities" => "all", "placement" => "local router"}
    }
  end

  defp hook_disclosure do
    %{
      "behavior" =>
        "No-op native target hooks append point names to an isolated Agent. They do not pause, " <>
          "crash, retry, replace an executor, add evidence to the target, or alter recovery.",
      "baseline" => "not_applicable",
      "receipts_expected_order" => ~w(
        before_intent_commit
        after_intent_commit_before_dispatch
        after_receipt_before_accept_commit
        after_accept_commit_before_accept_reply
        after_accept_observation_before_continue
        after_accept_reply_before_callback
        after_external_mutation_before_completion_commit
        after_completion_commit_before_completion_reply
        after_completion_reply_before_session_result_persist
      )
    }
  end

  defp target_report(targets) do
    Map.new(@conditions, fn condition ->
      target = targets[condition]

      {condition,
       %{
         "commit" => target.commit,
         "source_materialization" => "git archive of exact commit",
         "execution_boundary" => "separate OS BEAM with isolated MIX_BUILD_PATH"
       }}
    end)
  end

  defp map_step(%{"operation_kind" => "write", "arguments" => args}) do
    with "elara.declarative_write.v1" <- args["schema"],
         path when is_binary(path) <- args["path"],
         content when is_binary(content) <- get_in(args, ["desired", "content"]) do
      {:ok, "write", %{"path" => path, "content" => content},
       %{"source_schema" => args["schema"]}}
    else
      value -> {:error, {:invalid_write_plan, value}}
    end
  end

  defp map_step(%{"operation_kind" => "patch", "arguments" => args}) do
    with "elara.literal_patch.v1" <- args["schema"],
         path when is_binary(path) <- args["path"],
         old_text when is_binary(old_text) <- args["old_text"],
         new_text when is_binary(new_text) <- args["new_text"] do
      {:ok, "edit", %{"path" => path, "old_text" => old_text, "new_text" => new_text},
       %{"source_schema" => args["schema"]}}
    else
      value -> {:error, {:invalid_patch_plan, value}}
    end
  end

  defp map_step(%{"operation_kind" => "shell", "arguments" => args}) do
    with "elara.opaque_shell.v1" <- args["schema"],
         command when is_binary(command) <- args["command"],
         relative_cwd when is_binary(relative_cwd) <- args["relative_cwd"],
         environment when is_map(environment) <- args["environment"],
         timeout when is_integer(timeout) and timeout > 0 <- args["timeout_ms"] do
      {:ok, "bash", %{"command" => command},
       %{
         "source_schema" => args["schema"],
         "relative_cwd" => relative_cwd,
         "environment" => environment,
         "requested_timeout_ms" => timeout
       }}
    else
      value -> {:error, {:invalid_shell_plan, value}}
    end
  end

  defp map_step(step), do: {:error, {:unsupported_step, step}}

  defp tool_name("write"), do: "write"
  defp tool_name("patch"), do: "edit"
  defp tool_name("shell"), do: "bash"
  defp tool_name(_kind), do: nil

  defp expected_outcome(task) do
    task["plan"]["steps"] |> List.last() |> Map.fetch!("expected_no_fault_outcome")
  end

  defp unwrap_mapping(task) do
    {:ok, mapping} = mapping(task)
    mapping
  end

  defp fetch_config do
    case Process.get(@config_key) do
      config when is_map(config) -> {:ok, config}
      _other -> {:error, :adapter_not_configured}
    end
  end

  defp fetch_target(config, condition) do
    case get_in(config, [:targets, condition]) do
      target when is_map(target) -> {:ok, target}
      _other -> {:error, {:target_not_prepared, condition}}
    end
  end

  defp deliver_observation(nil, _observation), do: :ok
  defp deliver_observation(sink, observation) when is_function(sink, 1), do: sink.(observation)

  defp run_root(state_root, task_id, context) do
    phase =
      case context do
        %{kind: :fault, row: row} -> "fault/#{String.downcase(row["row_id"])}"
        _other -> context |> Map.get(:phase, "direct") |> to_string()
      end

    index = context |> Map.get(:run_index, 1) |> to_string()

    Path.join([
      state_root,
      "runs",
      String.downcase(task_id),
      context.condition,
      phase,
      index
    ])
  end

  defp target_env(repo_root, build_root) do
    [
      {"HEX_OFFLINE", "1"},
      {"LANG", "C"},
      {"LC_ALL", "C"},
      {"MIX_BUILD_PATH", build_root},
      {"MIX_DEPS_PATH", Path.join(repo_root, "deps")},
      {"MIX_ENV", "test"}
    ]
  end

  defp verify_support_files(repo_root) do
    Enum.reduce_while([@runner_path, @adapter_path, @neutral_runner_path], :ok, fn relative,
                                                                                   :ok ->
      if File.regular?(Path.join(repo_root, relative)) do
        {:cont, :ok}
      else
        {:halt, {:error, {:support_file_missing, relative}}}
      end
    end)
  end

  defp validate_state_root(repo_root, state_root) do
    cond do
      state_root in ["/", repo_root] -> {:error, :unsafe_state_root}
      String.starts_with?(repo_root <> "/", state_root <> "/") -> {:error, :unsafe_state_root}
      true -> :ok
    end
  end

  defp git(repo_root, args) do
    case System.cmd("git", args, cd: repo_root, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:git_failed, args, status, output}}
    end
  end

  defp git_archive(repo_root, commit) do
    case System.cmd("git", ["archive", "--format=tar", commit], cd: repo_root) do
      {archive, 0} -> {:ok, archive}
      {output, status} -> {:error, {:git_archive_failed, status, output}}
    end
  end

  defp extract_archive(archive, source_root) do
    case :erl_tar.extract(
           {:binary, archive},
           [{:cwd, String.to_charlist(source_root)}]
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:archive_extract_failed, reason}}
    end
  end

  defp file_sha256!(root, relative), do: root |> Path.join(relative) |> File.read!() |> sha256()

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
