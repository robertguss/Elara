defmodule Elara.Effect.Sidecar do
  @moduledoc false

  alias Elara.Effect.ControllerJournal
  alias Elara.Effect.ControllerJournal.Observation
  alias Elara.Effect.ExecutorLedger
  alias Elara.Effect.ExecutorLedger.Record
  alias Elara.Effect.Job
  alias Elara.Effect.TestExecutor

  defmodule Result do
    @moduledoc false
    @enforce_keys [:job, :status]
    defstruct [:job, :status, :outcome, :executor_record]

    @type t :: %__MODULE__{
            job: Job.t(),
            status: :terminal | :awaiting_executor,
            outcome: Elara.Tool.outcome() | nil,
            executor_record: Record.t() | nil
          }
  end

  @type operation :: (-> Elara.Tool.outcome())
  @type fault_hook :: (atom() -> :ok)

  @spec execute(
          GenServer.server(),
          GenServer.server(),
          Job.t(),
          operation(),
          timeout(),
          fault_hook()
        ) :: Result.t()
  def execute(executor, journal, %Job{} = job, operation, timeout, fault_hook)
      when is_function(operation, 0) and is_integer(timeout) and timeout > 0 do
    safely(job, journal, fn ->
      executor
      |> TestExecutor.submit(job.job_id, job.operation_digest, operation)
      |> resolve(executor, journal, job, operation, timeout, fault_hook)
    end)
  end

  @spec reconcile(
          GenServer.server(),
          GenServer.server(),
          Job.t(),
          operation(),
          timeout(),
          fault_hook()
        ) :: Result.t()
  def reconcile(executor, journal, %Job{} = job, operation, timeout, fault_hook)
      when is_function(operation, 0) and is_integer(timeout) and timeout > 0 do
    safely(job, journal, fn ->
      case ControllerJournal.observation(journal, job.job_id) do
        {:ok, %Observation{executor_record: %Record{state: state} = record}}
        when state in [:completed, :failed] ->
          result(job, record)

        {:ok, _observation} ->
          executor
          |> TestExecutor.query(job.job_id)
          |> resolve(executor, journal, job, operation, timeout, fault_hook)

        {:error, reason} ->
          rejected(job, nil, {:controller_observation_failed, reason})
      end
    end)
  end

  defp resolve(:unknown, executor, journal, job, operation, timeout, fault_hook) do
    executor
    |> TestExecutor.submit(job.job_id, job.operation_digest, operation)
    |> resolve(executor, journal, job, operation, timeout, fault_hook)
  end

  defp resolve(
         {:accepted, %Record{callback_attempt_count: 0} = record},
         executor,
         journal,
         job,
         operation,
         timeout,
         fault_hook
       ) do
    with {:ok, _observation} <- ControllerJournal.observe(journal, record),
         :ok <- invoke_hook(fault_hook, :after_accept_observation_before_continue) do
      monitor = monitor_executor(executor)

      case TestExecutor.continue(executor, job.job_id, job.operation_digest, operation) do
        :ok ->
          await_completion(executor, journal, job, operation, timeout, fault_hook, monitor)

        {:error, reason} when reason in [:callback_already_attempted, :already_terminal] ->
          demonitor(monitor)

          executor
          |> TestExecutor.query(job.job_id)
          |> resolve(executor, journal, job, operation, timeout, fault_hook)

        {:error, reason} ->
          demonitor(monitor)
          indeterminate(job, record, {:continue_failed, reason})
      end
    else
      {:error, reason} ->
        indeterminate(job, record, {:controller_observation_failed, reason})
    end
  end

  defp resolve(
         {:accepted, %Record{callback_attempt_count: 1} = record},
         _executor,
         journal,
         job,
         _operation,
         _timeout,
         _fault_hook
       ) do
    case ControllerJournal.observe(journal, record) do
      {:ok, _observation} ->
        indeterminate(job, record, :missing_causal_terminal_evidence)

      {:error, reason} ->
        indeterminate(job, record, {:controller_observation_failed, reason})
    end
  end

  defp resolve(
         {state, %Record{state: state} = record},
         _executor,
         journal,
         job,
         _operation,
         _timeout,
         _fault_hook
       )
       when state in [:completed, :failed] do
    case ControllerJournal.observe(journal, record) do
      {:ok, _observation} ->
        result(job, record)

      {:error, reason} ->
        indeterminate(job, record, {:controller_observation_failed, reason})
    end
  end

  defp resolve(
         {:error, reason},
         _executor,
         _journal,
         job,
         _operation,
         _timeout,
         _fault_hook
       ) do
    rejected(job, nil, {:executor_rejected, reason})
  end

  defp await_completion(executor, journal, job, operation, timeout, fault_hook, monitor) do
    receive do
      {:elara_test_executor, _executor_id, job_id, {state, %Record{state: state} = record}}
      when job_id == job.job_id and state in [:completed, :failed] ->
        demonitor(monitor)

        with {:ok, _observation} <- ControllerJournal.observe(journal, record),
             :ok <- invoke_hook(fault_hook, :after_completion_reply_before_session_result_persist) do
          result(job, record)
        else
          {:error, reason} ->
            indeterminate(job, record, {:controller_observation_failed, reason})
        end

      {:DOWN, reference, :process, _pid, reason}
      when reference == monitor ->
        unavailable(job, journal, Exception.format_exit(reason))
    after
      timeout ->
        demonitor(monitor)

        executor
        |> TestExecutor.query(job.job_id)
        |> resolve(executor, journal, job, operation, timeout, fn _ -> :ok end)
    end
  end

  defp safely(job, journal, fun) do
    fun.()
  rescue
    error -> unavailable(job, journal, Exception.message(error))
  catch
    kind, reason -> unavailable(job, journal, Exception.format_banner(kind, reason))
  end

  defp unavailable(job, journal, reason) do
    case safe_observation(journal, job.job_id) do
      %Observation{executor_record: %Record{state: :accepted, callback_attempt_count: 0} = record} ->
        awaiting_executor(job, record)

      %Observation{executor_record: %Record{state: :accepted} = record} ->
        indeterminate(job, record, {:transport_lost, reason})

      %Observation{executor_record: %Record{} = record} ->
        result(job, record)

      %Observation{executor_record: nil} ->
        awaiting_executor(job, nil)

      nil ->
        awaiting_executor(job, nil)
    end
  end

  defp safe_observation(journal, job_id) do
    case ControllerJournal.observation(journal, job_id) do
      {:ok, observation} -> observation
      {:error, _reason} -> nil
    end
  catch
    :exit, _reason -> nil
  end

  defp result(job, %Record{result: {kind, text}} = record)
       when kind in [:ok, :error] and is_binary(text) do
    %Result{job: job, status: :terminal, outcome: {kind, text}, executor_record: record}
  end

  defp result(job, %Record{} = record) do
    rejected(job, record, :invalid_terminal_result)
  end

  defp rejected(job, record, reason) do
    %Result{
      job: job,
      status: :terminal,
      executor_record: record,
      outcome: {:error, "effect protocol failed: #{inspect(reason)}"}
    }
  end

  defp indeterminate(job, record, reason) do
    last_proven = if record, do: ExecutorLedger.last_proven_fact(record), else: :intent

    missing =
      case record do
        %Record{state: state} when state in [:completed, :failed] ->
          "controller_observation_or_session_persistence"

        _record ->
          "completed_or_failed"
      end

    message =
      "effect outcome indeterminate: " <>
        "job_id=#{job.job_id} " <>
        "operation_digest=#{job.operation_digest} " <>
        "workspace_id=#{job.workspace_id} " <>
        "last_proven=#{last_proven} " <>
        "missing=#{missing} " <>
        "reason=#{inspect(reason)} action=do_not_retry_or_fail_over"

    %Result{
      job: job,
      status: :terminal,
      outcome: {:indeterminate, message},
      executor_record: record
    }
  end

  defp awaiting_executor(job, record) do
    %Result{job: job, status: :awaiting_executor, executor_record: record}
  end

  defp monitor_executor(executor) do
    case GenServer.whereis(executor) do
      pid when is_pid(pid) -> Process.monitor(pid)
      nil -> make_ref()
    end
  end

  defp demonitor(reference) do
    Process.demonitor(reference, [:flush])
    :ok
  end

  defp invoke_hook(hook, point) do
    case hook.(point) do
      :ok -> :ok
      other -> {:error, {:invalid_fault_hook_return, other}}
    end
  end
end
