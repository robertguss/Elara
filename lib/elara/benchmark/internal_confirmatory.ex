defmodule Elara.Benchmark.InternalConfirmatory do
  @moduledoc false

  alias Elara.Benchmark.{ElaraAdapter, Manifest, Qualification, Runner, Scorer}

  @protocol "ER-3/FND-2-v6"
  @report_schema "elara.exp003.internal-confirmatory-report.v1"
  @checkpoint_schema "elara.exp003.internal-confirmatory-checkpoint.v1"
  @manifest_sha256 "b415272e106db54087edbd54500c3544c94ca13b2d42950c0a63b82a38c0973c"
  @entrypoint "priv/benchmark/run_internal_confirmatory.exs"
  @checkpoint_filename "internal-confirmatory-checkpoint.json"
  @source_paths [
    "lib/elara/benchmark/internal_confirmatory.ex",
    "lib/elara/benchmark/elara_adapter.ex",
    "lib/elara/benchmark/runner.ex",
    "lib/elara/benchmark/qualification.ex",
    "lib/elara/benchmark/scorer.ex",
    "lib/elara/benchmark/evidence.ex",
    "lib/elara/benchmark/fixture.ex",
    "lib/elara/benchmark/manifest.ex",
    "priv/benchmark/elara_target_runner.exs",
    @entrypoint,
    "docs/experiments/003-effect-receipt-v6-compatibility.json",
    "mix.lock"
  ]

  @commands %{
    "qualify" =>
      "mix run priv/benchmark/run_internal_confirmatory.exs -- qualify <v6-manifest> <state-root> <workspace-root> <output.json>",
    "execute" =>
      "mix run priv/benchmark/run_internal_confirmatory.exs -- execute <v6-manifest> <qualification.json> <state-root> <workspace-root> <output.json>",
    "replay" =>
      "mix run priv/benchmark/run_internal_confirmatory.exs -- replay <v6-manifest> <execution.json> <score-output.json>"
  }

  @spec qualify(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def qualify(manifest_path, state_root, workspace_root, output_path) do
    run(:qualify, manifest_path, nil, state_root, workspace_root, output_path)
  end

  @spec execute(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def execute(manifest_path, qualification_path, state_root, workspace_root, output_path) do
    run(:execute, manifest_path, qualification_path, state_root, workspace_root, output_path)
  end

  @spec replay(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def replay(manifest_path, report_path, output_path) do
    repo_root = File.cwd!()
    output_path = Path.expand(output_path)

    with {:ok, source} <- load_source(manifest_path),
         {:ok, identities} <- source_identities(repo_root),
         :ok <- require_absent(output_path, :output_path),
         :ok <- require_absent(output_path <> ".tmp", :output_temporary_path),
         {:ok, report, report_bytes} <- read_canonical_json(report_path),
         {:ok, execution_manifest} <- report_manifest(source, report),
         :ok <- validate_report(report, source, execution_manifest, identities),
         score <-
           Scorer.score(
             execution_manifest,
             report["fault_records"],
             report["no_fault_records"]
           ),
         :ok <- validate_authorizing_score(score),
         :ok <- require_score_match(score, report["score"]),
         :ok <- write_atomic(output_path, canonical_json(score), :new) do
      {:ok,
       %{
         "score" => score,
         "report_sha256" => sha256(report_bytes),
         "score_sha256" => sha256(canonical_json(score))
       }}
    end
  end

  @spec canonical_json(term()) :: binary()
  def canonical_json(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(",", fn {key, item} ->
      JSON.encode!(key) <> ":" <> canonical_json(item)
    end)
    |> then(&("{" <> &1 <> "}"))
  end

  def canonical_json(value) when is_list(value) do
    value |> Enum.map_join(",", &canonical_json/1) |> then(&("[" <> &1 <> "]"))
  end

  def canonical_json(value), do: JSON.encode!(value)

  @spec source_identities(String.t()) :: {:ok, map()} | {:error, term()}
  def source_identities(repo_root) do
    Enum.reduce_while(@source_paths, {:ok, %{}}, fn relative, {:ok, identities} ->
      path = Path.join(repo_root, relative)

      case File.read(path) do
        {:ok, contents} ->
          {:cont, {:ok, Map.put(identities, relative, sha256(contents))}}

        {:error, reason} ->
          {:halt, {:error, {:source_identity_failed, relative, reason}}}
      end
    end)
  end

  @spec validate_authorizing_score(map()) :: :ok | {:error, term()}
  def validate_authorizing_score(%{"valid" => true, "status" => "Pass"}), do: :ok

  def validate_authorizing_score(%{"valid" => true, "status" => status}),
    do: {:error, {:non_passing_score, status}}

  def validate_authorizing_score(score), do: {:error, {:invalid_score, score["errors"]}}

  defp run(mode, manifest_path, qualification_path, state_root, workspace_root, output_path) do
    repo_root = File.cwd!()
    state_root = Path.expand(state_root)
    workspace_root = Path.expand(workspace_root)
    output_path = Path.expand(output_path)
    checkpoint_path = Path.join(state_root, @checkpoint_filename)

    with {:ok, source} <- load_source(manifest_path),
         {:ok, identities} <- source_identities(repo_root),
         {:ok, execution_manifest} <- execution_manifest(mode, source),
         {:ok, qualification_identity} <-
           qualification_identity(mode, qualification_path, source, identities),
         :ok <-
           preflight_paths(
             repo_root,
             state_root,
             workspace_root,
             output_path,
             checkpoint_path
           ),
         {:ok, config} <- ElaraAdapter.prepare(repo_root, state_root),
         {:ok, config} <- authorize(mode, config, source),
         :ok <- File.mkdir_p(workspace_root),
         checkpoint = checkpoint(mode, source, execution_manifest),
         {:ok, fault_records, no_fault_records, checkpoint} <-
           orchestrate(execution_manifest, config, workspace_root, checkpoint_path, checkpoint),
         score <- Scorer.score(execution_manifest, fault_records, no_fault_records),
         :ok <- validate_authorizing_score(score),
         {:ok, checkpoint_bytes} <- File.read(checkpoint_path),
         report <-
           report(
             mode,
             source,
             execution_manifest,
             identities,
             qualification_identity,
             fault_records,
             no_fault_records,
             score,
             checkpoint,
             sha256(checkpoint_bytes)
           ),
         :ok <- write_atomic(output_path, canonical_json(report), :new) do
      {:ok, report}
    end
  end

  defp orchestrate(manifest, config, workspace_root, checkpoint_path, checkpoint) do
    adapter_digest =
      config.repo_root
      |> Path.join("lib/elara/benchmark/elara_adapter.ex")
      |> File.read!()
      |> sha256()

    ElaraAdapter.with_config(config, fn ->
      with {:ok, fault_records, checkpoint} <-
             run_schedule(
               :fault,
               Runner.fault_schedule(manifest),
               manifest,
               config,
               workspace_root,
               adapter_digest,
               checkpoint_path,
               checkpoint
             ),
           {:ok, no_fault_records, checkpoint} <-
             run_schedule(
               :no_fault,
               Runner.no_fault_schedule(manifest),
               manifest,
               config,
               workspace_root,
               adapter_digest,
               checkpoint_path,
               checkpoint
             ) do
        {:ok, fault_records, no_fault_records, checkpoint}
      end
    end)
  end

  defp run_schedule(
         kind,
         schedule,
         manifest,
         config,
         workspace_root,
         adapter_digest,
         checkpoint_path,
         checkpoint
       ) do
    schedule
    |> Enum.reduce_while({:ok, [], checkpoint}, fn run, {:ok, records, checkpoint} ->
      started = checkpoint_event(checkpoint, kind, "started", run, nil)
      checkpoint = append_event(checkpoint, started)

      with :ok <- write_atomic(checkpoint_path, canonical_json(checkpoint), :replace),
           {:ok, record} <-
             run_one(kind, manifest, run, config, workspace_root, adapter_digest),
           completed = checkpoint_event(checkpoint, kind, "completed", run, record),
           checkpoint = append_event(checkpoint, completed),
           :ok <- write_atomic(checkpoint_path, canonical_json(checkpoint), :replace) do
        {:cont, {:ok, [record | records], checkpoint}}
      else
        {:error, reason} -> {:halt, {:error, {:run_failed, kind, run, reason}}}
      end
    end)
    |> then(fn
      {:ok, records, checkpoint} -> {:ok, Enum.reverse(records), checkpoint}
      error -> error
    end)
  end

  defp run_one(:fault, manifest, run, config, workspace_root, adapter_digest) do
    Runner.run_fault(manifest, run,
      adapter: ElaraAdapter,
      root: workspace_root,
      target_commit: config.targets[run["condition"]].commit,
      adapter_digest: adapter_digest
    )
  end

  defp run_one(:no_fault, manifest, run, _config, workspace_root, _adapter_digest) do
    Runner.run_no_fault(manifest, run, adapter: ElaraAdapter, root: workspace_root)
  end

  defp checkpoint(mode, source, execution_manifest) do
    %{
      "schema" => @checkpoint_schema,
      "protocol" => @protocol,
      "mode" => Atom.to_string(mode),
      "source_manifest_sha256" => source.sha256,
      "execution_manifest_sha256" => execution_manifest.sha256,
      "events" => []
    }
  end

  defp checkpoint_event(checkpoint, kind, status, run, record) do
    event = %{
      "sequence" => length(checkpoint["events"]) + 1,
      "kind" => Atom.to_string(kind),
      "status" => status,
      "run" => run
    }

    if record do
      Map.merge(event, %{
        "record" => record,
        "record_sha256" => sha256(canonical_json(record))
      })
    else
      event
    end
  end

  defp append_event(checkpoint, event) do
    Map.update!(checkpoint, "events", &(&1 ++ [event]))
  end

  defp report(
         mode,
         source,
         execution_manifest,
         identities,
         qualification_identity,
         fault_records,
         no_fault_records,
         score,
         checkpoint,
         checkpoint_digest
       ) do
    %{
      "schema" => @report_schema,
      "protocol" => @protocol,
      "mode" => Atom.to_string(mode),
      "source_manifest" => %{
        "path" => Path.relative_to_cwd(source.path),
        "schema" => source.data["schema"],
        "sha256" => source.sha256
      },
      "execution_manifest" => %{
        "schema" => execution_manifest.data["schema"],
        "sha256" => execution_manifest.sha256,
        "scope_id" => execution_manifest.data["scope_id"]
      },
      "qualification" => qualification_identity,
      "identities" => identities,
      "commands" => @commands,
      "configuration" => configuration(execution_manifest),
      "runtime" => %{
        "elixir" => System.version(),
        "otp_release" => List.to_string(:erlang.system_info(:otp_release)),
        "system_architecture" => List.to_string(:erlang.system_info(:system_architecture))
      },
      "execution" => %{
        "fault_run_count" => length(fault_records),
        "no_fault_run_count" => length(no_fault_records),
        "fault_records_sha256" => sha256(canonical_json(fault_records)),
        "no_fault_records_sha256" => sha256(canonical_json(no_fault_records)),
        "checkpoint_event_count" => length(checkpoint["events"]),
        "checkpoint_sha256" => checkpoint_digest
      },
      "exposure" => exposure(mode, fault_records, no_fault_records),
      "fault_records" => fault_records,
      "no_fault_records" => no_fault_records,
      "score" => score,
      "diagnostics" => diagnostics(fault_records, no_fault_records),
      "limitations" => [
        "Baseline barriers remain nearest-existing instrumented seams rather than receipt-native durable seams.",
        "Workspace postconditions do not prove causal job completion.",
        "The receipts target uses the research-only Elara.Effect.TestExecutor.",
        "Qualification scores development fixtures only and is not confirmatory B/T evidence."
      ]
    }
  end

  defp configuration(manifest) do
    fault_schedule = Runner.fault_schedule(manifest)
    no_fault_schedule = Runner.no_fault_schedule(manifest)

    %{
      "targets" => ElaraAdapter.target_commits(),
      "fault_condition_order" => ~w(baseline receipts receipts baseline baseline receipts),
      "fault_repetitions_per_condition" => 3,
      "no_fault_warmups_per_task_condition" => 2,
      "no_fault_measured_per_task_condition" => 10,
      "fault_schedule_sha256" => sha256(canonical_json(fault_schedule)),
      "no_fault_schedule_sha256" => sha256(canonical_json(no_fault_schedule)),
      "fault_schedule_count" => length(fault_schedule),
      "no_fault_schedule_count" => length(no_fault_schedule),
      "fixture_policy" => "exact reset before every run",
      "checkpoint_policy" =>
        "atomic started/completed events; unmatched started is invalid and never resumed",
      "failure_policy" => "stop on first failure; no retry, replacement, or synthesized record",
      "raw_evidence_policy" => "records precede aggregates in the canonical report"
    }
  end

  defp exposure(:qualify, fault_records, no_fault_records) do
    %{
      "development_fault_runs" => length(fault_records),
      "development_no_fault_runs" => length(no_fault_records),
      "v6_confirmatory_fault_runs" => 0,
      "v6_confirmatory_no_fault_timing_runs" => 0,
      "confirmatory_B_or_T_calculated" => false,
      "development_score_only" => true,
      "statement" =>
        "Every run used non-scored development_adapter_fixture tasks; no held-out v6 row or timing result was exposed."
    }
  end

  defp exposure(:execute, fault_records, no_fault_records) do
    %{
      "development_fault_runs" => 0,
      "development_no_fault_runs" => 0,
      "v6_confirmatory_fault_runs" => length(fault_records),
      "v6_confirmatory_no_fault_timing_runs" => length(no_fault_records),
      "confirmatory_B_or_T_calculated" => true,
      "development_score_only" => false,
      "statement" => "Complete immutable v6 internal execution; no row was retried or replaced."
    }
  end

  defp diagnostics(fault_records, no_fault_records) do
    matrix =
      fault_records
      |> Enum.group_by(&{&1["operation_class"], &1["fault_type"]})
      |> Map.new(fn {{class, fault}, records} ->
        {"#{class}:#{fault}",
         %{
           "run_count" => length(records),
           "conditions" => Enum.frequencies_by(records, & &1["condition"]),
           "recovery_classes" => Enum.frequencies_by(records, & &1["primary_recovery_class"])
         }}
      end)

    %{
      "fault_matrix" => matrix,
      "no_fault_phases" =>
        Enum.frequencies_by(no_fault_records, &"#{&1["phase"]}:#{&1["condition"]}"),
      "safety_disqualifier_count" =>
        fault_records |> Enum.flat_map(& &1["safety_disqualifiers"]) |> length(),
      "harness_error_count" => fault_records |> Enum.flat_map(& &1["harness_errors"]) |> length(),
      "all_no_fault_correct" =>
        Enum.all?(no_fault_records, &(&1["workspace_correct"] and &1["outcome_correct"]))
    }
  end

  defp execution_manifest(:qualify, source), do: Qualification.manifest(source)
  defp execution_manifest(:execute, source), do: {:ok, source}

  defp authorize(:qualify, config, _source), do: {:ok, config}

  defp authorize(:execute, config, source),
    do: ElaraAdapter.authorize_confirmatory(config, source)

  defp qualification_identity(:qualify, nil, _source, _identities),
    do: {:ok, %{"required" => false}}

  defp qualification_identity(:execute, qualification_path, source, identities)
       when is_binary(qualification_path) do
    with {:ok, report, bytes} <- read_canonical_json(qualification_path),
         {:ok, manifest} <- Qualification.manifest(source),
         :ok <- validate_report(report, source, manifest, identities),
         true <- report["mode"] == "qualify",
         true <- report["exposure"]["v6_confirmatory_fault_runs"] == 0,
         true <- report["exposure"]["v6_confirmatory_no_fault_timing_runs"] == 0,
         true <- report["exposure"]["confirmatory_B_or_T_calculated"] == false do
      {:ok,
       %{
         "required" => true,
         "path" => Path.relative_to_cwd(Path.expand(qualification_path)),
         "sha256" => sha256(bytes),
         "source_manifest_sha256" => source.sha256,
         "execution_manifest_sha256" => manifest.sha256
       }}
    else
      false -> {:error, :qualification_not_zero_exposure}
      {:error, _reason} = error -> error
    end
  end

  defp qualification_identity(:execute, _qualification_path, _source, _identities),
    do: {:error, :qualification_path_required}

  defp report_manifest(source, %{"mode" => "qualify"}), do: Qualification.manifest(source)
  defp report_manifest(source, %{"mode" => "execute"}), do: {:ok, source}
  defp report_manifest(_source, report), do: {:error, {:invalid_report_mode, report["mode"]}}

  defp validate_report(report, source, execution_manifest, identities) do
    expected_configuration = configuration(execution_manifest)

    cond do
      report["schema"] != @report_schema ->
        {:error, {:invalid_report_schema, report["schema"]}}

      report["protocol"] != @protocol ->
        {:error, {:invalid_report_protocol, report["protocol"]}}

      get_in(report, ["source_manifest", "sha256"]) != source.sha256 ->
        {:error, :report_source_manifest_mismatch}

      get_in(report, ["execution_manifest", "sha256"]) != execution_manifest.sha256 ->
        {:error, :report_execution_manifest_mismatch}

      report["identities"] != identities ->
        {:error, :report_source_identity_mismatch}

      report["commands"] != @commands ->
        {:error, :report_command_mismatch}

      report["configuration"] != expected_configuration ->
        {:error, :report_configuration_mismatch}

      not is_list(report["fault_records"]) or not is_list(report["no_fault_records"]) ->
        {:error, :report_records_missing}

      true ->
        replayed =
          Scorer.score(execution_manifest, report["fault_records"], report["no_fault_records"])

        with :ok <- validate_authorizing_score(replayed),
             :ok <- require_score_match(replayed, report["score"]) do
          :ok
        end
    end
  end

  defp load_source(path) do
    with {:ok, manifest} <- Manifest.load(Path.expand(path), sha256: @manifest_sha256),
         true <- manifest.data["schema"] == "elara.exp003.corpus.v6",
         true <- manifest.data["preregistration_version"] == @protocol do
      {:ok, manifest}
    else
      false -> {:error, :not_frozen_v6_manifest}
      {:error, _reason} = error -> error
    end
  end

  defp preflight_paths(repo_root, state_root, workspace_root, output_path, checkpoint_path) do
    cond do
      state_root == workspace_root ->
        {:error, :state_and_workspace_paths_overlap}

      inside?(state_root, repo_root) ->
        {:error, :state_root_inside_repository}

      inside?(workspace_root, repo_root) ->
        {:error, :workspace_root_inside_repository}

      File.exists?(state_root) ->
        interrupted_or_dirty(state_root, checkpoint_path)

      File.exists?(workspace_root) ->
        {:error, {:dirty_path, :workspace_root, workspace_root}}

      File.exists?(output_path) ->
        {:error, {:dirty_path, :output_path, output_path}}

      File.exists?(output_path <> ".tmp") ->
        {:error, {:dirty_path, :output_temporary_path, output_path <> ".tmp"}}

      true ->
        :ok
    end
  end

  defp interrupted_or_dirty(state_root, checkpoint_path) do
    with true <- File.regular?(checkpoint_path),
         {:ok, checkpoint, _bytes} <- read_canonical_json(checkpoint_path),
         %{"status" => "started"} = event <- List.last(checkpoint["events"] || []) do
      {:error, {:interrupted_checkpoint, event["kind"], event["run"]}}
    else
      _other -> {:error, {:dirty_path, :state_root, state_root}}
    end
  end

  defp read_canonical_json(path) do
    path = Path.expand(path)

    with {:ok, bytes} <- File.read(path),
         {:ok, value} <- JSON.decode(bytes),
         true <- is_map(value),
         true <- canonical_json(value) == bytes do
      {:ok, value, bytes}
    else
      false -> {:error, {:noncanonical_json, path}}
      {:error, reason} -> {:error, {:json_read_failed, path, reason}}
    end
  end

  defp require_score_match(left, right) do
    if canonical_json(left) == canonical_json(right),
      do: :ok,
      else: {:error, :score_replay_mismatch}
  end

  defp require_absent(path, label) do
    if File.exists?(path), do: {:error, {:dirty_path, label, path}}, else: :ok
  end

  defp write_atomic(path, contents, mode) do
    path = Path.expand(path)
    temporary = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- require_absent(temporary, :atomic_temporary_path),
         :ok <- require_new_target(mode, path),
         {:ok, io} <- File.open(temporary, [:write, :binary, :exclusive]),
         :ok <- IO.binwrite(io, contents),
         :ok <- :file.sync(io),
         :ok <- File.close(io),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} -> {:error, {:atomic_write_failed, path, reason}}
    end
  end

  defp require_new_target(:new, path), do: require_absent(path, :atomic_target_path)
  defp require_new_target(:replace, _path), do: :ok

  defp inside?(path, root) do
    relative = Path.relative_to(path, root)

    Path.type(relative) == :relative and relative != ".." and
      not String.starts_with?(relative, "../")
  end

  defp sha256(value) do
    value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end
end
