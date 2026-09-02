defmodule Elara.Effect.OpaqueShell do
  @moduledoc false

  alias Elara.Effect.AtomicFile
  alias Elara.Effect.ControllerJournal
  alias Elara.Effect.ExecutorLedger.Record
  alias Elara.Effect.Job
  alias Elara.Effect.Sidecar
  alias Elara.Exec

  @schema "elara.opaque_shell.v1"
  @tool_name "opaque_shell"
  @tool_version "1"
  @required_capabilities ["shell"]
  @default_timeout 5_000

  defmodule Workspace do
    @moduledoc false

    @enforce_keys [:state]
    defstruct [:state, files: [], reason: nil]

    @type state ::
            :exact_postimage
            | :conflict
            | :absent
            | :non_file
            | :symlink_rejected
            | :unavailable
            | :not_applicable

    @type t :: %__MODULE__{state: state(), files: [map()], reason: term() | nil}
  end

  defmodule Result do
    @moduledoc false

    @enforce_keys [
      :job,
      :status,
      :outcome,
      :workspace,
      :process_lifetime,
      :causal,
      :historical,
      :safe_action
    ]
    defstruct [
      :job,
      :status,
      :outcome,
      :workspace,
      :process_lifetime,
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
            workspace: Workspace.t(),
            process_lifetime: :not_spawned | :alive | :terminated | :unknown,
            causal: :not_started | :completed | :failed | :unproven,
            historical: :not_invoked | :invoked | :unknown,
            safe_action:
              :none
              | :new_job_id_allowed
              | :original_owner_continue_once
              | :postcondition_satisfied_no_retry
              | :do_not_retry
              | :manual_investigation
              | :refresh_then_report_conflict
              | :report_rejection,
            executor_record: Record.t() | nil,
            controller_record: Record.t() | nil
          }
  end

  @spec schema() :: String.t()
  def schema, do: @schema

  @spec arguments(String.t(), keyword()) :: map()
  def arguments(command, opts \\ []) when is_binary(command) do
    %{
      "schema" => @schema,
      "command" => command,
      "relative_cwd" => Keyword.get(opts, :relative_cwd, "."),
      "environment" => Keyword.get(opts, :environment, %{}),
      "timeout_ms" => Keyword.get(opts, :timeout_ms, @default_timeout),
      "postcondition" => Keyword.get(opts, :postcondition)
    }
  end

  @spec validate(Job.t(), String.t()) :: :ok | {:error, term()}
  def validate(%Job{} = job, cwd) when is_binary(cwd) do
    case parse(job, cwd) do
      {:ok, _spec} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec observe(Job.t(), String.t()) :: {:ok, Workspace.t()} | {:error, term()}
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
      case Exec.run(["/bin/sh", "-c", spec.command],
             cwd: spec.shell_cwd,
             env: spec.environment,
             max_bytes: Keyword.get(opts, :max_bytes, 16_384),
             timeout_ms: spec.timeout_ms
           ) do
        {:ok, execution} ->
          workspace = observe_spec(spec)
          :ok = maybe_observe_effect(effect_observer, workspace)
          :ok = invoke_hook(operation_hook, :after_shell_exit_before_callback_return)
          opaque_shell_result(execution, workspace)

        {:error, {:not_started, message}} ->
          {:error, "opaque shell failed to start: #{message}"}

        {:indeterminate, message} ->
          {:indeterminate, "opaque shell #{message}"}
      end
    else
      {:error, reason} ->
        {:error, "opaque shell rejected: #{inspect(reason)} action=report_rejection"}
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
    with {:ok, spec} <- parse(job, cwd) do
      sidecar =
        Sidecar.execute(
          executor,
          journal,
          job,
          operation(job, cwd, opts),
          Keyword.get(opts, :timeout, spec.timeout_ms),
          Keyword.get(opts, :sidecar_hook, &no_fault/1)
        )

      classify_sidecar(sidecar, job, cwd, opts)
    else
      {:error, reason} -> rejected_result(job, cwd, reason, opts)
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
    with {:ok, spec} <- parse(job, cwd) do
      sidecar =
        Sidecar.reconcile(
          executor,
          journal,
          job,
          operation(job, cwd, opts),
          Keyword.get(opts, :timeout, spec.timeout_ms),
          Keyword.get(opts, :sidecar_hook, &no_fault/1)
        )

      classify_sidecar(sidecar, job, cwd, opts)
    else
      {:error, reason} -> rejected_result(job, cwd, reason, opts)
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
          terminal_from_controller(job, cwd, record, opts)

        _record ->
          unavailable_result(job, cwd, controller_record, opts)
      end
    else
      {:ok, nil} -> not_started_result(job, cwd, opts)
      {:error, reason} -> rejected_result(job, cwd, {:controller_evidence_failed, reason}, opts)
      _conflict -> rejected_result(job, cwd, :controller_job_conflict, opts)
    end
  end

  defp parse(%Job{} = job, cwd) do
    with :ok <- validate_job_identity(job),
         {:ok, args} <- validate_arguments(job.arguments),
         {:ok, shell_cwd} <- validate_shell_cwd(args["relative_cwd"], cwd),
         {:ok, postcondition} <- validate_postcondition(args["postcondition"], cwd) do
      {:ok,
       %{
         command: args["command"],
         shell_cwd: shell_cwd,
         relative_cwd: args["relative_cwd"],
         environment: args["environment"] |> Enum.sort() |> Enum.map(fn {k, v} -> {k, v} end),
         timeout_ms: args["timeout_ms"],
         postcondition: postcondition
       }}
    end
  end

  defp validate_job_identity(%Job{} = job) do
    cond do
      job.operation_kind != :opaque_shell -> {:error, :invalid_operation_kind}
      job.tool_name != @tool_name -> {:error, :invalid_tool_name}
      job.tool_version != @tool_version -> {:error, :invalid_tool_version}
      job.required_capabilities != @required_capabilities -> {:error, :invalid_capabilities}
      not authority_allows_shell?(job.authority_scope) -> {:error, :invalid_authority}
      not (is_binary(job.workspace_id) and job.workspace_id != "") -> {:error, :invalid_workspace}
      true -> :ok
    end
  end

  defp validate_arguments(args) when is_map(args) do
    keys = ["command", "environment", "postcondition", "relative_cwd", "schema", "timeout_ms"]

    with true <- Enum.sort(Map.keys(args)) == keys,
         true <- args["schema"] == @schema,
         true <-
           is_binary(args["command"]) and args["command"] != "" and
             not String.contains?(args["command"], <<0>>),
         true <- valid_relative_cwd?(args["relative_cwd"]),
         true <- valid_environment?(args["environment"]),
         true <- is_integer(args["timeout_ms"]) and args["timeout_ms"] > 0 do
      {:ok, args}
    else
      false -> {:error, :invalid_arguments}
    end
  end

  defp validate_arguments(_args), do: {:error, :invalid_arguments}

  defp valid_relative_cwd?(path) when is_binary(path) do
    path != "" and not String.contains?(path, <<0>>) and Path.type(path) == :relative and
      (path == "." or
         (path == Path.join(Path.split(path)) and path != ".." and
            not String.starts_with?(path, "../")))
  end

  defp valid_relative_cwd?(_path), do: false

  defp valid_environment?(environment) when is_map(environment) do
    Enum.all?(environment, fn {key, value} ->
      is_binary(key) and key != "" and not String.contains?(key, ["=", <<0>>]) and
        is_binary(value) and not String.contains?(value, <<0>>)
    end)
  end

  defp valid_environment?(_environment), do: false

  defp validate_shell_cwd(relative, cwd) do
    root = Path.expand(cwd)
    full_path = Path.expand(relative, root)
    relative_to_root = Path.relative_to(full_path, root)

    if Path.type(relative_to_root) == :relative and relative_to_root != ".." and
         not String.starts_with?(relative_to_root, "../") do
      validate_directory_components(root, relative)
    else
      {:error, :cwd_outside_workspace}
    end
  end

  defp validate_directory_components(root, "."), do: validate_directory(root, root)

  defp validate_directory_components(root, relative) do
    relative
    |> Path.split()
    |> Enum.reduce_while(root, fn component, parent ->
      current = Path.join(parent, component)

      case File.lstat(current) do
        {:ok, %File.Stat{type: :directory}} -> {:cont, current}
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, :symlink_cwd_rejected}}
        {:ok, %File.Stat{type: type}} -> {:halt, {:error, {:invalid_cwd_type, type}}}
        {:error, reason} -> {:halt, {:error, {:cwd_unavailable, reason}}}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      path -> {:ok, path}
    end
  end

  defp validate_directory(path, root) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, root}
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_cwd_rejected}
      {:ok, %File.Stat{type: type}} -> {:error, {:invalid_cwd_type, type}}
      {:error, reason} -> {:error, {:cwd_unavailable, reason}}
    end
  end

  defp validate_postcondition(nil, _cwd), do: {:ok, nil}

  defp validate_postcondition(%{"kind" => "files_sha256", "files" => files} = adapter, cwd)
       when map_size(adapter) == 2 and is_list(files) and files != [] do
    files
    |> Enum.reduce_while([], fn file, acc ->
      case validate_postcondition_file(file, cwd) do
        {:ok, value} -> {:cont, [value | acc]}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      values -> {:ok, %{kind: :files_sha256, files: Enum.reverse(values)}}
    end
  end

  defp validate_postcondition(_postcondition, _cwd), do: {:error, :invalid_postcondition}

  defp validate_postcondition_file(%{"path" => path, "sha256" => digest} = file, cwd)
       when map_size(file) == 2 and is_binary(path) and is_binary(digest) do
    with true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
         {:ok, target} <- AtomicFile.target(path, cwd) do
      {:ok, %{path: path, sha256: digest, target: target}}
    else
      false -> {:error, :invalid_postcondition_digest}
      {:error, _reason} = error -> error
    end
  end

  defp validate_postcondition_file(_file, _cwd), do: {:error, :invalid_postcondition_file}

  defp observe_spec(%{postcondition: nil}), do: %Workspace{state: :not_applicable}

  defp observe_spec(%{postcondition: %{kind: :files_sha256, files: files}}) do
    observations = Enum.map(files, &observe_file/1)

    state =
      cond do
        Enum.all?(observations, &(&1.state == :exact_postimage)) -> :exact_postimage
        Enum.any?(observations, &(&1.state == :unavailable)) -> :unavailable
        Enum.any?(observations, &(&1.state == :symlink_rejected)) -> :symlink_rejected
        Enum.any?(observations, &(&1.state == :non_file)) -> :non_file
        Enum.any?(observations, &(&1.state == :conflict)) -> :conflict
        true -> :absent
      end

    %Workspace{state: state, files: observations}
  end

  defp observe_file(file) do
    case AtomicFile.snapshot(file.target) do
      {:regular, _content, digest} when digest == file.sha256 ->
        %{path: file.path, state: :exact_postimage, sha256: digest}

      {:regular, _content, digest} ->
        %{path: file.path, state: :conflict, sha256: digest}

      :absent ->
        %{path: file.path, state: :absent}

      {:symlink, target} ->
        %{path: file.path, state: :symlink_rejected, reason: target}

      {:non_file, type} ->
        %{path: file.path, state: :non_file, reason: type}

      {:unavailable, reason} ->
        %{path: file.path, state: :unavailable, reason: reason}
    end
  end

  defp classify_sidecar(%Sidecar.Result{} = sidecar, job, cwd, opts) do
    {:ok, workspace} = observe(job, cwd)
    record = sidecar.executor_record

    {causal, historical, safe_action} =
      case {sidecar.outcome, record} do
        {{:indeterminate, _message}, %Record{callback_attempt_count: 1}} ->
          {:unproven, :invoked, indeterminate_safe_action(workspace)}

        {{:indeterminate, _message}, _record} ->
          {:unproven, :unknown, indeterminate_safe_action(workspace)}

        {_outcome, %Record{state: :completed}} ->
          {:completed, :invoked, :none}

        {_outcome, %Record{state: :failed}} ->
          {:failed, :invoked, :do_not_retry}

        {_outcome, %Record{state: :accepted, callback_attempt_count: 1}} ->
          {:unproven, :invoked, indeterminate_safe_action(workspace)}

        {_outcome, %Record{state: :accepted, callback_attempt_count: 0}} ->
          {:unproven, :not_invoked, :original_owner_continue_once}

        {_outcome, nil} ->
          {:unproven, :unknown, indeterminate_safe_action(workspace)}
      end

    %Result{
      job: job,
      status: sidecar.status,
      outcome: sidecar.outcome,
      workspace: workspace,
      process_lifetime: process_lifetime(opts),
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
        process_lifetime: process_lifetime(opts),
        causal: :unproven,
        historical: :unknown,
        safe_action: safe_action,
        executor_record: nil,
        controller_record: controller_record
      }
    else
      {:error, reason} ->
        rejected_result(job, cwd, {:reconciliation_observation_failed, reason}, opts)
    end
  end

  defp terminal_from_controller(job, cwd, %Record{} = record, opts) do
    {:ok, workspace} = observe(job, cwd)
    causal = if record.state == :completed, do: :completed, else: :failed

    %Result{
      job: job,
      status: :terminal,
      outcome: record.result,
      workspace: workspace,
      process_lifetime: process_lifetime(opts),
      causal: causal,
      historical: :invoked,
      safe_action: if(causal == :completed, do: :none, else: :do_not_retry),
      executor_record: nil,
      controller_record: record
    }
  end

  defp not_started_result(job, _cwd, opts) do
    %Result{
      job: job,
      status: :terminal,
      outcome: {:error, "effect not_started: job_id=#{job.job_id} action=new_job_id_allowed"},
      workspace: %Workspace{state: :not_applicable},
      process_lifetime: process_lifetime(opts),
      causal: :not_started,
      historical: :not_invoked,
      safe_action: :new_job_id_allowed
    }
  end

  defp rejected_result(job, cwd, reason, opts) do
    %Result{
      job: job,
      status: :terminal,
      outcome: {:error, "opaque shell protocol failed: #{inspect(reason)}"},
      workspace: safe_workspace(job, cwd),
      process_lifetime: process_lifetime(opts),
      causal: :not_started,
      historical: :not_invoked,
      safe_action: :report_rejection
    }
  end

  defp safe_workspace(job, cwd) do
    case observe(job, cwd) do
      {:ok, workspace} -> workspace
      {:error, reason} -> %Workspace{state: :unavailable, reason: reason}
    end
  end

  defp indeterminate_safe_action(%Workspace{state: :exact_postimage}),
    do: :postcondition_satisfied_no_retry

  defp indeterminate_safe_action(_workspace), do: :manual_investigation

  defp process_lifetime(opts) do
    observer = Keyword.get(opts, :process_observer, fn -> :unknown end)

    case observer.() do
      state when state in [:not_spawned, :alive, :terminated, :unknown] -> state
      _invalid -> :unknown
    end
  rescue
    _error -> :unknown
  catch
    _kind, _reason -> :unknown
  end

  defp maybe_observe_effect(observer, %Workspace{state: :exact_postimage}) do
    invoke_hook(observer, :declared_postcondition_satisfied)
  end

  defp maybe_observe_effect(_observer, _workspace), do: :ok

  defp shell_message(label, status, output, workspace) do
    "opaque shell #{label}: exit_status=#{status} workspace=#{workspace.state}\n#{output}"
  end

  defp opaque_shell_result(%Exec.Result{termination: :exited, code: 0} = result, workspace),
    do: {:ok, shell_message("completed", 0, result.output, workspace)}

  defp opaque_shell_result(
         %Exec.Result{termination: :exited, code: status} = result,
         workspace
       )
       when is_integer(status),
       do: {:error, shell_message("failed", status, result.output, workspace)}

  defp opaque_shell_result(
         %Exec.Result{termination: :exited, signal: signal} = result,
         workspace
       ),
       do: {:error, shell_message("failed", "signal_#{signal}", result.output, workspace)}

  defp opaque_shell_result(%Exec.Result{termination: :cancelled}, _workspace),
    do: {:error, "opaque shell cancelled"}

  defp opaque_shell_result(%Exec.Result{termination: :timed_out}, _workspace),
    do: {:error, "opaque shell timed out"}

  defp opaque_shell_result(%Exec.Result{termination: :truncated} = result, _workspace) do
    {:error,
     "opaque shell output truncated: bytes_total=#{result.bytes_total} " <>
       "bytes_sent=#{result.bytes_sent}\n#{result.output}"}
  end

  defp unavailable_message(job, workspace, safe_action) do
    "effect outcome indeterminate: job_id=#{job.job_id} " <>
      "operation_digest=#{job.operation_digest} workspace_id=#{job.workspace_id} " <>
      "executor_evidence=unavailable workspace=#{workspace.state} " <>
      "causal=unproven action=#{safe_action}"
  end

  defp authority_allows_shell?(%{allowed_capabilities: :all, placement: :local}), do: true

  defp authority_allows_shell?(%{allowed_capabilities: capabilities, placement: :local})
       when is_list(capabilities),
       do: "shell" in capabilities

  defp authority_allows_shell?(_authority), do: false

  defp invoke_hook(hook, point) do
    case hook.(point) do
      :ok -> :ok
      other -> {:error, {:invalid_hook_return, other}}
    end
  end

  defp no_fault(_point), do: :ok
end
