defmodule Elara.Effect.Executor do
  @moduledoc """
  Durable effect-executor contract shared by production and test callers.

  A submitted job is admitted once by `{job_id, operation_digest}`. Only an
  accepted job whose callback has never started may be continued. Once callback
  invocation is durable, the executor never invokes it again without a terminal
  record.
  """

  alias Elara.Effect.Executor.Server
  alias Elara.Effect.ExecutorLedger.Record

  @type t :: GenServer.server()
  @type operation :: (-> {:ok | :error | :indeterminate, term()})
  @type response ::
          :unknown
          | {:accepted | :completed | :failed | :indeterminate, Record.t()}
          | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: Server.start_link(opts)

  @spec submit(t(), String.t(), String.t(), operation()) :: response()
  def submit(executor, job_id, operation_digest, operation) when is_function(operation, 0) do
    GenServer.call(executor, {:submit, job_id, operation_digest, operation}, :infinity)
  end

  @spec query(t(), String.t()) :: response()
  def query(executor, job_id), do: GenServer.call(executor, {:query, job_id})

  @spec continue(t(), String.t()) :: :ok | {:error, term()}
  def continue(executor, job_id), do: GenServer.call(executor, {:continue_pending, job_id})

  @spec continue(t(), String.t(), String.t(), operation()) :: :ok | {:error, term()}
  def continue(executor, job_id, operation_digest, operation) when is_function(operation, 0) do
    GenServer.call(executor, {:continue, job_id, operation_digest, operation})
  end

  @doc false
  @spec configuration(t()) :: map()
  def configuration(executor), do: GenServer.call(executor, :configuration)

  @doc false
  @spec close(t()) :: :ok
  def close(executor), do: GenServer.stop(executor, :normal)
end

defmodule Elara.Effect.Executor.Server do
  @moduledoc false

  use GenServer

  alias Elara.Effect.ExecutorLedger
  alias Elara.Effect.ExecutorLedger.Record
  alias Elara.Effect.Ownership

  defmodule State do
    @moduledoc false
    defstruct [
      :id,
      :ledger,
      :fault_hook,
      :writer_lock,
      :callback_lock_path,
      :incarnation,
      operations: %{}
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    fault_hook = Keyword.get(opts, :fault_hook, fn _point -> :ok end)
    incarnation = Ownership.writer()

    with {:ok, path} <- Ownership.canonical_path(Keyword.fetch!(opts, :path)),
         {:ok, writer_lock} <- Ownership.acquire(path <> ".writer.lock", :exclusive) do
      result =
        with {:ok, callbacks} <- Ownership.acquire(path <> ".callbacks.lock", :exclusive) do
          try do
            case ExecutorLedger.open(path) do
              {:ok, ledger} ->
                case ExecutorLedger.claim_writer(ledger, incarnation) do
                  {:ok, _} ->
                    {:ok,
                     %State{
                       id: id,
                       ledger: ledger,
                       fault_hook: fault_hook,
                       writer_lock: writer_lock,
                       callback_lock_path: path <> ".callbacks.lock",
                       incarnation: incarnation
                     }}

                  {:error, reason} ->
                    ExecutorLedger.close(ledger)
                    {:error, reason}
                end

              error ->
                error
            end
          after
            :ok = Ownership.release(callbacks)
          end
        end

      case result do
        {:ok, state} ->
          {:ok, state}

        {:error, reason} ->
          Ownership.release(writer_lock)
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:submit, job_id, operation_digest, operation}, _from, state) do
    case ExecutorLedger.admit(
           state.ledger,
           state.id,
           job_id,
           operation_digest,
           state.fault_hook
         ) do
      {:ok, :new, record} ->
        :ok = state.fault_hook.(:after_accept_commit_before_accept_reply)
        operations = Map.put(state.operations, job_id, {operation_digest, operation})
        {:reply, response(record), %{state | operations: operations}}

      {:ok, :existing, record} ->
        {:reply, response(record), state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:query, job_id}, _from, state) do
    reply =
      case ExecutorLedger.query(state.ledger, job_id) do
        {:ok, nil} -> :unknown
        {:ok, record} -> response(record)
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:continue_pending, job_id}, from, state) do
    case Map.fetch(state.operations, job_id) do
      {:ok, {operation_digest, operation}} ->
        continue_reply(state, from, job_id, operation_digest, operation)

      :error ->
        {:reply, {:error, :operation_unavailable}, state}
    end
  end

  def handle_call({:continue, job_id, operation_digest, operation}, from, state) do
    continue_reply(state, from, job_id, operation_digest, operation)
  end

  def handle_call(:configuration, _from, state) do
    {:reply, state.ledger.configuration, state}
  end

  @impl true
  def handle_continue({:execute, recipient, job_id, operation_digest, operation}, state) do
    :ok = state.fault_hook.(:after_accept_reply_before_callback)

    with {:ok, result} <- invoke_worker(state, job_id, operation_digest, operation) do
      :ok = state.fault_hook.(:after_external_mutation_before_completion_commit)

      case ExecutorLedger.finish(state.ledger, state.id, job_id, operation_digest, result) do
        {:ok, record} ->
          :ok = state.fault_hook.(:after_completion_commit_before_completion_reply)
          send(recipient, {:elara_effect_executor, state.id, job_id, response(record)})
          {:noreply, %{state | operations: Map.delete(state.operations, job_id)}}

        {:error, reason} ->
          {:stop, {:terminal_persistence_failed, reason}, state}
      end
    else
      {:error, reason} -> {:stop, {:attempt_persistence_failed, reason}, state}
    end
  end

  @impl true
  def handle_info({:EXIT, _worker, _reason}, state), do: {:noreply, state}

  def handle_info({port, {:exit_status, status}}, %{writer_lock: port} = state),
    do: {:stop, {:executor_ownership_lost, status}, state}

  def handle_info({_port, {:exit_status, _status}}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %State{ledger: ledger, writer_lock: writer_lock}) do
    ExecutorLedger.close(ledger)
    Ownership.release(writer_lock)
    :ok
  end

  defp continue_reply(state, {recipient, _tag}, job_id, operation_digest, operation) do
    case ExecutorLedger.query(state.ledger, job_id) do
      {:ok,
       %Record{
         operation_digest: ^operation_digest,
         executor_id: executor_id,
         state: :accepted,
         callback_attempt_count: 0
       }}
      when executor_id == state.id ->
        {:reply, :ok, state,
         {:continue, {:execute, recipient, job_id, operation_digest, operation}}}

      {:ok, %Record{operation_digest: digest}} when digest != operation_digest ->
        {:reply, {:error, :digest_conflict}, state}

      {:ok, %Record{executor_id: executor_id}} when executor_id != state.id ->
        {:reply, {:error, :wrong_executor}, state}

      {:ok, %Record{state: :accepted}} ->
        {:reply, {:error, :callback_already_attempted}, state}

      {:ok, %Record{}} ->
        {:reply, {:error, :already_terminal}, state}

      {:ok, nil} ->
        {:reply, {:error, :unknown_job}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @partial "it may have partially changed the workspace"

  defp response(%Record{state: state} = record), do: {state, record}

  # The linked worker holds its own shared lifetime lock before attempt commit. Writer
  # death cannot release that hold while the callback is still alive.
  defp invoke_worker(state, job_id, operation_digest, operation) do
    previous = Process.flag(:trap_exit, true)
    writer = self()

    try do
      task =
        Task.async(fn ->
          result = Ownership.acquire(state.callback_lock_path, :shared)
          send(writer, {:callback_owned, self(), result})

          case result do
            {:ok, _hold} ->
              receive do
                :invoke -> invoke(operation)
              end

            {:error, reason} ->
              {:indeterminate, "callback ownership unavailable: #{inspect(reason)}"}
          end
        end)

      receive do
        {:callback_owned, worker, {:ok, _hold}} when worker == task.pid ->
          case ExecutorLedger.begin_attempt(
                 state.ledger,
                 state.id,
                 job_id,
                 operation_digest,
                 Ownership.attempt(state.incarnation, worker)
               ) do
            {:ok, %Record{}} ->
              send(worker, :invoke)
              {:ok, await_worker(task, state.writer_lock)}

            {:error, reason} ->
              Task.shutdown(task, :brutal_kill)
              {:error, reason}
          end

        {:callback_owned, worker, {:error, reason}} when worker == task.pid ->
          Task.shutdown(task, :brutal_kill)
          {:error, {:callback_ownership_unavailable, reason}}

        {:DOWN, ref, :process, _worker, reason} when ref == task.ref ->
          {:error, {:callback_start_failed, reason}}

        {port, {:exit_status, status}} when port == state.writer_lock ->
          exit({:executor_ownership_lost, status})

        {:EXIT, _pid, reason} when reason != :normal ->
          exit(reason)
      end
    after
      Process.flag(:trap_exit, previous)
    end
  end

  defp await_worker(%Task{ref: ref, pid: worker} = task, writer_lock) do
    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        Process.unlink(worker)
        result

      {:DOWN, ^ref, :process, ^worker, reason} ->
        Process.unlink(worker)
        {:indeterminate, "callback worker lost: #{Exception.format_exit(reason)}; #{@partial}"}

      {:EXIT, ^worker, _reason} ->
        await_worker(task, writer_lock)

      {:EXIT, _pid, :normal} ->
        await_worker(task, writer_lock)

      {^writer_lock, {:exit_status, status}} ->
        exit({:executor_ownership_lost, status})

      {:EXIT, _pid, reason} ->
        exit(reason)
    end
  end

  # The callback has started, so an invalid result or a crash leaves its mutation
  # unknown: record it as indeterminate rather than as an ordinary failure.
  defp invoke(operation) do
    case operation.() do
      {kind, _payload} = result when kind in [:ok, :error, :indeterminate] ->
        result

      other ->
        {:indeterminate, "invalid callback result: #{inspect(other)}; #{@partial}"}
    end
  rescue
    error -> {:indeterminate, "callback crashed: #{Exception.message(error)}; #{@partial}"}
  catch
    kind, reason ->
      {:indeterminate, "callback crashed: #{Exception.format_banner(kind, reason)}; #{@partial}"}
  end
end
