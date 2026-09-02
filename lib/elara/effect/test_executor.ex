defmodule Elara.Effect.TestExecutor do
  @moduledoc false

  alias Elara.Effect.Executor
  alias Elara.Effect.ExecutorLedger.Record

  @type operation :: Executor.operation()
  @type response ::
          :unknown
          | {:accepted | :completed | :failed, Record.t()}
          | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: Executor.start_link(opts)

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :id), Path.expand(Keyword.fetch!(opts, :path))},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @spec submit(GenServer.server(), String.t(), String.t(), operation()) :: response()
  defdelegate submit(executor, job_id, operation_digest, operation), to: Executor

  @spec query(GenServer.server(), String.t()) :: response()
  defdelegate query(executor, job_id), to: Executor

  @spec continue(GenServer.server(), String.t()) :: :ok | {:error, term()}
  defdelegate continue(executor, job_id), to: Executor

  @spec continue(GenServer.server(), String.t(), String.t(), operation()) ::
          :ok | {:error, term()}
  defdelegate continue(executor, job_id, operation_digest, operation), to: Executor

  @spec configuration(GenServer.server()) :: map()
  defdelegate configuration(executor), to: Executor

  @spec close(GenServer.server()) :: :ok
  defdelegate close(executor), to: Executor
end
