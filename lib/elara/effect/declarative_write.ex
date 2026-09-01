defmodule Elara.Effect.DeclarativeWrite do
  @moduledoc false

  alias Elara.Effect.ControllerJournal
  alias Elara.Effect.ExecutorLedger.Record
  alias Elara.Effect.Job
  alias Elara.Effect.Sidecar

  @schema "elara.declarative_write.v1"
  @tool_name "declarative_write"
  @tool_version "1"
  @required_capabilities ["filesystem:write"]
  @default_timeout 2_000

  defmodule Observation do
    @moduledoc false

    @enforce_keys [:state, :path]
    defstruct [:state, :path, :sha256, :reason]

    @type state ::
            :expected_preimage
            | :exact_postimage
            | :conflict
            | :absent
            | :non_file
            | :symlink_rejected
            | :unavailable

    @type t :: %__MODULE__{
            state: state(),
            path: String.t(),
            sha256: String.t() | nil,
            reason: term() | nil
          }
  end

  defmodule Result do
    @moduledoc false

    @enforce_keys [
      :job,
      :status,
      :outcome,
      :workspace,
      :causal,
      :historical,
      :safe_action
    ]
    defstruct [
      :job,
      :status,
      :outcome,
      :workspace,
      :causal,
      :historical,
      :safe_action,
      :executor_record,
      :controller_record
    ]

    @type t :: %__MODULE__{
            job: Job.t(),
            status: :terminal | :awaiting_executor,
            outcome: Elara.Tool.outcome() | nil,
            workspace: Observation.t(),
            causal: :not_started | :completed | :failed | :unproven,
            historical: :not_invoked | :invoked | :unknown,
            safe_action:
              :none
              | :new_job_id_allowed
              | :original_owner_continue_once
              | :postcondition_satisfied_no_retry
              | :cleanup_bound_temp_only_no_retry
              | :report_conflict
              | :report_rejection
              | :refresh_then_report_conflict
              | :manual_investigation,
            executor_record: Record.t() | nil,
            controller_record: Record.t() | nil
          }
  end

  @type expected :: :absent | {:regular, String.t()}
  @type hook :: (atom() -> :ok)

  @spec schema() :: String.t()
  def schema, do: @schema

  @spec arguments(String.t(), expected(), String.t()) :: map()
  def arguments(path, expected, content) when is_binary(path) and is_binary(content) do
    %{
      "schema" => @schema,
      "path" => path,
      "expected" => encode_expected(expected),
      "desired" => %{"content" => content, "sha256" => sha256(content)},
      "parent_policy" => "create",
      "replacement" => "same_directory_temp_rename"
    }
  end

  @spec sha256(binary()) :: String.t()
  def sha256(content) when is_binary(content) do
    content
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec validate(Job.t(), String.t()) :: :ok | {:error, term()}
  def validate(%Job{} = job, cwd) when is_binary(cwd) do
    case parse(job, cwd) do
      {:ok, _spec} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec observe(Job.t(), String.t()) :: {:ok, Observation.t()} | {:error, term()}
  def observe(%Job{} = job, cwd) when is_binary(cwd) do
    with {:ok, spec} <- parse(job, cwd) do
      {:ok, observe_spec(spec)}
    end
  end

  @spec operation(Job.t(), String.t(), keyword()) :: (-> Elara.Tool.outcome())
  def operation(%Job{} = job, cwd, opts \\ []) when is_binary(cwd) do
    fn -> run(job, cwd, opts) end
  end

  @spec run(Job.t(), String.t(), keyword()) :: Elara.Tool.outcome()
  def run(%Job{} = job, cwd, opts \\ []) when is_binary(cwd) do
    operation_hook = Keyword.get(opts, :operation_hook, &no_fault/1)
    effect_observer = Keyword.get(opts, :effect_observer, &no_fault/1)

    with {:ok, spec} <- parse(job, cwd) do
      case observe_spec(spec) do
        %Observation{state: :exact_postimage} ->
          {:ok,
           "declarative write postcondition_satisfied: path=#{spec.path} " <>
             "sha256=#{spec.desired_sha256} no_write=true"}

        %Observation{state: :expected_preimage} ->
          replace(spec, job, operation_hook, effect_observer)

        %Observation{} = observation ->
          observation_error(observation)
      end
    else
      {:error, reason} ->
        {:error, "declarative write rejected: #{inspect(reason)} action=report_rejection"}
    end
  end

  @spec execute(
          GenServer.server(),
          GenServer.server(),
          Job.t(),
          String.t(),
          keyword()
        ) :: Result.t()
  def execute(executor, journal, %Job{} = job, cwd, opts \\ []) when is_binary(cwd) do
    with {:ok, _spec} <- parse(job, cwd) do
      sidecar =
        Sidecar.execute(
          executor,
          journal,
          job,
          operation(job, cwd, opts),
          Keyword.get(opts, :timeout, @default_timeout),
          Keyword.get(opts, :sidecar_hook, &no_fault/1)
        )

      classify_sidecar(sidecar, job, cwd)
    else
      {:error, reason} -> rejected_result(job, cwd, reason)
    end
  end

  @spec reconcile(
          GenServer.server(),
          GenServer.server(),
          Job.t(),
          String.t(),
          keyword()
        ) :: Result.t()
  def reconcile(executor, journal, %Job{} = job, cwd, opts \\ []) when is_binary(cwd) do
    with {:ok, _spec} <- parse(job, cwd) do
      sidecar =
        Sidecar.reconcile(
          executor,
          journal,
          job,
          operation(job, cwd, opts),
          Keyword.get(opts, :timeout, @default_timeout),
          Keyword.get(opts, :sidecar_hook, &no_fault/1)
        )

      classify_sidecar(sidecar, job, cwd)
    else
      {:error, reason} -> rejected_result(job, cwd, reason)
    end
  end

  @doc "Reconciles when the executor ledger is known to be unavailable, never merely empty."
  @spec reconcile_unavailable(GenServer.server(), Job.t(), String.t(), keyword()) :: Result.t()
  def reconcile_unavailable(journal, %Job{} = job, cwd, opts \\ []) when is_binary(cwd) do
    with {:ok, _spec} <- parse(job, cwd),
         {:ok, ^job} <- ControllerJournal.get(journal, job.job_id),
         {:ok, controller_observation} <- ControllerJournal.observation(journal, job.job_id) do
      controller_record =
        case controller_observation do
          %ControllerJournal.Observation{executor_record: record} -> record
          nil -> nil
        end

      case controller_record do
        %Record{state: state} = record when state in [:completed, :failed] ->
          terminal_from_controller(job, cwd, record)

        _record ->
          unavailable_result(job, cwd, controller_record, opts)
      end
    else
      {:ok, nil} -> not_started_result(job, cwd)
      {:error, reason} -> rejected_result(job, cwd, {:controller_evidence_failed, reason})
      _conflict -> rejected_result(job, cwd, :controller_job_conflict)
    end
  end

  defp replace(spec, job, operation_hook, effect_observer) do
    with :ok <- ensure_parents(spec),
         %Observation{state: :expected_preimage} <- observe_spec(spec),
         :ok <- invoke_hook(operation_hook, :after_typed_precondition_before_temp_create),
         :ok <- write_temp(spec, job) do
      case invoke_hook(operation_hook, :after_temp_complete_before_rename) do
        :ok ->
          finish_replace(spec, job, effect_observer)

        {:error, reason} ->
          cleanup_temp(spec, job)
          {:error, write_error(spec.path, reason)}
      end
    else
      %Observation{} = observation ->
        observation_error(observation)

      {:error, reason} ->
        cleanup_temp(spec, job)
        {:error, write_error(spec.path, reason)}
    end
  end

  defp finish_replace(spec, job, effect_observer) do
    temp_path = temp_path(spec, job)

    result =
      case observe_spec(spec) do
        %Observation{state: :expected_preimage} ->
          with :ok <- File.rename(temp_path, spec.full_path),
               :ok <- invoke_hook(effect_observer, :primary_target_committed),
               %Observation{state: :exact_postimage} <- observe_spec(spec) do
            {:ok,
             "declarative write committed: path=#{spec.path} " <>
               "sha256=#{spec.desired_sha256}"}
          else
            %Observation{} = observation -> observation_error(observation)
            {:error, reason} -> {:error, write_error(spec.path, reason)}
          end

        %Observation{state: :exact_postimage} ->
          {:ok,
           "declarative write postcondition_satisfied: path=#{spec.path} " <>
             "sha256=#{spec.desired_sha256} no_write=true"}

        %Observation{} = observation ->
          observation_error(observation)
      end

    cleanup_temp(spec, job)
    result
  end

  defp write_temp(spec, job) do
    temp_path = temp_path(spec, job)

    case File.write(temp_path, spec.content, [:binary, :exclusive]) do
      :ok ->
        case File.read(temp_path) do
          {:ok, content} ->
            if sha256(content) == spec.desired_sha256,
              do: :ok,
              else: {:error, :temp_digest_mismatch}

          {:error, reason} ->
            {:error, {:temp_read_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:temp_write_failed, reason}}
    end
  end

  defp ensure_parents(spec) do
    spec.path
    |> Path.split()
    |> Enum.drop(-1)
    |> Enum.reduce_while(spec.cwd, fn component, parent ->
      current = Path.join(parent, component)

      case File.lstat(current) do
        {:ok, %File.Stat{type: :directory}} ->
          {:cont, current}

        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, {:symlink_component, Path.relative_to(current, spec.cwd)}}}

        {:ok, %File.Stat{type: type}} ->
          {:halt, {:error, {:non_directory_component, type}}}

        {:error, :enoent} ->
          case File.mkdir(current) do
            :ok -> {:cont, current}
            {:error, reason} -> {:halt, {:error, {:parent_create_failed, reason}}}
          end

        {:error, reason} ->
          {:halt, {:error, {:parent_observation_failed, reason}}}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      _parent -> :ok
    end
  end

  defp observe_spec(spec) do
    case inspect_target(spec) do
      :absent ->
        if spec.expected == :absent do
          %Observation{state: :expected_preimage, path: spec.path}
        else
          %Observation{state: :absent, path: spec.path}
        end

      {:regular, content} ->
        digest = sha256(content)

        cond do
          digest == spec.desired_sha256 ->
            %Observation{state: :exact_postimage, path: spec.path, sha256: digest}

          expected_digest(spec.expected) == digest ->
            %Observation{state: :expected_preimage, path: spec.path, sha256: digest}

          true ->
            %Observation{state: :conflict, path: spec.path, sha256: digest}
        end

      {:symlink, target} ->
        %Observation{state: :symlink_rejected, path: spec.path, reason: target}

      {:non_file, type} ->
        %Observation{state: :non_file, path: spec.path, reason: type}

      {:unavailable, reason} ->
        %Observation{state: :unavailable, path: spec.path, reason: reason}
    end
  end

  defp inspect_target(spec) do
    components = Path.split(spec.path)

    components
    |> Enum.with_index()
    |> Enum.reduce_while(spec.cwd, fn {component, index}, parent ->
      current = Path.join(parent, component)
      final? = index == length(components) - 1

      case File.lstat(current) do
        {:ok, %File.Stat{type: :symlink}} ->
          target =
            case File.read_link(current) do
              {:ok, value} -> value
              _ -> :unknown
            end

          {:halt, {:result, {:symlink, target}}}

        {:ok, %File.Stat{type: :directory}} when not final? ->
          {:cont, current}

        {:ok, %File.Stat{type: :regular}} when final? ->
          case File.read(current) do
            {:ok, content} -> {:halt, {:result, {:regular, content}}}
            {:error, reason} -> {:halt, {:result, {:unavailable, {:read_failed, reason}}}}
          end

        {:ok, %File.Stat{type: type}} ->
          {:halt, {:result, {:non_file, type}}}

        {:error, :enoent} ->
          {:halt, {:result, :absent}}

        {:error, reason} ->
          {:halt, {:result, {:unavailable, {:lstat_failed, reason}}}}
      end
    end)
    |> case do
      {:result, result} -> result
      _path -> :absent
    end
  end

  defp parse(%Job{} = job, cwd) do
    with :ok <- validate_job_identity(job),
         {:ok, args} <- validate_arguments(job.arguments),
         {:ok, full_path} <- validate_path(args["path"], cwd) do
      {:ok,
       %{
         cwd: Path.expand(cwd),
         path: args["path"],
         full_path: full_path,
         expected: decode_expected(args["expected"]),
         content: args["desired"]["content"],
         desired_sha256: args["desired"]["sha256"]
       }}
    end
  end

  defp validate_job_identity(%Job{} = job) do
    cond do
      job.operation_kind != :declarative_write -> {:error, :invalid_operation_kind}
      job.tool_name != @tool_name -> {:error, :invalid_tool_name}
      job.tool_version != @tool_version -> {:error, :invalid_tool_version}
      job.required_capabilities != @required_capabilities -> {:error, :invalid_capabilities}
      not authority_allows_write?(job.authority_scope) -> {:error, :invalid_authority}
      not (is_binary(job.workspace_id) and job.workspace_id != "") -> {:error, :invalid_workspace}
      true -> :ok
    end
  end

  defp validate_arguments(args) when is_map(args) do
    keys = ["desired", "expected", "parent_policy", "path", "replacement", "schema"]

    with true <- Enum.sort(Map.keys(args)) == keys,
         true <- args["schema"] == @schema,
         true <- is_binary(args["path"]) and args["path"] != "",
         :ok <- validate_expected(args["expected"]),
         :ok <- validate_desired(args["desired"]),
         true <- args["parent_policy"] == "create",
         true <- args["replacement"] == "same_directory_temp_rename" do
      {:ok, args}
    else
      false -> {:error, :invalid_arguments}
      {:error, _reason} = error -> error
    end
  end

  defp validate_arguments(_args), do: {:error, :invalid_arguments}

  defp validate_expected(%{"state" => "absent"} = expected)
       when map_size(expected) == 1,
       do: :ok

  defp validate_expected(%{"state" => "regular", "sha256" => digest} = expected)
       when map_size(expected) == 2,
       do: validate_digest(digest)

  defp validate_expected(_expected), do: {:error, :invalid_expected_state}

  defp validate_desired(%{"content" => content, "sha256" => digest} = desired)
       when map_size(desired) == 2 and is_binary(content) and is_binary(digest) do
    with true <- String.valid?(content),
         :ok <- validate_digest(digest),
         true <- sha256(content) == digest do
      :ok
    else
      false -> {:error, :desired_digest_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp validate_desired(_desired), do: {:error, :invalid_desired_state}

  defp validate_digest(digest) when is_binary(digest) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, digest), do: :ok, else: {:error, :invalid_digest}
  end

  defp validate_digest(_digest), do: {:error, :invalid_digest}

  defp validate_path(path, cwd) do
    if Path.type(path) != :relative or path == "." or String.contains?(path, <<0>>) do
      {:error, :path_outside_workspace}
    else
      root = Path.expand(cwd)
      full_path = Path.expand(path, root)
      relative = Path.relative_to(full_path, root)
      canonical = path |> Path.split() |> Path.join()

      if path == canonical and Path.type(relative) == :relative and relative != ".." and
           not String.starts_with?(relative, "../") do
        {:ok, full_path}
      else
        {:error, :path_outside_workspace}
      end
    end
  end

  defp classify_sidecar(%Sidecar.Result{} = sidecar, job, cwd) do
    {:ok, workspace} = observe(job, cwd)
    record = sidecar.executor_record

    {causal, historical, safe_action} =
      case record do
        %Record{state: :completed} ->
          {:completed, :invoked, :none}

        %Record{state: :failed} ->
          {:failed, :invoked, terminal_safe_action(workspace)}

        %Record{state: :accepted, callback_attempt_count: 1} ->
          {:unproven, :invoked, indeterminate_safe_action(workspace, job, cwd)}

        %Record{state: :accepted, callback_attempt_count: 0} ->
          {:unproven, :not_invoked, :original_owner_continue_once}

        nil ->
          {:unproven, :unknown, indeterminate_safe_action(workspace, job, cwd)}
      end

    %Result{
      job: job,
      status: sidecar.status,
      outcome: sidecar.outcome,
      workspace: workspace,
      causal: causal,
      historical: historical,
      safe_action: safe_action,
      executor_record: record,
      controller_record: record
    }
  end

  defp unavailable_result(job, cwd, controller_record, opts) do
    {:ok, initial} = observe(job, cwd)
    hook = Keyword.get(opts, :reconcile_hook, &no_fault/1)

    with :ok <- invoke_hook(hook, :after_postcondition_observation_before_action),
         {:ok, refreshed} <- observe(job, cwd) do
      safe_action =
        cond do
          initial.state == :exact_postimage and refreshed.state == :conflict ->
            :refresh_then_report_conflict

          refreshed.state == :exact_postimage ->
            :postcondition_satisfied_no_retry

          true ->
            :manual_investigation
        end

      %Result{
        job: job,
        status: :terminal,
        outcome: {:indeterminate, unavailable_message(job, refreshed, safe_action)},
        workspace: refreshed,
        causal: :unproven,
        historical: unavailable_historical(controller_record),
        safe_action: safe_action,
        executor_record: nil,
        controller_record: controller_record
      }
    else
      {:error, reason} -> rejected_result(job, cwd, {:reconciliation_observation_failed, reason})
    end
  end

  defp terminal_from_controller(job, cwd, %Record{} = record) do
    {:ok, workspace} = observe(job, cwd)
    causal = if record.state == :completed, do: :completed, else: :failed

    %Result{
      job: job,
      status: :terminal,
      outcome: record.result,
      workspace: workspace,
      causal: causal,
      historical: :invoked,
      safe_action: if(causal == :completed, do: :none, else: terminal_safe_action(workspace)),
      executor_record: nil,
      controller_record: record
    }
  end

  defp not_started_result(job, cwd) do
    {:ok, workspace} = observe(job, cwd)

    %Result{
      job: job,
      status: :terminal,
      outcome: {:error, "effect not_started: job_id=#{job.job_id} action=new_job_id_allowed"},
      workspace: workspace,
      causal: :not_started,
      historical: :not_invoked,
      safe_action: :new_job_id_allowed
    }
  end

  defp rejected_result(job, cwd, reason) do
    workspace =
      case observe(job, cwd) do
        {:ok, observation} ->
          observation

        {:error, observation_reason} ->
          %Observation{
            state: :unavailable,
            path: Map.get(job.arguments, "path", "unknown"),
            reason: observation_reason
          }
      end

    %Result{
      job: job,
      status: :terminal,
      outcome: {:error, "declarative write protocol failed: #{inspect(reason)}"},
      workspace: workspace,
      causal: :not_started,
      historical: :not_invoked,
      safe_action: :report_rejection
    }
  end

  defp terminal_safe_action(%Observation{state: :conflict}), do: :report_conflict

  defp terminal_safe_action(%Observation{state: state})
       when state in [:non_file, :symlink_rejected, :unavailable, :absent],
       do: :report_rejection

  defp terminal_safe_action(_workspace), do: :none

  defp indeterminate_safe_action(%Observation{state: :exact_postimage}, _job, _cwd),
    do: :postcondition_satisfied_no_retry

  defp indeterminate_safe_action(%Observation{state: :expected_preimage}, job, cwd) do
    if File.exists?(temp_path_for(job, cwd)),
      do: :cleanup_bound_temp_only_no_retry,
      else: :manual_investigation
  end

  defp indeterminate_safe_action(_workspace, _job, _cwd), do: :manual_investigation

  defp unavailable_historical(%Record{callback_attempt_count: 1}), do: :invoked

  defp unavailable_historical(%Record{state: state}) when state in [:completed, :failed],
    do: :invoked

  defp unavailable_historical(_record), do: :unknown

  defp unavailable_message(job, observation, safe_action) do
    "effect outcome indeterminate: job_id=#{job.job_id} " <>
      "operation_digest=#{job.operation_digest} workspace_id=#{job.workspace_id} " <>
      "executor_evidence=unavailable workspace=#{observation.state} " <>
      "causal=unproven action=#{safe_action}"
  end

  defp observation_error(%Observation{state: :conflict, path: path, sha256: digest}) do
    {:error,
     "declarative write conflict: path=#{path} observed_sha256=#{digest} " <>
       "action=report_conflict"}
  end

  defp observation_error(%Observation{state: state, path: path, reason: reason}) do
    {:error,
     "declarative write rejected: path=#{path} state=#{state} reason=#{inspect(reason)} " <>
       "action=report_rejection"}
  end

  defp write_error(path, reason) do
    "declarative write failed: path=#{path} reason=#{inspect(reason)} action=report_rejection"
  end

  defp temp_path(spec, job), do: Path.join(Path.dirname(spec.full_path), temp_name(job))

  defp cleanup_temp(spec, job) do
    temp_path = temp_path(spec, job)
    if File.exists?(temp_path), do: File.rm(temp_path)
    :ok
  end

  defp temp_path_for(job, cwd) do
    case parse(job, cwd) do
      {:ok, spec} -> temp_path(spec, job)
      {:error, _reason} -> Path.join(Path.expand(cwd), ".invalid-elara-temp")
    end
  end

  defp temp_name(job) do
    ".elara-#{job.job_id}-#{String.slice(job.operation_digest, 0, 16)}.tmp"
  end

  defp encode_expected(:absent), do: %{"state" => "absent"}
  defp encode_expected({:regular, digest}), do: %{"state" => "regular", "sha256" => digest}

  defp decode_expected(%{"state" => "absent"}), do: :absent
  defp decode_expected(%{"state" => "regular", "sha256" => digest}), do: {:regular, digest}

  defp expected_digest(:absent), do: nil
  defp expected_digest({:regular, digest}), do: digest

  defp authority_allows_write?(%{allowed_capabilities: :all, placement: :local}), do: true

  defp authority_allows_write?(%{allowed_capabilities: capabilities, placement: :local})
       when is_list(capabilities),
       do: "filesystem:write" in capabilities

  defp authority_allows_write?(_authority), do: false

  defp invoke_hook(hook, point) do
    case hook.(point) do
      :ok -> :ok
      other -> {:error, {:invalid_hook_return, other}}
    end
  end

  defp no_fault(_point), do: :ok
end
