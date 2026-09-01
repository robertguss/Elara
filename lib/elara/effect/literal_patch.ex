defmodule Elara.Effect.LiteralPatch do
  @moduledoc false

  alias Elara.Effect.AtomicFile
  alias Elara.Effect.ControllerJournal
  alias Elara.Effect.ExecutorLedger.Record
  alias Elara.Effect.Job
  alias Elara.Effect.Sidecar

  @schema "elara.literal_patch.v1"
  @tool_name "literal_patch"
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

  @spec schema() :: String.t()
  def schema, do: @schema

  @spec arguments(String.t(), binary(), String.t(), String.t()) :: map()
  def arguments(path, preimage, old_text, new_text)
      when is_binary(path) and is_binary(preimage) and is_binary(old_text) and is_binary(new_text) do
    postimage = String.replace(preimage, old_text, new_text, global: false)

    %{
      "schema" => @schema,
      "path" => path,
      "preimage_sha256" => sha256(preimage),
      "old_text" => old_text,
      "new_text" => new_text,
      "postimage_sha256" => sha256(postimage),
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
           "literal patch postcondition_satisfied: path=#{spec.path} " <>
             "sha256=#{spec.postimage_sha256} no_write=true"}

        %Observation{state: :expected_preimage} ->
          apply_patch(spec, job, operation_hook, effect_observer)

        %Observation{} = observation ->
          observation_error(observation)
      end
    else
      {:error, reason} ->
        {:error, "literal patch rejected: #{inspect(reason)} action=report_rejection"}
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

  defp apply_patch(spec, job, operation_hook, effect_observer) do
    with {:ok, postimage} <- transform(spec) do
      opts = [operation_hook: operation_hook, effect_observer: effect_observer]

      case AtomicFile.replace(
             spec.target,
             {:regular, spec.preimage_sha256},
             postimage,
             spec.postimage_sha256,
             job.job_id,
             job.operation_digest,
             opts
           ) do
        {:ok, :committed} ->
          {:ok, "literal patch committed: path=#{spec.path} sha256=#{spec.postimage_sha256}"}

        {:ok, :already_satisfied} ->
          {:ok,
           "literal patch postcondition_satisfied: path=#{spec.path} " <>
             "sha256=#{spec.postimage_sha256} no_write=true"}

        {:error, {:observation, observation}} ->
          observation |> local_observation() |> observation_error()

        {:error, reason} ->
          {:error,
           "literal patch failed: path=#{spec.path} reason=#{inspect(reason)} " <>
             "action=report_rejection"}
      end
    else
      {:error, reason} ->
        {:error,
         "literal patch rejected: path=#{spec.path} reason=#{inspect(reason)} " <>
           "action=report_rejection"}
    end
  end

  defp transform(spec) do
    case AtomicFile.snapshot(spec.target) do
      {:regular, content, digest} when digest == spec.preimage_sha256 ->
        if String.valid?(content) do
          case :binary.matches(content, spec.old_text) do
            [_match] ->
              postimage = String.replace(content, spec.old_text, spec.new_text, global: false)

              if sha256(postimage) == spec.postimage_sha256,
                do: {:ok, postimage},
                else: {:error, :postimage_digest_mismatch}

            [] ->
              {:error, :old_text_not_found}

            matches ->
              {:error, {:old_text_match_count, length(matches)}}
          end
        else
          {:error, :invalid_utf8_preimage}
        end

      {:regular, _content, digest} ->
        {:error, {:preimage_changed, digest}}

      snapshot ->
        {:error, {:preimage_unavailable, snapshot}}
    end
  end

  defp observe_spec(spec) do
    spec.target
    |> AtomicFile.observe({:regular, spec.preimage_sha256}, spec.postimage_sha256)
    |> local_observation()
  end

  defp parse(%Job{} = job, cwd) do
    with :ok <- validate_job_identity(job),
         {:ok, args} <- validate_arguments(job.arguments),
         {:ok, target} <- AtomicFile.target(args["path"], cwd) do
      {:ok,
       %{
         target: target,
         path: args["path"],
         preimage_sha256: args["preimage_sha256"],
         old_text: args["old_text"],
         new_text: args["new_text"],
         postimage_sha256: args["postimage_sha256"]
       }}
    end
  end

  defp validate_job_identity(%Job{} = job) do
    cond do
      job.operation_kind != :literal_patch -> {:error, :invalid_operation_kind}
      job.tool_name != @tool_name -> {:error, :invalid_tool_name}
      job.tool_version != @tool_version -> {:error, :invalid_tool_version}
      job.required_capabilities != @required_capabilities -> {:error, :invalid_capabilities}
      not authority_allows_write?(job.authority_scope) -> {:error, :invalid_authority}
      not (is_binary(job.workspace_id) and job.workspace_id != "") -> {:error, :invalid_workspace}
      true -> :ok
    end
  end

  defp validate_arguments(args) when is_map(args) do
    keys = [
      "new_text",
      "old_text",
      "path",
      "postimage_sha256",
      "preimage_sha256",
      "replacement",
      "schema"
    ]

    with true <- Enum.sort(Map.keys(args)) == keys,
         true <- args["schema"] == @schema,
         true <- is_binary(args["path"]) and args["path"] != "",
         :ok <- validate_digest(args["preimage_sha256"]),
         true <- is_binary(args["old_text"]) and args["old_text"] != "",
         true <- String.valid?(args["old_text"]),
         true <- is_binary(args["new_text"]),
         true <- String.valid?(args["new_text"]),
         :ok <- validate_digest(args["postimage_sha256"]),
         true <- args["replacement"] == "same_directory_temp_rename" do
      {:ok, args}
    else
      false -> {:error, :invalid_arguments}
      {:error, _reason} = error -> error
    end
  end

  defp validate_arguments(_args), do: {:error, :invalid_arguments}

  defp validate_digest(digest) when is_binary(digest) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, digest), do: :ok, else: {:error, :invalid_digest}
  end

  defp validate_digest(_digest), do: {:error, :invalid_digest}

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
      outcome: {:error, "literal patch protocol failed: #{inspect(reason)}"},
      workspace: workspace,
      causal: :not_started,
      historical: :not_invoked,
      safe_action: :report_rejection
    }
  end

  defp terminal_safe_action(%Observation{state: :conflict}), do: :report_conflict
  defp terminal_safe_action(_workspace), do: :report_rejection

  defp indeterminate_safe_action(%Observation{state: :exact_postimage}, _job, _cwd),
    do: :postcondition_satisfied_no_retry

  defp indeterminate_safe_action(%Observation{state: :expected_preimage}, job, cwd) do
    case parse(job, cwd) do
      {:ok, spec} ->
        if AtomicFile.bound_temp?(spec.target, job.job_id, job.operation_digest),
          do: :cleanup_bound_temp_only_no_retry,
          else: :manual_investigation

      {:error, _reason} ->
        :manual_investigation
    end
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
     "literal patch conflict: path=#{path} observed_sha256=#{digest} " <>
       "action=report_conflict"}
  end

  defp observation_error(%Observation{state: state, path: path, reason: reason}) do
    {:error,
     "literal patch rejected: path=#{path} state=#{state} reason=#{inspect(reason)} " <>
       "action=report_rejection"}
  end

  defp local_observation(%AtomicFile.Observation{} = observation) do
    struct(Observation, Map.from_struct(observation))
  end

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
